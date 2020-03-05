#!/usr/bin/perl

use strict;
use warnings;
use Encode qw(encode_utf8);
use Term::Screen; # CPAN
use Config;
use Fcntl;
require 'syscall.ph';

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

sub cpuinfo {
	sysopen(my $fh, "/proc/cpuinfo", O_RDONLY)
		|| die "can't open /proc/cpuinfo: $!\n";
	sysread($fh, my $data, 300);
	close($fh);
	my @lines = split(/\n/, $data);
	foreach (@lines) {
		next unless $_ =~ m/model name/;
		$_ =~ s/(Processor|\(tm\))//ig;
		return substr($_, (index($_, ":")+2));
	}
}

sub meminfo {
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
		$convert->($used), $convert->($info{MemTotal}), "MB";
	return $fmtstr;
}

sub asort {
	my $aref = shift;
	my @sorted = sort { length($a) <=> length($b) } @$aref;
	return length($sorted[-1]);
}

sub cleanup {
	my $scrref = shift;
	$$scrref->normal();
	$$scrref->clrscr();
	$$scrref->curvis();
}

sub main {
	my $distro = lsb_info();

	my $table = {
		CPU => \&cpuinfo,
		MEM => \&meminfo,
		SYS => sub { return join(' ', uname("sysname"), uname("release")) },
		DIST => sub { return $distro->() },
		SHELL => sub { return $ENV{SHELL} },
		TERM => sub { return $ENV{TERM} },
		PROCS => sub { return sysinfo("procs") },
		UPTIME => sub { return uptime(sysinfo("uptime")) }
	};

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
	
	my $pad = 3;
	my $rel = asort(\@vals);
	my $run = 1;
	my $resized = 0;
	
	my $scr = Term::Screen->new();
	$scr->curinvis();
	$scr->clrscr();

	while ($run) {
		$SIG{INT} = sub { $run-- }; 
		$SIG{WINCH} = sub { $resized++ };
		
		if ($resized) {
			undef $scr;
			undef $resized;
			$scr = Term::Screen->new();
			$scr->clrscr();
		}

		for my $i (0..$#vals) {
			$scr->at($i, 0)->bold()->puts("$vals[$i]")
				->puts(" " x ($pad + $rel - length($vals[$i])))
				->puts($table->{$vals[$i]}->())
		}
		select(undef,undef,undef,0.5);
	}
	cleanup(\$scr);
}

main();
