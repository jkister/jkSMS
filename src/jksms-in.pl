#!__PERL__

# jksms-in.pl v__VERSION__
# Copyright (c) 2016 Jeremy Kister
# Released under Perl's Artistic License

# read email from input
# send properly formatted data to the listener on the asterisk server

use strict;
use Getopt::Std;
use IO::Socket::INET;
use Sys::SigAction qw(set_sig_handler);

set_sig_handler('ALRM', sub { die "timeout!"; } );
alarm(30);

my %opt;
getopts('Dc:', \%opt);
# D Debug
# c config file

$opt{c} ||= '/etc/jksms.cfg';
my %config;
open(my $fh, $opt{c}) || die "cannot read $opt{c}: $!\n";
while(<$fh>){
    s/#.*//g;
    next if(/^\s*$/);
    chomp;

    if( /^([^:]+)\s*[:=]\s*(.+)/ ){
        my($k,$v) = ($1,$2);
        if( $k eq 'name' ){
            my ($addr,$name) = split(/=/, $v);
            $config{name}{$addr} = $name;
        }else{
            $config{$k} = $v;
        }
    }
}
close $fh;

tmp_fail( "no peer host in config file" ) unless $config{peer};
perm_fail( "invalid sender" ) unless( $config{name}{ $ENV{SENDER} } );

while(<STDIN>){
    chomp;
    if( /^X-Mms-/i || m#^Content-Type: multipart/mixed#i ){
        while(<STDIN>){
            if( /^From:.*<?(\S+\@\S+\.\S+)>?/i ){ # meh
                my $sender = $1;
                perm_fail( "unknown sender (m): $sender" ) unless $config{name}{$sender};
            }
            last if( m#^Content-Type: text/html# );
        }
    }elsif( /^From:\s*<?(\S+\@\S+\.\S+)>?/i ){
        my $sender = $1;
        perm_fail( "unknown sender: $sender" ) unless $config{name}{$sender};
    }

    last if( /^\s*$/ );
}

my @body;
while(<STDIN>){
    chomp;
    next if( /[<>]/ || /^\s*$/ );
    last if( /^------/ ); # meh.
    s/^\s*//g;
    push @body, $_;
}

my $msg = join(' ', @body);

my $sock = IO::Socket::INET->new( PeerAddr => $config{peer},
                                  PeerPort => 6929,
                                  Proto    => 'tcp');

tmp_fail( "cannot connect to $config{peer}" ) unless $sock;

print $sock "QUEUE:$ENV{SENDER}~${msg}~ jksms/1.0\r\n";

chomp(my $r = <$sock>);
if($r =~ /^OK/){
    print $sock "QUIT\r\n";
    print "mail converted successfully\n";
    exit 0;
}else{
    tmp_fail( "error converting mail" );
}



sub perm_fail {
    my $msg = join('', @_);

    print "$msg\n";
    exit 100;
}

sub tmp_fail {
    my $msg = join('', @_);

    print "$msg\n";
    exit 111;
}
