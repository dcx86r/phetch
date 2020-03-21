#!/usr/bin/perl

use strict;
use warnings;
use Encode qw(encode_utf8);
use Term::Screen; # CPAN
use Term::ANSIColor; # core
use Config;
use Fcntl;
require 'syscall.ph';

# ToDo - print colors
# terminal dimens geometry would be nice...

# comment out any unwanted values below
sub user_config { 
	return q{
		CPU
		SYS
		DIST
		MEM
		SHELL
		TERM
		UPTIME
		PROCS
	}
}

sub uname {
	my $key = shift;
	my $x = "Z[65]" x 6;
	my $v = pack($x, {
			sysname => "",
			nodename => "", 
			release  => "", 
			version  => "", 
			machine  => "", 
			domainname => ""
		}
	);
 	syscall(SYS_uname(), $v);
 	my $upd = {};
 	@{$upd}{qw(sysname nodename release version machine domainname)} 
 		= unpack $x, $v;
	my %z = %{$upd};
	return $z{$key};
}

sub sysinfo {
	my $key = shift;
#	...sizeof(__kernel_ulong_t)-sizeof(__u32)...
	my $padding = 20-2*$Config{longlongsize}-$Config{intsize};
	my $x ="q(Q)9vvQQVZ[$padding]";
	my $v = pack($x, {
		uptime    => 0, # __kernel_long_t (8 bytes)
		load1m    => 0, # __kernel_ulong_t (8 bytes)
		load5m    => 0,
		load15m   => 0,
		totalram  => 0, # "
		freeram   => 0, # "
		sharedram => 0, # "
		bufferram => 0, # "
		totalswap => 0, # "
		freeswap  => 0, # "
# procs includes thread count
		procs     => 0, # __u16 (2 bytes)
		pad       => 0, # __u16
		totalhigh => 0, # __kernel_ulong_t
		freehigh  => 0, # __kernel_ulong_t
		mem_unit  => 0, # __u32 (4 bytes)
		_f        => "" # padding to 64 bytes
	});

	syscall(SYS_sysinfo(), $v);
	my $upd = {};
	@{$upd}{qw(uptime load1m load5m load15m totalram freeram sharedram 
	bufferram totalswap freeswap procs pad totalhigh freehigh mem_unit _f)}
		= unpack $x, $v;
	my %z = %{$upd};
	return $z{$key};
}

sub uptime {
	my $s = shift;
	my @u = ($s/3600, $s%3600/60, $s%60);
	my $time;
	open(my $fh, ">", \$time);
	printf $fh "%.2i:%.2i:%.2i", $u[0], $u[1], $u[2];
	return $time;
}

sub lsb_info {
	my $line;
	unless ($line) {
		return 0 unless	grep { -e "$_/lsb_release" } split(/:/, $ENV{PATH});
		chomp(my @info = qx/lsb_release -a 2>&1/);
		@info = grep { $_ =~ m/Description/ } @info;
		($line = pop(@info)) =~ s/^.*\t//;
	}
	return sub { return $line };
}

sub cpu_info {
	sysopen(my $fh, "/proc/cpuinfo", O_RDONLY)
		|| die "can't open /proc/cpuinfo: $!\n";
	sysread($fh, my $data, 300);
	close($fh);
	my @lines = split(/\n/, $data);
	foreach (@lines) {
		next unless $_ =~ m/model name/;
		$_ =~ s/(Processor|\(tm\))//ig;
		my $str = substr($_, (index($_, ":")+2));
		return sub { return $str };
	}
}

sub mem_info {
	sysopen(my $fh, "/proc/meminfo", O_RDONLY)
		|| die "can't open /proc/meminfo: $!\n";
	sysread($fh, my $data, 300);
	close($fh);
	my $convert = sub {
		return (shift) / 1024;
	};
	my @tmp = map { split(/:/, $_) } split(/\n/, $data);
	my %info = @tmp;
	for my $key (sort keys %info) {
		$info{$key} =~ s/^\s+|\skB$//g;
	}
	my $used = ($info{MemTotal} - $info{MemFree}) 
		- ($info{Buffers} + $info{Cached});
	my $fmtstr;
	open($fh, ">", \$fmtstr);
	printf $fh '%d/%d %s', 
		$convert->($used), $convert->($info{MemTotal}), "MiB";
	return $fmtstr;
}

sub asort {
	my $aref = shift;
	my @sorted = sort { length($a) <=> length($b) } @$aref;
	return length($sorted[-1]);
}

sub draw_border {
	my $rlen = shift;
	my $brdr = shift;
	my $bccref = shift;
	my $title = shift;
	my $enc = sub { 
		my $key = shift;
# probably should run everything through this
		return colored(encode_utf8(chr(${$bccref}{$key})), "green");
	};

	my $title_pos = $title ? (($rlen+2)/2) - (length($title)/2) : 0;
	my @colored = split(/@/, $title);
	my $title_str = colored($colored[0], "blue");
	$title_str .= colored("@", "yellow");
	$title_str .= colored($colored[1], "magenta");

	my $str = do {
		if ($brdr eq "top") {
			$enc->('tl') . ($enc->('hc') x ($title_pos-1)) . 
			$enc->('lp') . $title_str . $enc->('rp') .
			$enc->('hc') x (($rlen) - ($title_pos+length($title))+1) .
			$enc->('tr')
		} elsif ($brdr eq "bottom") {
			$enc->('bl') . ($enc->('hc') x ($rlen+2)) . $enc->('br')
		}
	};
}

sub cleanup {
	my $scrref = shift;
	$$scrref->normal();
	$$scrref->clrscr();
	$$scrref->curvis();
}

sub main {
# CPU and SYS also static
	my $cpu = cpu_info();
#	print $cpu->(); exit;
	my $distro = lsb_info();
	my $title = sub { return join('@', $ENV{USER}, uname("nodename")) };

	my $table = {
		CPU => sub { return $cpu->() },
		MEM => \&mem_info,
		SYS => sub { return join(' ', uname("sysname"), uname("release")) },
		DIST => sub { return $distro->() },
		SHELL => sub { return $ENV{SHELL} },
		TERM => sub { return $ENV{TERM} },
		PROCS => sub { return sysinfo("procs") },
		UPTIME => sub { return uptime(sysinfo("uptime")) }
	};

	my %bcc = ( # border character codes
		'tl' => 0x256D, # top left
		'tr' => 0x256E, # top right
		'bl' => 0x2570, # bottom left
		'br' => 0x256F, # bottom right
		'hc' => 0x2550, # horizontal char
		'vc' => 0x2551, # vertical char
		'lp' => 0x2561, # left perpendicular
		'rp' => 0x255E, # right perpendicular
	);

	my @vals = split(/\n/, user_config());
	foreach (@vals) { $_ =~ s/^\s+|\s+$//g }
	@vals = grep { $_ !~ m/^(#|$)/ } @vals;
	unless ($distro) {
		@vals = grep { $_ ne "DIST" } @vals;
		print STDERR "lsb_release not found\n";
	}
	my @errval = grep { ! defined $table->{$_} } @vals;
	if (@errval) { 
		print "Invalid config value(s): " . join(', ', @errval);
		exit 1;
	}

	my $rel = asort(\@vals);
	my $pad = 3;
	my @vstrl;
	my $rlen;
	my $run = 1;
	my $resized = 0;

# setting max width here based on values that should stay constant
	for my $i (0..$#vals) {
		unless ($#vstrl == $#vals) {
			push @vstrl, $table->{$vals[$i]}->();
			next;
		}
	}

	my $top;
	my $bottom;
	my $title_pos;
	my $vlen = asort(\@vstrl);
	$rlen = ($pad + $rel + $vlen);
	$top = draw_border($rlen, "top", \%bcc, $title->());
	$bottom = draw_border($rlen, "bottom", \%bcc);
	
	my $scr = Term::Screen->new();
	$scr->curinvis();
	$scr->clrscr();

	while ($run) {
		$SIG{INT} = sub { $run-- }; 
		$SIG{WINCH} = sub { $resized++ };	
		
		if ($resized) {
			undef $scr;
			undef $resized;
# abstract into redraw sub?
			$scr = Term::Screen->new();
			$scr->clrscr();
#			border redraw
		}

		$scr->at(0,0)->puts($top);
		$scr->at((3+scalar(@vals)),0)->puts($bottom);

		for my $i (0..$#vals) {
			my $desc = colored($vals[$i], "red");
			my $val = $table->{$vals[$i]}->();
			$scr->at((2+$i), 2)->bold()->puts($desc)->normal()
				->puts(" " x ($pad + $rel - length($vals[$i])))
				->puts($val);
		}
		sleep 1;
	}
	cleanup(\$scr);
}

main();
