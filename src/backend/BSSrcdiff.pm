#
# Copyright (c) 2006, 2007 Michael Schroeder, Novell Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
#
# create a diff between two source trees
#

package BSSrcdiff;

use Digest::MD5;
use Fcntl;

use strict;

use BSUtil;

#
# batcher support: if we need to do lots of diffs for a bif tar archive,
# we call the diff program from an extra process. While this sounds like
# something that makes no sense at all, it actually speeds up diffing
# by a factor of 20. The reason is that fork/exec is much slower if the
# process has a big memory size.
#
# A better approach would be a perl module that does the diffing with
# no exec at all but alas, there seems to be no such thing (execpt a
# pure perl version that is too slow).
#
my $batcherpid;

sub batcher {
  $| = 1;
  open(OUT, ">&3") || die("open fd 3: $!\n");
  my $r = 0;
  while (1) {
    my $in = '';
    my $inl = sysread(STDIN, $in, 4);
    last if defined($inl) && $inl == 0;
    die("read error length\n") unless $inl && $inl == 4;
    $inl = unpack('N', $in);
    if ($inl == 0) {	# ping
      syswrite(OUT, $in, 4);
      next;
    }
    $in = '';
    while ($inl > 0) {
      my $l = $inl > 8192 ? 8192 : $inl;
      $l = sysread(STDIN, $in, $l, length($in));
      die("read error body\n") unless $l && $l > 0;
      $inl -= $l;
    }
    $in = BSUtil::fromstorable($in);
    $in = BSSrcdiff::filediff(@$in);
    $in = BSUtil::tostorable($in);
    $in = pack('N', length($in)).$in;
    while (length($in)) {
      my $l = syswrite(OUT, $in, length($in));
      die("write error: $!\n") unless $l;
      $in = substr($in, $l);
    }
    eval {
      exec("/usr/bin/perl", '-I', $INC[0], '-MBSSrcdiff', '-e', 'BSSrcdiff::batcher()') if $r++ == 1000;
    };
    warn($@) if $@;
  }
}

sub startbatcher {
  die("batcher is already running\n") if $batcherpid;
  pipe(BATCHERIN, TOBATCHER);
  pipe(FROMBATCHER, BATCHEROUT);
  if (($batcherpid = xfork()) == 0) {
    close(TOBATCHER);
    close(FROMBATCHER);
    POSIX::dup2(fileno(BATCHERIN), 0);
    POSIX::dup2(fileno(BATCHEROUT), 3);
    my $dir = __FILE__;
    $dir =~ s/[^\/]+$/./;
    exec("/usr/bin/perl", '-I', $dir, '-MBSSrcdiff', '-e', 'BSSrcdiff::batcher()');
    die("/usr/bin/perl: $!\n");
  }
  my $p = '';
  close(BATCHEROUT);
  syswrite(TOBATCHER, "\000\000\000\000", 4);
  if (sysread(FROMBATCHER, $p, 4) != 4 || $p ne "\000\000\000\000") {
    warn("batcher did not start\n");
    close(BATCHEROUT);
    close(TOBATCHER);
    close(FROMBATCHER);
    waitpid($batcherpid, 0);
    undef($batcherpid);
    return;
  }
  close(BATCHERIN);
}

sub endbatcher {
  return unless $batcherpid;
  close(TOBATCHER);
  close(FROMBATCHER);
  waitpid($batcherpid, 0);
  undef($batcherpid);
}

sub filediff_batcher {
  die("batcher is not running\n") unless $batcherpid;
  my $p = BSUtil::tostorable(\@_);
  $p = pack('N', length($p)).$p;
  while (length($p)) {
    my $l = syswrite(TOBATCHER, $p, length($p));
    die("batcher write: $!\n") unless $l;
    $p = substr($p, $l);
  }
  $p = '';
  sysread(FROMBATCHER, $p, 4) == 4 || die;
  my $pl = unpack('N', $p);
  $p = '';
  while ($pl > 0) {
    my $l = $pl > 8192 ? 8192 : $pl;
    $l = sysread(FROMBATCHER, $p, $l, length($p));
    die unless $l > 0;
    $pl -= $l;
  }
  return BSUtil::fromstorable($p);
}

#
# fmax: maximum number of lines in a diff
# tmax: maximum number of lines in a tardiff
#

sub opentar {
  my ($fp, $tar, $gemdata, @taropts) = @_;
  if (!$gemdata) {
     open($fp, '-|', 'tar', @taropts, $tar) || die("tar: $!\n");
     return;
  }
  if (!open($fp, '-|')) {
    if (!open(STDIN, '-|')) {
      exec('tar', '-xOf', $tar, $gemdata);
      die("tar $gemdata");
    }
    if ($gemdata =~ /\.gz$/) {
      exec('tar', '-z', @taropts, '-');
    } elsif ($gemdata =~ /\.xz$/) {
      exec('tar', '--xz', @taropts, '-');
    } else {
      exec('tar', @taropts, '-');
    }
    die('tar');
  }
}

#
# entries have the following attributes:
#
#  sname: name we are using for diffing
#   name: name in tar file
#   type: [-dlbcp] type of file
#   size: size in bytes
#   mode: mode as rwx... string
#   info: md5sum for plain files, link target for symlinks

sub listtar {
  my ($tar, $gemdata) = @_;
  local *F;
  
  opentar(\*F, $tar, $gemdata, '--numeric-owner', '-tvf');
  my @c;
  my $fc = 0;
  while(<F>) {
    next unless /^([-dlbcp])(.........)\s+\d+\/\d+\s+(\S+) \d\d\d\d-\d\d-\d\d \d\d:\d\d(?::\d\d)? (.*)$/;
    my $type = $1;
    my $mode = $2;
    my $size = $3;
    my $name = $4;
    my $info;
    if ($type eq 'l') {
      next unless $name =~ /^(.*) -> (.*)$/;
      $name = $1;
      $info = $2;
    } elsif ($type eq 'b' || $type eq 'c') {
      $info = $size;
      $size = 0;
    } elsif ($type eq 'd') {
      $name =~ s/\/$//;
    } elsif ($type eq '-') {
      if ($size == 0) {
	$info = 'd41d8cd98f00b204e9800998ecf8427e';
      } else {
	$fc++;		# need 2nd pass
      }
    }
    push @c, {'type' => $type, 'name' => $name, 'size' => $size, 'mode' => $mode};
    $c[-1]->{'info'} = $info if defined $info;
  }
  close(F) || die("tar: $!\n");
  if ($fc) {
    opentar(\*F, $tar, $gemdata, '-xOf');
    for my $c (@c) {
      next unless $c->{'type'} eq '-' && $c->{'size'};
      my $ctx = Digest::MD5->new;
      my $s = $c->{'size'};
      while ($s > 0) {
	my $b;
	my $l = $s > 16384 ? 16384 : $s;
	$l = sysread(F, $b, $l);
	die("tar read error\n") unless $l;
	$ctx->add($b);
	$s -= $l;
      }
      $c->{'info'} = $ctx->hexdigest();
    }
    close(F) || die("tar: $!\n");
  }
  return @c;
}

sub extracttar {
  my ($tar, $cp, $gemdata) = @_;

  local *F;
  local *G;
  opentar(\*F, $tar, $gemdata, '-xOf');
  my $skipgemdata;
  for my $c (@$cp) {
    next unless $c->{'type'} eq '-' || $c->{'type'} eq 'gemdata';
    if ($c->{'type'} eq 'gemdata') {
      my @data = grep {$_->{'name'} =~ /^data\// && $_->{'type'} ne 'gemdata'} @$cp;
      extracttar($tar, \@data, $c->{'name'});
      delete $c->{'extract'};	# just in case...
      $skipgemdata = 1;
    }
    next if $skipgemdata && $c->{'type'} ne 'gemdata' && $c->{'name'} =~ /^data\//;
    if (exists $c->{'extract'}) {
      open(G, '>', $c->{'extract'}) || die("$c->{'extract'}: $!\n");
      my $s = $c->{'size'};
      while ($s > 0) {
	my $b;
	my $l = $s > 16384 ? 16384 : $s;
	$l = sysread(F, $b, $l);
	die("tar read error\n") unless $l;
	(syswrite(G, $b) || 0) == $l || die("syswrite: $!\n");
	$s -= $l;
      }
      close(G);
    } elsif ($c->{'size'}) {
      my $s = $c->{'size'};
      while ($s > 0) {
	my $b;
	my $l = $s > 16384 ? 16384 : $s;
	$l = sysread(F, $b, $l);
	die("tar read error\n") unless $l;
	$s -= $l;
      }
    }
  }
  close(F) || die("tar: $!\n");
}

sub listgem {
  my ($gem) = @_;

  my @gem;
  my @tar = listtar($gem);
  my $founddata = 0;
  for my $t (@tar) {
    if ($t->{'name'} =~ /^data\.tar\.[xg]z$/) {
      die("multiple data sections in gem\n") if $founddata++;
      $t->{'type'} = 'gemdata';
      push @gem, $t;
      my @data = listtar($gem, $t->{'name'});
      $_->{'name'} = "data/".$_->{'name'} for @data;
      push @gem, @data;
    } elsif ($t->{'name'} =~ /^data\//) {
      die("gemfile contains data directory\n");
    } else {
      push @gem, $t;
    }
  }
  return @gem;
}

sub cpiomode {
  my ($m) = @_;
  my $mm = '';
  my $b = 0x100;
  for (qw{r w x r w x r w x}) {
    $mm .= $m & $b ? $_ : '-';
    $b >>= 1;
  }
  substr($mm, 2, 1) = substr($mm, 2, 1) eq 'x' ? 'S' : 's' if $m & 0x800;
  substr($mm, 5, 1) = substr($mm, 5, 1) eq 'x' ? 'S' : 's' if $m & 0x400;
  substr($mm, 8, 1) = substr($mm, 8, 1) eq 'x' ? 'T' : 'T' if $m & 0x200;
  return $mm;
}

sub listextractcpio {
  my ($cpio, $cp) = @_;
  
  my @c;
  local *F;
  local *G;
  open(F, '<', $cpio) || die("$cpio: $!\n");
  while (1) {
    my $cpiohead;
    die("cpio read error head\n") unless (read(F, $cpiohead, 110) || 0) == 110;
    die("cpio: not a newc cpio\n") unless substr($cpiohead, 0, 6) eq '070701';
    my $mode = hex(substr($cpiohead, 14, 8));
    my $mtime = hex(substr($cpiohead, 46, 8));
    my $fsize  = hex(substr($cpiohead, 54, 8));
    my $nsize = hex(substr($cpiohead, 94, 8));
    die("ridiculous long filename\n") if $nsize > 8192;
    my $nsizepad = 0;
    $nsizepad = 4 - ($nsize + 2 & 3) if $nsize + 2 & 3;
    my $name;
    die("cpio read error name\n") unless (read(F, $name, $nsize + $nsizepad) || 0) == $nsize + $nsizepad;
    $name = substr($name, 0, $nsize);
    $name =~ s/\0.*//s;
    my $type = $mode & 0xf000;
    if ($type == 0x4000) {
      $type = 'd';
    } elsif ($type == 0x2000) {
      $type = 'c';
    } elsif ($type == 0x4000) {
      $type = 'b';
    } elsif ($type == 0x8000) {
      $type = '-';
    } elsif ($type == 0xa000) {
      $type = 'l';
    } else {
      $type = '?';
    }
    last if !$fsize && $name eq 'TRAILER!!!';
    push @c, {'type' => $type, 'name' => $name, 'size' => $fsize, 'mode' => cpiomode($mode)};
    my $x = shift @$cp if $cp;
    die if $cp && !$x;
    undef $x if $x && !$x->{'extract'};
    die("ridiculous long symlink\n") if $type eq 'l' && $fsize > 8192;
    my $fsizepad = 0;
    $fsizepad = 4 - ($fsize & 3) if $fsize & 3;
    my $info = $type eq 'l' ? '' : 'd41d8cd98f00b204e9800998ecf8427e';
    if ($x) {
      open(G, '>', $x->{'extract'}) || die("$x->{'extract'}: $!\n");
    }
    if ($fsize > 0) {
      my $ctx = Digest::MD5->new;
      while ($fsize > 0) {
        my $chunk = $fsize > 16384 ? 16384 : $fsize;
	my $data;
	die("cpio read error body\n") unless (read(F, $data, $chunk) || 0) == $chunk;
	$ctx->add($data);
	$info .= $data if $type eq 'l';
	print G $data if $x;
	$fsize -= $chunk;
      }
      $info = $ctx->hexdigest() unless $type eq 'l';
    }
    close(G) if $x;
    $c[-1]->{'info'} = $info if $type eq '-' || $type eq 'l';
    die("cpio read error bodypad\n") unless (read(F, $name, $fsizepad) || 0) == $fsizepad;
  }
  close(F);
  return @c;
}


#
# diff file f1 against file f2
#
sub filediff {
  my ($f1, $f2, %opts) = @_;

  return filediff_batcher(@_) if $batcherpid;

  my $nodecomp = $opts{'nodecomp'};
  my $arg = $opts{'diffarg'} || '-u';
  my $max = $opts{'fmax'};
  my $maxc = defined($max) ? $max * 80 : undef;
  $maxc = $opts{'fmaxc'} if exists $opts{'fmaxc'};

  if (!defined($f1) && !defined($f2)) {
    return { 'lines' => 0 , '_content' => ''};
  }

  local *D;
  my $pid = open(D, '-|');
  if (!$pid) {
    local *F1;
    local *F2;
    if (!defined($f1) || ref($f1)) {
      open(F1, "<", '/dev/null') || die("open /dev/null: $!\n");
    } elsif (!$nodecomp && $f1 =~ /\.gz$/i) {
      open(F1, "-|", 'gunzip', '-dc', $f1) || die("open $f1: $!\n");
    } elsif (!$nodecomp && $f1 =~ /\.bz2$/i) {
      open(F1, "-|", 'bzip2', '-dc', $f1) || die("open $f1: $!\n");
    } elsif (!$nodecomp && $f1 =~ /\.xz$/i) {
      open(F1, "-|", 'xz', '-dc', $f1) || die("open $f1: $!\n");
    } else {
      open(F1, '<', $f1) || die("open $f1: $!\n");
    }
    if (!defined($f2) || ref($f2)) {
      open(F2, "<", '/dev/null') || die("open /dev/null: $!\n");
    } elsif (!$nodecomp && $f2 =~ /\.gz$/i) {
      open(F2, "-|", 'gunzip', '-dc', $f2) || die("open $f2: $!\n");
    } elsif (!$nodecomp && $f2 =~ /\.bz2$/i) {
      open(F2, "-|", 'bzip2', '-dc', $f2) || die("open $f2: $!\n");
    } elsif (!$nodecomp && $f2 =~ /\.xz$/i) {
      open(F2, "-|", 'xz', '-dc', $f2) || die("open $f2: $!\n");
    } else {
      open(F2, '<', $f2) || die("open $f2: $!\n");
    }
    fcntl(F1, F_SETFD, 0);
    fcntl(F2, F_SETFD, 0);
    exec '/usr/bin/diff', $arg, '/dev/fd/'.fileno(F1), '/dev/fd/'.fileno(F2);
    die("diff: $!\n");
  }
  my $lcnt = $opts{'linestart'} || 0;
  my $ccnt = 0;
  my $d = '';
  my $havediff;
  my $binary;
  while (<D>) {
    if (!$havediff) {
      next if /^diff/;
      next if /^--- \/dev\/fd\/\d+/;
      if (/^\+\+\+ \/dev\/fd\/\d+/) {
	if (defined($f1) && ref($f1)) {
	  $d .= "-$_\n" for @$f1;
	  $lcnt += @$f1;
	}
	$havediff = 1;
	next;
      }
      if (/^(?:Binary )?[fF]iles \/dev\/fd\/\d+ and \/dev\/fd\/\d+ differ/) {
	$binary = 1;
	last;
      }
    }
    $lcnt++;
    if (!defined($max) || $lcnt <= $max) {
      if (defined($maxc) && length($d) + length($_) > $maxc) {
	$ccnt++;
      } else {
        $d .= $_;
      }
    }
  }
  close(D);
  if ($havediff && !$binary && length($d) >= 1024) {
    # the diff binary detection is a bit "lacking". Do some extra heuristics
    # by counting 26 chars common in binaries
    my $bcnt = $d =~ tr/\000-\007\016-\037/\000-\007\016-\037/;
    if ($bcnt * 40 > length($d)) {
      $d = '';
      $havediff = 0;
      $binary = 1;
      $lcnt = $opts{'linestart'} || 0;
      $ccnt = 0;
    }
  }
  if ($d eq '' && !$havediff && ((defined($f1) && ref($f1)) || defined($f2) && ref($f2))) {
    $havediff = 1;
    if (defined($f1) && ref($f1)) {
      $d .= "-$_\n" for @$f1;
      $lcnt += @$f1;
    }
  }
  if ($havediff && defined($f2) && ref($f2)) {
    $d .= "+$_\n" for @$f2;
    $lcnt += @$f2;
  }
  my $ret = {};
  if (!defined($f1)) {
    $ret->{'state'} = 'added';
  } elsif (!defined($f2)) {
    $ret->{'state'} = 'deleted';
  } else {
    $ret->{'state'} = 'changed';
  }
  $ret->{'binary'} = 1 if $binary;
  $ret->{'lines'} = $lcnt;
  $ret->{'shown'} = $max if defined($max) && $lcnt > $max;
  $ret->{'shown'} = ($ret->{'shown'} || $ret->{'lines'}) - $ccnt if $ccnt;
  $ret->{'_content'} = $d;
  return $ret;
}

sub fixup {
  my ($e) = @_;
  return undef unless defined $e;
  if ($e->{'type'} eq 'd') {
    return [ '(directory)' ];
  } elsif ($e->{'type'} eq 'b') {
    return [ "(block device $e->{info})" ];
  } elsif ($e->{'type'} eq 'c') {
    return [ "(character device $e->{info})" ];
  } elsif ($e->{'type'} eq 'l') {
    return [ "(symlink to $e->{info})" ];
  } elsif ($e->{'type'} eq '-') {
    return $e->{'size'} ? $e->{'extract'} : undef;
  } else {
    return [ "(unknown type $e->{type})" ];
  }
}

sub adddiffheader {
  my ($r, $p1, $p2) = @_;
  my ($h, $hl);
  my $state = $r->{'state'} || 'changed';
  $r->{'_content'} = '' unless defined $r->{'_content'};
  if ($r->{'binary'}) {
    if (defined($p1) && defined($p2) && $state eq 'changed') {
      $h = "Binary files $p1 and $p2 differ\n";
    } elsif (defined($p1) && $state ne 'added') {
      $h = "Binary files $p1 deleted\n";
    } elsif (defined($p2) && $state ne 'deleted') {
      $h = "Binary files $p2 added\n";
    }
    $hl = 1;
  } else {
    if (defined($p1) && defined($p2) && $state eq 'changed') {
      $h = "--- $p1\n+++ $p2\n";
    } elsif (defined($p1) && $state ne 'added') {
      $p2 = $p1 unless defined $p2;
      $h = "--- $p1\n+++ $p2\n";
    } elsif (defined($p2) && $state ne 'deleted') {
      $p1 = $p2 unless defined $p1;
      $h = "--- $p1\n+++ $p2\n";
    }
    $hl = 2;
  }
  if ($h) {
    $r->{'_content'} = $h . $r->{'_content'};
    $r->{'lines'} += $hl;
    $r->{'shown'} += $hl if defined $r->{'shown'};
  }
  if (defined($r->{'shown'})) {
    if ($r->{'shown'}) {
      $r->{'_content'} .= "(".($r->{'lines'} - $r->{'shown'})." more lines skipped)\n";
    } else {
      $r->{'_content'} .= "(".($r->{'lines'})." lines skipped)\n";
    }
  }
  return $r->{'_content'};
}

# strip first dir if it is the same for all files
sub stripfirstdir {
  my ($l) = @_;
  return unless @$l;
  my $l1 = $l->[0]->{'sname'};
  $l1 =~ s/\/.*//s;
  return if grep {!($_->{'sname'} eq $l1 || $_->{'sname'} =~ /^\Q$l1\E\//)} @$l;
  $_->{'sname'} =~ s/^[^\/]*\/?// for @$l;
}

sub listit {
  my ($f) = @_;
  return listgem($f) if $f =~ /\.gem$/;
  return listextractcpio($f) if $f =~ /\.obscpio$/;
  return listtar($f);
}

sub extractit {
  my ($f, $cp) = @_;
  return listextractcpio($f, $cp || []) if $f =~ /\.obscpio$/;
  return extracttar($f, $cp);
}

sub tardiff {
  my ($f1, $f2, %opts) = @_;

  my $max = $opts{'tmax'};
  my $maxc = defined($max) ? $max * 80 : undef;
  $maxc = $opts{'tmaxc'} if exists $opts{'tmaxc'};
  my $tfmax = $opts{'tfmax'};
  my $tfmaxc = $opts{'tfmaxc'};
  my $edir = $opts{'edir'};

  my @l1 = listit($f1);
  my @l2 = listit($f2);

  die unless $edir;
  for (@l1, @l2) {
    $_->{'sname'} = $_->{'name'};
    $_->{'sname'} =~ s/^\.\///;
  }
  stripfirstdir(\@l1);
  stripfirstdir(\@l2);

  for (@l1, @l2) {
    $_->{'sname'} = '' if "/$_->{'sname'}/" =~ /\/(?:CVS|\.cvsignore|\.svn|\.svnignore)\//;
  }

  my %l1 = map {$_->{'sname'} => $_} @l1;
  my %l2 = map {$_->{'sname'} => $_} @l2;
  my @f = sort keys %{ { %l1, %l2 } };

  # find renamed files
  my %l1md5;
  for (@l1) {
    next unless $_->{'type'} eq '-' && $_->{'size'} && $_->{'sname'} ne '';
    $l1md5{$_->{'info'}} = $_;
  }
  my %ren;
  for my $l2 (@l2) {
    next unless $l2->{'type'} eq '-' && $l2->{'size'};
    my $f = $l2->{'sname'};
    next if $f eq '' || $l1{$f};
    my $l1 = $l1md5{$l2->{'info'}};
    next unless $l1 && !$l2{$l1->{'sname'}};
    $ren{$l1->{'sname'}} = $f;
    $ren{$f} = $l1->{'sname'};
    delete $l1md5{$l2->{'info'}};	# used up
  }
  %l1md5 = (); 	# free mem

  my $e1cnt = 0;
  my $e2cnt = 0;

  my @efiles;
  for my $f (@f) {
    next if $f eq '';
    next if $ren{$f};
    my $l1 = $l1{$f};
    my $l2 = $l2{$f};
    my $suf1 = '';
    $suf1 = ".$1" if $l1 && $l1->{'name'} =~ /\.(gz|xz|bz2)$/;
    my $suf2 = '';
    $suf2 = ".$1" if $l2 && $l2->{'name'} =~ /\.(gz|xz|bz2)$/;
    if ($l1 && $l2) {
      next if $l1->{'type'} ne $l2->{'type'};
      next if $l1->{'type'} ne '-';
      next if $l1->{'info'} eq $l2->{'info'};
      $l1->{'extract'} = "$edir/a$e1cnt$suf1";
      push @efiles, "$edir/a$e1cnt$suf1";
      $e1cnt++;
      $l2->{'extract'} = "$edir/b$e2cnt$suf2";
      push @efiles, "$edir/b$e2cnt$suf2";
      $e2cnt++;
    } elsif ($l1 && $l1->{'size'}) {
      $l1->{'extract'} = "$edir/a$e1cnt$suf1";
      push @efiles, "$edir/a$e1cnt$suf1";
      $e1cnt++;
    } elsif ($l2 && $l2->{'size'}) {
      $l2->{'extract'} = "$edir/b$e2cnt$suf2";
      push @efiles, "$edir/b$e2cnt$suf2";
      $e2cnt++;
    }
  }

  if ($e1cnt || $e2cnt) {
    # need to extract some files
    if (! -d $edir) {
      mkdir($edir) || die("mkdir $edir: $!\n");
    }
    extractit($f1, \@l1) if $e1cnt;
    extractit($f2, \@l2) if $e2cnt;
  }

  startbatcher() if $e1cnt + $e2cnt > 100 || ($e1cnt + $e2cnt > 10 && @f > 20000);

  my $lcnt = 0;
  my $d = '';
  my @ret;
  my $ccnt = 0;
  for my $f (@f) {
    next if $f eq '';
    my $l1 = $l1{$f};
    my $l2 = $l2{$f};
    if ($ren{$f}) {
      my $r = {'lines' => 1, 'name' => $f};
      if ($l1) {
	$r->{'_content'} = "(renamed to $ren{$f})\n";
	$r->{'new'} = {'name' => $ren{$f}, 'md5' => $l1->{'info'}, 'size' => $l1->{'size'}};
      } else {
	$r->{'_content'} = "(renamed from $ren{$f})\n";
	$r->{'new'} = {'name' => $f, 'md5' => $l2->{'info'}, 'size' => $l2->{'size'}};
      }
      push @ret, $r;
      $lcnt += $r->{'lines'};
      next;
    }
    next unless $l1 || $l2;
    if ($l1 && $l2) {
      next if $l1->{'type'} eq $l2->{'type'} && (!defined($l1->{'info'}) || $l1->{'info'} eq $l2->{'info'});
      next if $l1->{'type'} eq 'gemdata' && $l2->{'type'} eq 'gemdata';
    }
    my $fmax;
    $fmax = $max > $lcnt ? $max - $lcnt : 0 if defined $max;
    $fmax = $tfmax if defined($tfmax) && (!defined($fmax) || $fmax > $tfmax);
    my $r = filediff(fixup($l1), fixup($l2), %opts, 'fmax' => $fmax, 'fmaxc' => $tfmaxc);
    $r->{'name'} = $f;
    $r->{'old'} = {'name' => $f, 'md5' => $l1->{'info'}, 'size' => $l1->{'size'}} if $l1;
    $r->{'new'} = {'name' => $f, 'md5' => $l2->{'info'}, 'size' => $l2->{'size'}} if $l2;
    push @ret, $r;
    $lcnt += $r->{'shown'} || $r->{'lines'};
    $ccnt += length($r->{'_content'}) if exists $r->{'_content'};
  }
  if ((defined($max) && $lcnt > $max) || (defined($maxc) && $ccnt > $maxc)) {
    my $r = {'lines' => $lcnt, 'shown' => 0};
    @ret = ($r);
  }
  unlink($_) for @efiles;
  rmdir($edir);

  endbatcher();
  return @ret;
}

my @simclasses = (
  'spec',
  'dsc',
  'changes',
  '(?:diff?|patch)(?:\.gz|\.bz2|\.xz)?',
  '(?:tar|tar\.gz|tar\.bz2|tar\.xz|tgz|tbz|gem|obscpio)',
);

sub findsim {
  my ($of, @f) = @_;

  my %s = map {$_ => 1} @$of;	# old file pool
  my %sim;

  my %fc;	# file base name
  my %ft;	# file class

  for my $f (@f) {
    if ($s{$f}) {
      $sim{$f} = $f;	# trivial mapped
      delete $s{$f};
    }
  }

  # classify all files
  for my $f (@f, @$of) {
    next if $sim{$f};	# trivial mapped
    next unless $f =~ /\./;
    next if exists $fc{$f};
    for my $sc (@simclasses) {
      my $fc = $f;
      if ($fc =~ s/\.$sc$//) {
	$fc{$f} = $fc;
	$ft{$f} = $sc;
	last;
      }
      $fc =~ s/\.bz2$//;
      $fc =~ s/\.gz$//;
      next if $fc =~ /\.(?:spec|dsc|changes)$/;	# no compression here!
      if ($fc =~ /^(.*)\.([^\/]+)$/) {
	$fc{$f} = $1;
	$ft{$f} = $2;
      }
    }
  }

  # first pass: exact matches
  for my $f (grep {!exists($sim{$_})} @f) {
    my $fc = $fc{$f};
    my $ft = $ft{$f};
    next unless defined $fc;
    my @s = grep {defined($fc{$_}) && $fc{$_} eq $fc && $ft{$_} eq $ft} sort keys %s;
    if (@s) {
      $sim{$f} = $s[0];
      delete $s{$s[0]};
    }
  }

  # second pass: ignore version
  for my $f (grep {!exists($sim{$_})} @f) {
    my $fc = $fc{$f};
    my $ft = $ft{$f};
    next unless defined $fc;
    my @s = grep {defined($ft{$_}) && $ft{$_} eq $ft} sort keys %s;
    my $fq = "\Q$fc\E";
    $fq =~ s/\\\././g;
    $fq =~ s/[0-9.]+/.*/g;
    @s = grep {/^$fq$/} @s;
    if (@s) {
      $sim{$f} = $s[0];
      delete $s{$s[0]};
    }
  }

  #for my $f (@f) {
  #  print "$f -> $sim{$f}\n";
  #}
  return \%sim;
}


sub fn {
  my ($dir, $f, $md5) = @_;
  return $dir->($f, $md5) if ref($dir);
  return "$dir/$md5-$f";
}

sub srcdiff {
  my ($pold, $old, $orev, $pnew, $new, $rev, %opts) = @_;

  my $d = '';
  my $fmax = $opts{'fmax'};

  my @old = sort keys %$old;
  my @new = sort keys %$new;
  my $sim = findsim(\@old, @new);

  for my $extra ('changes', 'filelist', 'spec', 'dsc') {
    if ($extra eq 'filelist') {
      my @xold = sort keys %$old;
      my @xnew = sort keys %$new;
      my %xold = map {$_ => 1} @xold;
      my %xnew = map {$_ => 1} @xnew;
      @xnew = grep {!$xold{$_}} @xnew;
      @xold = grep {!$xnew{$_}} @xold;
      if (@xold) {
	$d .= "\n";
	$d .= "old:\n";
	$d .= "----\n";
	$d .= "  $_\n" for @xold;
      }
      if (@xnew) {
	$d .= "\n";
	$d .= "new:\n";
	$d .= "----\n";
	$d .= "  $_\n" for @xnew;
      }
      next;
    }
    my @xold = grep {/\.$extra$/} sort keys %$old;
    my @xnew = grep {/\.$extra$/} sort keys %$new;
    my %xold = map {$_ => 1} @xold;
    if (@xnew || @xold) {
      $d .= "\n";
      $d .= "$extra files:\n";
      $d .= "-------".('-' x length($extra))."\n";
    }
    my $arg = '-ub';
    $arg = '-U0' if $extra eq 'changes';
    for my $f (@xnew) {
      if ($xold{$f}) {
	my $of = $f;
	delete $xold{$of};
	next if $old->{$of} eq $new->{$f};
	my $r = filediff(fn($pold, $of, $old->{$of}), fn($pnew, $f, $new->{$f}), %opts, 'diffarg' => $arg, 'fmax' => undef);
	$d .= adddiffheader($r, $of, $f);
      } else {
	$d .= "\n++++++ new $extra file:\n";
	my $r = filediff(undef, fn($pnew, $f, $new->{$f}), %opts, 'diffarg' => $arg, 'fmax' => undef);
	$d .= adddiffheader($r, undef, $f);
      }
    }
    if (%xold) {
      $d .= "\n++++++ deleted $extra files:\n";
      for my $f (sort keys %xold) {
	$d .= "--- $f\n";
      }
    }
    @old = grep {!/\.$extra$/} @old;
    @new = grep {!/\.$extra$/} @new;
  }

  my %oold = map {$_ => 1} @old;
  if ($d ne '' && (@new || @old)) {
    $d .= "\n";
    $d .= "other changes:\n";
    $d .= "--------------\n";
  }
  for my $f (@new) {
    my $of = $sim->{$f};
    if (defined $of) {
      delete $oold{$of};
      $d .= "\n++++++ $of -> $f\n" if $of ne $f;
      next if $old->{$of} eq $new->{$f};
      $d .= "\n++++++ $f\n" if $of eq $f;
    }
    if ($f =~ /\.(?:tgz|tar\.gz|tar\.bz2|tbz|tar\.xz|gem|obscpio)$/) {
      if (defined $of) {
	my @r = tardiff(fn($pold, $of, $old->{$of}), fn($pnew, $f, $new->{$f}), %opts);
	for my $r (@r) {
	  $d .= adddiffheader($r, $r->{'name'}, $r->{'name'});
	}
	next;
      } else {
	$d .= "\n++++++ $f (new)\n";
	next;
      }
    }
    if (defined $of) {
      my $r = filediff(fn($pold, $of, $old->{$of}), fn($pnew, $f, $new->{$f}), %opts);
      $d .= adddiffheader($r, $of, $f);
    } else {
      $d .= "\n++++++ $f (new)\n";
      my $r = filediff(undef, fn($pnew, $f, $new->{$f}), %opts);
      $d .= adddiffheader($r, $of, $f);
    }
  }
  if (%oold) {
    $d .= "\n++++++ deleted files:\n";
    for my $f (sort keys %oold) {
      $d .= "--- $f\n";
    }
  }
  return $d;
}

sub udiff {
  my ($pold, $old, $orev, $pnew, $new, $rev, %opts) = @_;

  $opts{'nodecomp'} = 1;
  my @changed;
  my @added;
  my @deleted;
  for (sort(keys %{ { %$old, %$new } })) {
    if (!defined($old->{$_})) {
      push @added, $_;
    } elsif (!defined($new->{$_})) {
      push @deleted, $_;
    } elsif ($old->{$_} ne $new->{$_}) {
      push @changed, $_;
    }
  }
  my $orevb = $orev && defined($orev->{'rev'}) ? " (revision $orev->{'rev'})" : '';
  my $revb = $rev && defined($rev->{'rev'}) ? " (revision $rev->{'rev'})" : '';
  my $d = '';
  for my $f (@changed) {
    $d .= "Index: $f\n" . ("=" x 67) . "\n";
    my $r = filediff(fn($pold, $f, $old->{$f}), fn($pnew, $f, $new->{$f}), %opts);
    $d .= adddiffheader($r, "$f$orevb", "$f$revb");
  }
  for my $f (@added) {
    $d .= "Index: $f\n" . ("=" x 67) . "\n";
    my $r = filediff(undef, fn($pnew, $f, $new->{$f}), %opts);
    $d .= adddiffheader($r, "$f (added)", "$f$revb");
  }
  for my $f (@deleted) {
    $d .= "Index: $f\n" . ("=" x 67) . "\n";
    my $r = filediff(fn($pold, $f, $old->{$f}), undef, %opts);
    $d .= adddiffheader($r, "$f$orevb", "$f (deleted)");
  }
  return $d;
}

sub datadiff {
  my ($pold, $old, $orev, $pnew, $new, $rev, %opts) = @_;

  my @changed;
  my @added;
  my @deleted;

  my $sim;
  if ($opts{'similar'}) {
    $sim = findsim([ keys %$old ], keys %$new);
  }

  my %done;
  for my $f (sort(keys %$new)) {
    my $of = $f;
    $of = $sim->{$f} if defined $sim->{$f};
    $done{$of} = 1;
    if (!defined($old->{$of})) {
      my @s = stat(fn($pnew, $f, $new->{$f}));
      my $r = filediff(undef, fn($pnew, $f, $new->{$f}), %opts);
      delete $r->{'state'};
      push @added, {'state' => 'added', 'diff' => $r, 'new' => {'name' => $f, 'md5' => $new->{$f}, 'size' => $s[7]}};
    } elsif ($old->{$of} ne $new->{$f}) {
      if ($opts{'doarchive'} && $f =~ /\.(?:tgz|tar\.gz|tar\.bz2|tbz|tar\.xz|gem|obscpio)$/) {
	my @r = tardiff(fn($pold, $of, $old->{$of}), fn($pnew, $f, $new->{$f}), %opts);
        if (@r == 0 && $f ne $of) {
	  # (almost) identical tars but renamed
	  my @os = stat(fn($pold, $of, $old->{$of}));
          my @s = stat(fn($pnew, $f, $new->{$f}));
          push @changed, {'state' => 'renamed', 'old' => {'name' => $of, 'md5' => $old->{$of}, 'size' => $os[7]}, 'new' => {'name' => $f, 'md5' => $new->{$f}, 'size' => $s[7]}};
        }
        if (@r == 1 && !$r[0]->{'old'} && !$r[0]->{'new'}) {
	  # tardiff was too big
	  my @os = stat(fn($pold, $of, $old->{$of}));
          my @s = stat(fn($pnew, $f, $new->{$f}));
          push @changed, {'state' => 'changed', 'diff' => $r[0], 'old' => {'name' => $of, 'md5' => $old->{$of}, 'size' => $os[7]}, 'new' => {'name' => $f, 'md5' => $new->{$f}, 'size' => $s[7]}};
          @r = ();
        }
	for my $r (@r) {
	  my $n = delete($r->{'name'});
	  my $state = delete($r->{'state'}) || 'changed';
	  $r->{'old'}->{'name'} = "$of/$r->{'old'}->{'name'}" if $r->{'old'};
	  $r->{'new'}->{'name'} = "$f/$r->{'new'}->{'name'}" if $r->{'new'};
	  $r->{'old'} ||= $r->{'new'};
	  $r->{'new'} ||= $r->{'old'};
	  push @changed, {'state' => $state, 'diff' => $r, 'old' => $r->{'old'}, 'new' => $r->{'new'}};
	  delete $r->{'old'};
	  delete $r->{'new'};
	}
      } else {
	my @os = stat(fn($pold, $of, $old->{$of}));
        my @s = stat(fn($pnew, $f, $new->{$f}));
	my $r = filediff(fn($pold, $of, $old->{$of}), fn($pnew, $f, $new->{$f}), %opts);
	delete $r->{'state'};
	push @changed, {'state' => 'changed', 'diff' => $r, 'old' => {'name' => $of, 'md5' => $old->{$of}, 'size' => $os[7]}, 'new' => {'name' => $f, 'md5' => $new->{$f}, 'size' => $s[7]}};
      }
    } elsif ($f ne $of) {
      my @os = stat(fn($pold, $of, $old->{$of}));
      my @s = stat(fn($pnew, $f, $new->{$f}));
      push @changed, {'state' => 'renamed', 'old' => {'name' => $of, 'md5' => $old->{$of}, 'size' => $os[7]}, 'new' => {'name' => $f, 'md5' => $new->{$f}, 'size' => $s[7]}};
    }
  }
  for my $of (grep {!$done{$_}} sort(keys %$old)) {
    my @os = stat(fn($pold, $of, $old->{$of}));
    my $r = filediff(fn($pold, $of, $old->{$of}), undef, %opts);
    delete $r->{'state'};
    push @added, {'state' => 'deleted', 'diff' => $r, 'old' => {'name' => $of, 'md5' => $old->{$of}, 'size' => $os[7]}};
  }
  return [ @changed, @added, @deleted ];
}

sub issues {
  my ($entry, $trackers, $ret) = @_;
  for my $tracker (@$trackers) {
    my @issues = $entry =~ /$tracker->{'regex'}/g;
    pop @issues if @issues & 1;	# hmm
    my %issues = @issues;
    for (keys %issues) {
      my $label = $tracker->{'label'};
      $label =~ s/\@\@\@/$issues{$_}/g;
      $ret->{$label} = {
	'name' => $issues{$_},
	'label' => $label,
        'tracker' => $tracker,
      };
    }
  }
}

sub issuediff {
  my ($pold, $old, $orev, $pnew, $new, $rev, $trackers, %opts) = @_;

  return [] unless @{$trackers || []};

  $trackers = [ @$trackers ];
  for (@$trackers) {
    $_ = { %$_ };
    $_->{'regex'} = "($_->{'regex'})" unless $_->{'regex'} =~ /\(/;
    $_->{'regex'} = "($_->{'regex'})";
    eval {
      $_->{'regex'} = qr/$_->{'regex'}/;
    };
    if ($@) {
      warn($@);
      $_->{'regex'} = qr/___this_reGExp_does_NOT_match___/;
    }
  }

  my %oldchanges;
  my %newchanges;
  for my $f (grep {/\.changes$/} sort(keys %$old)) {
    for (split(/------------------------------------------+/, readstr(fn($pold, $f, $old->{$f})))) {
      $oldchanges{Digest::MD5::md5_hex($_)} = $_;
    }
  }
  for my $f (grep {/\.changes$/} sort(keys %$new)) {
    for (split(/------------------------------------------+/, readstr(fn($pnew, $f, $new->{$f})))) {
      $newchanges{Digest::MD5::md5_hex($_)} = $_;
    }
  }
  my %oldissues;
  my %newissues;
  for my $c (keys %oldchanges) {
    next if exists $newchanges{$c};
    issues($oldchanges{$c}, $trackers, \%oldissues);
  }
  for my $c (keys %newchanges) {
    next if exists $oldchanges{$c};
    issues($newchanges{$c}, $trackers, \%newissues);
  }
  my @added;
  my @changed;
  my @deleted;
  for (sort keys %newissues) {
    if (exists $oldissues{$_}) {
      $newissues{$_}->{'state'} = 'changed';
      delete $oldissues{$_};
      push @changed, $newissues{$_};
    } else {
      $newissues{$_}->{'state'} = 'added';
      push @added, $newissues{$_};
    }
  }
  for (sort keys %oldissues) {
    $oldissues{$_}->{'state'} = 'deleted';
    push @deleted , $oldissues{$_};
  }
  for my $issue (@changed, @added, @deleted) {
    my $tracker = $issue->{'tracker'};
    my $url = $tracker->{'show-url'};
    if ($url) {
      $url =~ s/\@\@\@/$issue->{'name'}/g;
      $issue->{'url'} = $url;
    }
    $issue->{'tracker'} = $tracker->{'name'};
  }
  return [ @changed, @added, @deleted ];
}

sub diff {
  my ($pold, $old, $orev, $pnew, $new, $rev, $fmax, $tmax, $edir, $unified) = @_;
  my %opts;
  $opts{'fmax'} = $fmax if defined $fmax;
  $opts{'tmax'} = $tmax if defined $tmax;
  $opts{'edir'} = $edir if defined $edir;
  if ($unified) {
    return udiff($pold, $old, $orev, $pnew, $new, $rev, %opts);
  } else {
    $opts{'doarchive'} = 1;
    return srcdiff($pold, $old, $orev, $pnew, $new, $rev, %opts);
  }
}

1;
