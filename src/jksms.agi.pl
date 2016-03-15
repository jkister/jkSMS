#!__PERL__

# jksms.agi v__VERSION__
# Copyright (c) Jeremy Kister 2016
# Released under Perl's Artistic License

# AGI script to check, delete, and reply to text messages

use strict;
use DBI;
use Getopt::Std;
use Asterisk::AGI;
use Net::CIDR::Lite;
use Sys::SigAction qw(set_sig_handler);

set_sig_handler('ALRM', sub { die "timeout!"; } );
alarm(120);

my %opt;
getopts('Dc:', \%opt);
# D Debug
# c config file

$opt{c} ||= '/etc/jksms.cfg';
open(my $fh, $opt{c}) || die "cannot read $opt{c}: $!\n";

my %config;
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

my $agi = Asterisk::AGI->new();
my %input = $agi->ReadParse();

my @day   = qw/Sun Mon Tue Wed Thu Fri Sat/;
my @month = qw/Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;

my $dbh = DBI->connect($config{dsn}, $config{dbun}, $config{dbpw}, {RaiseError => 1});

$ENV{PATH} = '/usr/lib:/usr/sbin:/var/qmail/bin:/usr/bin';

while( 1 ){
    my $sql = 'SELECT id,addr,msg FROM queue';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my %queue;
    while(my $row = $sth->fetchrow_arrayref){
        $queue{$row->[0]} = { addr => $row->[1], msg => $row->[2] };
    }
    
    my $count = (keys %queue);
    
    my $msg = ($count == 0 || $count > 1) ? "There are $count new texts. " : 'There is 1 new text. ';
    if( $count == 0 ){
        $msg .= " Goodbye.";
        swift( $msg );
        $agi->hangup();
        exit;
    }
    
    my $r;
    if( $count > 1 ){
        for my $id (keys %queue){
            my $name = $config{name}{ $queue{$id}{addr} };
            $msg .= "Press $id for message from ${name}. ";
        }
        swift( "$msg,5000,2" );
        $r = $agi->get_variable('SWIFT_DTMF');
    }else{
        ($r) = keys %queue;
    }
    
    my $loop;
    while( $loop < 50 ){
        $loop++;

        my $from = $config{name}{ $queue{$r}{addr} } || 'unknown';
        $msg = "message from $from .  $queue{$r}{msg} . ";
        $msg .= 'Press 1 to reply O K.  2 for yes . 3 for no . 4 to re-play . or 5 to delete.';

        swift( "$msg,5000,1" );
        my $a = $agi->get_variable('SWIFT_DTMF');
    
        if( $a == 1 || $a == 2 || $a == 3 ){
            my ($sec,$min,$hour,$mday,$mon,$year,$wday,$isdst) = (localtime)[0,1,2,3,4,5,6,8];
            $year += 1900;
            my $date = $day[$wday] . ', ' . sprintf("%02d", $wday) .
                       "$month[$mon] $year " .
                       sprintf("%02d", $hour) . ':' .
                       sprintf("%02d", $min)  . ':' .
                       sprintf("%02d", $sec);
            $date .= $isdst ? ' EDT' : ' EST';

            my $answer = ($a == 1) ? 'OK' :
                         ($a == 2) ? 'Yes' :
                                     'No';

            open(my $sm, "| sendmail -t -F $config{from}" ) || die "cannot fork sendmail: $!\n";
            print $sm "To: $queue{$r}{addr}\n",
                      "From: $config{from}\n",
                      "Date: $date\n",
                      "\n",
                      "$answer\n";
            close $sm;

            swift( "replied with $answer" );

            $dbh->do( 'DELETE FROM queue WHERE id = ' . $dbh->quote($r) );

            last;
        }elsif( $a == 4 ){
            next;
        }elsif( $a == 5 ){
            $dbh->do( 'DELETE FROM queue WHERE id = ' . $dbh->quote($r) );
            swift( 'message deleted.' );
            last;
        }
    }
}



sub swift {
    my $msg = join('', @_);

    $agi->exec('Swift', $msg);
}

sub verbose {
    my $msg = join('', @_);

    warn "[$0]: $msg\n";
    $agi->verbose($msg, 1);
}

sub debug {
    verbose(@_) if $opt{D};
}
