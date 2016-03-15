#!__PERL__

# jksmsd v__VERSION__
# Copyright (c) Jeremy Kister 2016
# Released under Perl's Artistic License

# receive data from sms-client
# queue the text message
# announce to configured extensions that there's a message waiting


use strict;
use DBI;
use IO::Select;
use IO::Socket::INET;
use Getopt::Std;
use Sys::Syslog;
use Asterisk::AMI;
use Net::CIDR::Lite;
use POSIX qw(setsid);
use Sys::SigAction qw(set_sig_handler);

set_sig_handler('ALRM', sub { die "timeout!\n"; } );


my %opt;
getopts('Dc:fu:vh', \%opt);

if( $opt{h} ){
    print <<__EOH__;
    -D        Debug enable
    -c <file> config file [/etc/jksms.cfg]
    -f        run in foreground
    -u <user> username to switch to [nobody]
    -h        this help message
    -v        show version
__EOH__
    ;
    exit;
}elsif( $opt{v} ){
    print "__VERSION__\n";
    exit;
}

my $childpid;
$opt{c} ||= '/etc/jksms.cfg';
$opt{u} ||= 'nobody';

openlog( 'jksmsd', 'pid', 'local6' );

my ($uid,$gid) = (getpwnam($opt{u}))[2,3];

daemonize(60) unless $opt{f};

$SIG{USR1} = sub {
    $opt{D} = $opt{D} ? undef : 1;
    verbose( "USR1 received - changing debug" );
};

my ($fperm,$fuid) = (stat($opt{c}))[2,4];
unless( $fuid == $uid ){
    slowerr( "owner of $opt{c} is not $opt{u}.  chown $opt{u} $opt{c}." );
}

my $mode = sprintf("%04o", ( $fperm & 07777 ));
unless( $mode eq '0400' || $mode eq '0600' ){
    slowerr( "file mode of $opt{c} is not strict enough: chmod 0400 $opt{c} and re-secure the secret." );
}

if( $> == 0 || $< == 0){
    if( $uid && $gid ){
        debug( "switching to $uid/$gid" );
        $! = 0;
        $( = $) = $gid;
        slowerr( "unable to chgid $opt{u}: $!" ) if $!;
        $< = $> = $uid;
        slowerr( "unable to chuid $opt{u}: $!" ) if $!;
    }else{
        slowerr( "cannot chid to $opt{u}: uid for $opt{u} not found." );
    }
}else{
    slowerr( "cannot chid when not running as root." ) unless( $uid == $> );
}

my %config;
open(my $fh, $opt{c}) || slowerr( "cannot read $opt{c}: $!" );
while(<$fh>){
    chomp;
    s/#.*//g;
    next if(/^\s*$/);

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

$config{timeout} ||= 300;
$config{port}    ||= 5038;
$config{host}    ||= 'localhost';

if($config{allow}){
    $config{allow} .= ',127.0.0.0/8' unless($config{allow} =~ /127\.0\.0\.0\/8/);
}else{
    $config{allow} = '127.0.0.0/8';
}

slowerr( "couldnt get AMI user/pass" ) unless($config{username} && $config{secret});
if( $opt{D} ){
    for my $key (keys %config){
        warn "DEBUG: config: $key => $config{$key}\n";
    }
}

my $dbh = DBI->connect($config{dsn}, $config{dbun}, $config{dbpw}, {RaiseError => 1});

my $cidr = Net::CIDR::Lite->new;
foreach my $network (split /,/, $config{allow}){
    verbose( "will allow connections from $network" );
    $cidr->add($network);
}

my $sock = IO::Socket::INET->new(Listen    => 5,
                                 LocalPort => 6929,
                                 Proto     => 'tcp',
                                 Reuse     => 1,
                                 Blocking  => 1);

slowerr( "cannot bind to port 6929/tcp: $@" ) unless $sock;


eval {
    alarm(3);
    my $res = $dbh->selectrow_arrayref(
                  "SELECT COUNT(*) FROM sqlite_master" .
                  " WHERE type='table'" .
                  " AND name = 'queue'"
                                      );
    alarm(3);
    unless( $res->[0] ){
        debug( 'creating table/database' );
        $dbh->do( 'CREATE TABLE queue ('                .
                  ' id   INTEGER PRIMARY KEY NOT NULL,' .
                  ' addr INT NOT NULL,'                 .
                  ' msg  TEXT NOT NULL)'                
                ) || slowerr( "cannot run query: ", $dbh->errstr );
    }

    alarm(0);
};
alarm(0);
slowerr( "problem with database at $config{database}: $@" ) if $@;

my $timeout = 1;
my $queue = IO::Select->new();
$queue->add($sock);

my $notify;
while( 1 ){
    my ($rh_set) = IO::Select->select($queue, undef, undef, $timeout);
    debug( "running event loop" );

    my $time = time();
    if( ($time - $notify) >= $config{timeout} ){
        debug( "in notification area" );

        alarm(5);
        my $sql = 'SELECT DISTINCT addr FROM queue';
        my $sth = $dbh->prepare($sql);
        $sth->execute;
        my %names;
        
        while(my $row = $sth->fetchrow_arrayref){
            $names{ $config{name}{$row->[0]} } = 1;
        }
        alarm(0);

        $notify = $time;
        if( keys %names ){
            my $queue = join(' and ', (keys %names));

            originate( "text queued from ${queue}.  dial $config{dialcode}." );

            $timeout = $config{timeout};
        }else{
            $timeout = undef;
        }
    }

    foreach my $rh ( @{$rh_set} ){
        # if it is the main socket then we have an incoming connection and
        # we should accept() it and then add the new socket to the $queue

        alarm(10);
        if( $rh == $sock ){
            my $ns = $rh->accept();
            my $peerhost = $ns->peerhost();
            debug( "connection from $peerhost" );

            if( $cidr->find($peerhost) ){
                debug( "connection from $peerhost accepted" );
                $queue->add($ns);
            }else{
                verbose( "denying connection from $peerhost" );
                close($rh);
            }
        }else{
            # otherwise it is an ordinary socket and we should read and process the request
            if( defined(my $buf=<$rh>) ){
                debug( "buf: [$buf]" );

                if( $buf =~ /^QUIT/ ){
                    print $rh "Bye!\r\n";
                    $queue->remove($rh);
                    close($rh);
                }else{
                    my($cmd,$ver) = $buf =~ m#^(.+)\sjksms/(\d+\.\d+)#;
                    if( $ver eq '1.0' ){
                        if( $cmd =~ /^QUEUE:([^~]+)~([^~]+)~/ ){
                            my($addr,$msg) = ($1,$2);
                        
                            verbose( "queued message from [$addr]: [$msg]" );

                            $dbh->do( 'INSERT INTO queue (addr,msg) VALUES (' .
                                      $dbh->quote($addr) . ',' .
                                      $dbh->quote($msg)  . ')'
                                    ) || slowerr( "cannot insert query: ", $dbh->errstr);

                            print $rh "OK\r\n";

                            $notify = time();
                            $timeout = $config{timeout};
                            originate( "text queued from $config{name}{$addr}.  dial $config{dialcode}." );
                        }elsif( $cmd =~ /^TEST/ ){
                            debug( "test message received" );
                            print $rh "OK\r\n";
                        }else{
                            print $rh "not understood\r\n";
                        }
                    }else{
                        print $rh "unsupported\r\n";
                    }
                }

            }else{ # the client has closed the socket
                # remove the socket from the $queue and close it
                $queue->remove($rh);
                close($rh);
            }
        }
        alarm(0);
    }
} 


sub originate {
    my $msg = join('', @_);

    debug( "msg to originate is: $msg" );
    my $m = Asterisk::AMI->new( PeerAddr => $config{host},
                                PeerPort => $config{port},
                                Username => $config{username},
                                Secret   => $config{secret},
                                OriginateHack => 1,
                              );

    slowerr( "unable to connect to AMI" ) unless $m;

    my $r = $m->action( {Action   => 'Originate',
                         Channel  => $config{channel},
                         Context  => $config{context},
                         Exten    => $config{exten},
                         Priority => $config{priority},
                         Async    => 1,
                         Variable => "TEXT=J K S M S.. $msg",
                        });

    # doesnt mean call worked, just that it was queued.
    slowerr( "unable to queue call" ) unless $r;
}


sub daemonize {
    my $to = shift;

    chdir('/');
    fork && exit;
    close STDIN;   open( STDIN,  '<',  "/dev/null" );
    close STDOUT;  open( STDOUT, '>>', "/dev/null" );
    close STDERR;  open( STDERR, '>>', "/dev/null" );
    setsid();

    $SIG{HUP} = $SIG{QUIT} = $SIG{INT} = $SIG{TERM} = sub { sighandler( @_ ) };

    open(my $pid, ">__PIDDIR__/jksmsd.pid") || die "cannot write to __PIDDIR__/jksmsd.pid: $!\n";
    print $pid "$$\n";
    close $pid;

    # run as 2 processes
    while( 1 ){
        if( $childpid = fork ){
            # parent
            wait;
            my $xcode = $?;
            $childpid = undef;
            verbose( "jksmsd exited with code $xcode - restarting" );
            sleep $to;
        }else{
            # child
            return;
        }
    }
}

sub sighandler {
    unlink( "__PIDDIR__/jksmsd.pid" ) || verbose( "cannot unlink __PIDDIR__/jksmsd.pid: $!" );
    kill "TERM", $childpid;
    wait;
    verbose( "caught signal SIG$_[0] - exiting" );
    exit;
}

sub verbose {
        my $msg = join('', @_);

        warn "[jksmsd]: $msg\n" if $opt{f};
        syslog( 'info', $msg );
}

sub debug {
    verbose(@_) if $opt{D};
}

sub slowerr {
    verbose(@_);   
    sleep 5;
    exit 1;
}
