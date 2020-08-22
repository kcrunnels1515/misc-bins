#! /usr/bin/perl -w
#
# reads an article on STDIN, mails any copies if required,
# signs the article and posts it.
#
#
# Copyright (c) 2002-2020 Urs Janssen <urs@tin.org>,
#                         Marc Brockschmidt <marc@marcbrockschmidt.de>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
#
# TODO: - extend debug mode to not delete tmp-files and be more verbose
#       - add pid to pgptmpf to allow multiple simultaneous instances
#       - check for /etc/nntpserver (and /etc/news/server)
#       - add $PGPOPTS, $PGPPATH and $GNUPGHOME support
#       - cleanup and remove duplicated code
#       - option to convert CRLF to LF in input
#       - use STARTTLS (if Net::NNTP is recent enough and server supports it)?
#       - quote inpupt properly before passing to shell
#       - if (!defined $ENV{'GPG_TTY'}) {if (open(my $T,'-|','tty')) {
#           chomp(my $tty=<$T>); close($T);
#           $ENV{'GPG_TTY'}=$tty if($tty =~ m/^\//)}}
#         for gpg?
#

use strict;
use warnings;

# version Number
my $version = "1.1.51";

my %config;

# configuration, may be overwritten via ~/.tinewsrc
$config{'NNTPServer'}	= 'news';	# your NNTP servers name, may be set via $NNTPSERVER
$config{'NNTPPort'}		= 119;	# NNTP-port, may be set via $NNTPPORT
$config{'NNTPUser'}		= '';	# username for nntp-auth, may be set via ~/.newsauth or ~/.nntpauth
$config{'NNTPPass'}		= '';	# password for nntp-auth, may be set via ~/.newsauth or ~/.nntpauth

$config{'PGPSigner'}	= '';	# sign as who?
$config{'PGPPass'}		= '';	# pgp2 only
$config{'PathtoPGPPass'}= '';	# pgp2, pgp5, pgp6 and gpg
$config{'PGPPassFD'}	= 9;	# file descriptor used for input redirection of PathtoPGPPass; GPG1, GPG2, PGP5 and PGP6 only

$config{'pgp'}			= '/usr/bin/pgp';	# path to pgp
$config{'PGPVersion'}	= '2';	# Use 2 for 2.X, 5 for PGP5, 6 for PGP6, GPG or GPG1 for GPG1 and GPG2 for GPG2
$config{'digest-algo'}	= 'MD5';# Digest Algorithm for GPG. Must be supported by your installation

$config{'Interactive'}	= 'yes';# allow interactive usage

$config{'sig_path'}		= glob('~/.signature');	# path to signature
$config{'add_signature'}= 'yes';# Add $config{'sig_path'} to posting if there is no sig
$config{'sig_max_lines'}= 4;	# max number of signatures lines

$config{'sendmail'}		= '/usr/sbin/sendmail -i -t'; # set to '' to disable mail-actions

$config{'pgptmpf'}		= 'pgptmp';	# temporary file for PGP.

$config{'pgpheader'}	= 'X-PGP-Sig';
$config{'pgpbegin'}		= '-----BEGIN PGP SIGNATURE-----';	# Begin of PGP-Signature
$config{'pgpend'}		= '-----END PGP SIGNATURE-----';	# End of PGP-Signature

$config{'canlock_algorithm'}	= 'sha1'; 	# Digest algorithm used for cancel-lock and cancel-key; sha1, sha256 and sha512 are supported
# $config{'canlock_secret'}	= '~/.cancelsecret';		# Path to canlock secret file

# $config{'ignore_headers'} = '';		# headers to be ignored during signing

$config{'PGPSignHeaders'} = ['From', 'Newsgroups', 'Subject', 'Control',
	'Supersedes', 'Followup-To', 'Date', 'Injection-Date', 'Sender', 'Approved',
	'Message-ID', 'Reply-To', 'Cancel-Key', 'Also-Control',
	'Distribution'];
$config{'PGPorderheaders'} = ['from', 'newsgroups', 'subject', 'control',
	'supersedes', 'followup-To', 'date', 'injection-date', 'organization',
	'lines', 'sender', 'approved', 'distribution', 'message-id',
	'references', 'reply-to', 'mime-version', 'content-type',
	'content-transfer-encoding', 'summary', 'keywords', 'cancel-lock',
	'cancel-key', 'also-control', 'x-pgp', 'user-agent'];

################################################################################

use Getopt::Long qw(GetOptions);
use Net::NNTP;
use Time::Local;
use Term::ReadLine;

(my $pname = $0) =~ s#^.*/##;

# read config file (first match counts) from
# $XDG_CONFIG_HOME/tinewsrc ~/.config/tinewsrc ~/.tinewsrc
# if present
my $TINEWSRC = undef;
my (@try, %seen);
if ($ENV{'XDG_CONFIG_HOME'}) {
	push(@try, (glob("$ENV{'XDG_CONFIG_HOME'}/tinewsrc"))[0]);
}
push(@try, (glob('~/.config/tinewsrc'))[0], (glob('~/.tinewsrc'))[0]);

foreach (grep { ! $seen{$_}++ } @try) {
	last if (open($TINEWSRC, '<', $_));
	$TINEWSRC = undef;
}
if (defined($TINEWSRC)) {
	while (defined($_ = <$TINEWSRC>)) {
		if (m/^([^#\s=]+)\s*=\s*(\S[^#]+)/io) {
			chomp($config{$1} = $2);
		}
	}
	close($TINEWSRC);
}

# as of tinews 1.1.51 we use 3 args open() to pipe to sendmail
# thus we remove any leading '|' to avoid syntax errors;
# for redirections use cat etc.pp., eg. 'cat > /tmp/foo'
$config{'sendmail'} =~ s/^\s*\|\s*//io;

# digest-algo is case sensitive and should be all uppercase
$config{'digest-algo'} = uc($config{'digest-algo'});

# these env-vars have higher priority (order is important)
$config{'NNTPServer'} = $ENV{'NEWSHOST'} if ($ENV{'NEWSHOST'});
$config{'NNTPServer'} = $ENV{'NNTPSERVER'} if ($ENV{'NNTPSERVER'});
$config{'NNTPPort'} = $ENV{'NNTPPORT'} if ($ENV{'NNTPPORT'});

# Get options:
$Getopt::Long::ignorecase=0;
$Getopt::Long::bundling=1;
GetOptions('A|V|W|O|no-organization|h|headers' => [], # do nothing
	'debug|D|N'	=> \$config{'debug'},
	'port|p=i'	=> \$config{'NNTPPort'},
	'no-sign|X'	=> \$config{'no_sign'},
	'no-control|R'	=> \$config{'no_control'},
	'no-signature|S'	=> \$config{'no_signature'},
	'no-canlock|L'	=> \$config{'no_canlock'},
	'no-injection-date|I'	=> \$config{'no-injection-date'},
	'force-auth|Y'	=> \$config{'force_auth'},
	'approved|a=s'	=> \$config{'approved'},
	'control|c=s'	=> \$config{'control'},
	'canlock-algorithm=s'	=> \$config{'canlock_algorithm'},
	'distribution|d=s'	=> \$config{'distribution'},
	'expires|e=s'	=> \$config{'expires'},
	'from|f=s'	=> \$config{'from'},
	'ignore-headers|i=s'	=> \$config{'ignore_headers'},
	'followupto|w=s'	=> \$config{'followup-to'},
	'newsgroups|n=s'	=> \$config{'newsgroups'},
	'replyto|r=s'	=> \$config{'reply-to'},
	'savedir|s=s'	=> \$config{'savedir'},
	'subject|t=s'	=> \$config{'subject'},
	'references|F=s'	=> \$config{'references'},
	'organization|o=s'	=> \$config{'organization'},
	'path|x=s'	=> \$config{'path'},
	'help|H'	=> \$config{'help'},
	'version|v'	=> \$config{'version'}
);

foreach (@ARGV) {
	print STDERR "Unknown argument $_.";
	usage();
}

if ($config{'version'}) {
	version();
	exit 0;
}

usage() if ($config{'help'});

my $sha_mod=undef;
# Cancel-Locks require some more modules
if ($config{'canlock_secret'} && !$config{'no_canlock'}) {
	$config{'canlock_algorithm'} = lc($config{'canlock_algorithm'});
	# we support sha1, sha256 and sha512, fallback to sha1 if something else is given
	if (!($config{'canlock_algorithm'} =~ /^sha(1|256|512)$/)) {
		warn "Digest algorithm " . $config{'canlock_algorithm'} . " not supported. Falling back to sha1.\n" if $config{'debug'};
		$config{'canlock_algorithm'} = 'sha1';
	}
	if ($config{'canlock_algorithm'} eq 'sha1') {
		foreach ('Digest::SHA qw(sha1)', 'Digest::SHA1()') {
			eval "use $_";
			if (!$@) {
				($sha_mod = $_) =~ s#( qw\(sha1\)|\(\))##;
				last;
			}
		}
		foreach ('MIME::Base64()', 'Digest::HMAC_SHA1()') {
			eval "use $_";
			if ($@ || !defined($sha_mod)) {
				$config{'no_canlock'} = 1;
				warn "Cancel-Locks disabled: Can't locate ".$_."\n" if $config{'debug'};
				last;
			}
		}
	} elsif ($config{'canlock_algorithm'} eq 'sha256') {
		foreach ('MIME::Base64()', 'Digest::SHA qw(sha256 hmac_sha256)') {
			eval "use $_";
			if ($@) {
	 			$config{'no_canlock'} = 1;
				warn "Cancel-Locks disabled: Can't locate ".$_."\n" if $config{'debug'};
				last;
			}
		}
	} else {
		foreach ('MIME::Base64()', 'Digest::SHA qw(sha512 hmac_sha512)') {
			eval "use $_";
			if ($@) {
	 			$config{'no_canlock'} = 1;
				warn "Cancel-Locks disabled: Can't locate ".$_."\n" if $config{'debug'};
				last;
			}
		}
	}
}

my $term = Term::ReadLine->new('tinews');
my $attribs = $term->Attribs;
my $in_header = 1;
my (%Header, @Body, $PGPCommand);

if (! $config{'no_sign'}) {
	$config{'PGPSigner'} = $ENV{'SIGNER'} if ($ENV{'SIGNER'});
	$config{'PathtoPGPPass'} = $ENV{'PGPPASSFILE'} if ($ENV{'PGPPASSFILE'});
	if ($config{'PathtoPGPPass'}) {
		open(my $PGPPass, '<', (glob($config{'PathtoPGPPass'}))[0]) or
			$config{'Interactive'} && die("$0: Can't open ".$config{'PathtoPGPPass'}.": $!");
		chomp($config{'PGPPass'} = <$PGPPass>);
		close($PGPPass);
	}
	if ($config{'PGPVersion'} eq '2' && $ENV{'PGPPASS'}) {
		$config{'PGPPass'} = $ENV{'PGPPASS'};
	}
}

# Remove unwanted headers from PGPSignHeaders
if (${config{'ignore_headers'}}) {
	my @hdr_to_ignore = split(/,/, ${config{'ignore_headers'}});
	foreach my $hdr (@hdr_to_ignore) {
		@{$config{'PGPSignHeaders'}} = map {lc($_) eq lc($hdr) ? () : $_} @{$config{'PGPSignHeaders'}};
	}
}
# Read the message and split the header
readarticle(\%Header, \@Body);

# Add signature if there is none
if (!$config{'no_signature'}) {
	if ($config{'add_signature'} && !grep {/^-- /} @Body) {
		if (-r glob($config{'sig_path'})) {
			my $l = 0;
			push @Body, "-- \n";
			open(my $SIGNATURE, '<', glob($config{'sig_path'})) or die("Can't open " . $config{'sig_path'} . ": $!");
			while (<$SIGNATURE>) {
				die $config{'sig_path'} . " longer than " . $config{'sig_max_lines'}. " lines!" if (++$l > $config{'sig_max_lines'});
				push @Body, $_;
			}
			close($SIGNATURE);
		} else {
			if ($config{'debug'}) {
				warn "Tried to add " . $config{'sig_path'} . ", but it is unreadable";
			}
		}
	}
}

# import headers set in the environment
if (!defined($Header{'reply-to'})) {
	if ($ENV{'REPLYTO'}) {
		chomp($Header{'reply-to'} = "Reply-To: " . $ENV{'REPLYTO'});
		$Header{'reply-to'} .= "\n";
	}
}
foreach ('DISTRIBUTION', 'ORGANIZATION') {
	if (!defined($Header{lc($_)}) && $ENV{$_}) {
		chomp($Header{lc($_)} = ucfirst($_).": " . $ENV{$_});
		$Header{lc($_)} .= "\n";
	}
}

# overwrite headers if specified via cmd-line
foreach ('Approved', 'Control', 'Distribution', 'Expires',
	'From', 'Followup-To', 'Newsgroups',' Reply-To', 'Subject',
	'References', 'Organization', 'Path') {
	next if (!defined($config{lc($_)}));
	chomp($Header{lc($_)} = $_ . ": " . $config{lc($_)});
	$Header{lc($_)} .= "\n";
}

# verify/add/remove headers
foreach ('From', 'Subject') {
	die("$0: No $_:-header defined.") if (!defined($Header{lc($_)}));
}

$Header{'date'} = "Date: ".getdate()."\n" if (!defined($Header{'date'}) || $Header{'date'} !~ m/^[^\s:]+: .+/o);
$Header{'injection-date'} = "Injection-Date: ".getdate()."\n" if (!$config{'no-injection-date'});

if (defined($Header{'user-agent'})) {
	chomp $Header{'user-agent'};
	$Header{'user-agent'} = $Header{'user-agent'}." ".$pname."/".$version."\n";
}

delete $Header{'x-pgp-key'} if (!$config{'no_sign'} && defined($Header{'x-pgp-key'}));


# No control messages allowed when using -R|--no-control
if ($config{'no_control'} and $Header{control}) {
	print STDERR "No control messages allowed.\n";
	exit 1;
}

# various checks
if ($config{'debug'}) {
	foreach (keys %Header) {
		warn "Raw 8-bit data in the following header:\n$Header{$_}" if ($Header{$_} =~ m/[\x80-\xff]/o);
	}
	if (!defined($Header{'mime-version'}) || !defined($Header{'content-type'}) || !defined($Header{'content-transfer-encoding'})) {
		warn "8bit body without MIME-headers\n" if (grep {/[\x80-\xff]/} @Body);
	}
}

# try ~/.newsauth if no $config{'NNTPPass'} was set
if (!$config{'NNTPPass'}) {
	my ($l, $server, $pass, $user);
	if (-r (glob("~/.newsauth"))[0]) {
		open (my $NEWSAUTH, '<', (glob("~/.newsauth"))[0]) or die("Can't open ~/.newsauth: $!");
		while ($l = <$NEWSAUTH>) {
			chomp $l;
			next if ($l =~ m/^[#\s]/);
			($server, $pass, $user) = split(/\s+\b/, $l);
			last if ($server =~ m/\Q$config{'NNTPServer'}\E/);
		}
		close($NEWSAUTH);
		if ($pass && $server =~ m/\Q$config{'NNTPServer'}\E/) {
			$config{'NNTPPass'} = $pass;
			$config{'NNTPUser'} = $user || getlogin || getpwuid($<) || $ENV{USER};
		} else {
			$pass = $user = "";
		}
	}
	# try ~/.nntpauth if we still got no password
	if (!$pass) {
		if (-r (glob("~/.nntpauth"))[0]) {
			open (my $NNTPAUTH, '<', (glob("~/.nntpauth"))[0]) or die("Can't open ~/.nntpauth: $!");
			while ($l = <$NNTPAUTH>) {
				chomp $l;
				next if ($l =~ m/^[#\s]/);
				($server, $user, $pass) = split(/\s+\b/, $l);
				last if ($server =~ m/\Q$config{'NNTPServer'}\E/);
			}
			close($NNTPAUTH);
			if ($pass && $server =~ m/\Q$config{'NNTPServer'}\E/) {
				$config{'NNTPPass'} = $pass;
				$config{'NNTPUser'} = $user || getlogin || getpwuid($<) || $ENV{USER};
			}
		}
	}
}

if (! $config{'savedir'} && defined($Header{'newsgroups'}) && !defined($Header{'message-id'})) {
	my $Server = AuthonNNTP();
	my $ServerMsg = $Server->message();
	$Server->datasend('.');
	$Server->dataend();
	$Server->quit();
	$Header{'message-id'} = "Message-ID: $1\n" if ($ServerMsg =~ m/(<\S+\@\S+>)/o);
}

if (!defined($Header{'message-id'})) {
	my $hname;
	eval "use Sys::Hostname";
	if ($@) {
		chomp($hname = `hostname`);
	} else {
		$hname = hostname();
	}
	my ($hostname,) = gethostbyname($hname);
	if (defined($hostname) && $hostname =~ m/\./io) {
		$Header{'message-id'} = "Message-ID: " . sprintf("<N%xI%xT%x@%s>\n", $>, timelocal(localtime), $$, $hostname);
	}
}

# add Cancel-Lock (and Cancel-Key) header(s) if requested
if ($config{'canlock_secret'} && !$config{'no_canlock'} && defined($Header{'message-id'})) {
	open(my $CANLock, '<', (glob($config{'canlock_secret'}))[0]) or die("$0: Can't open " . $config{'canlock_secret'} . ": $!");
	chomp(my $key = <$CANLock>);
	close($CANLock);
	(my $data = $Header{'message-id'}) =~ s#^Message-ID: ##i;
	chomp $data;
	my $cancel_key = buildcancelkey($data, $key);
	my $cancel_lock = buildcancellock($cancel_key, $sha_mod);
	if (defined($Header{'cancel-lock'})) {
		chomp $Header{'cancel-lock'};
		$Header{'cancel-lock'} .= " " . $config{'canlock_algorithm'} . ":" . $cancel_lock . "\n";
	} else {
		$Header{'cancel-lock'} = "Cancel-Lock: " . $config{'canlock_algorithm'} . ":" . $cancel_lock . "\n";
	}

	if ((defined($Header{'supersedes'}) && $Header{'supersedes'} =~ m/^Supersedes:\s+<\S+>\s*$/i) || (defined($Header{'control'}) && $Header{'control'} =~ m/^Control:\s+cancel\s+<\S+>\s*$/i) ||(defined($Header{'also-control'}) && $Header{'also-control'} =~ m/^Also-Control:\s+cancel\s+<\S+>\s*$/i)) {
		if (defined($Header{'also-control'}) && $Header{'also-control'} =~ m/^Also-Control:\s+cancel\s+/i) {
			($data = $Header{'also-control'}) =~ s#^Also-Control:\s+cancel\s+##i;
			chomp $data;
			$cancel_key = buildcancelkey($data, $key);
		} else {
			if (defined($Header{'control'}) && $Header{'control'} =~ m/^Control: cancel /i) {
				($data = $Header{'control'})=~ s#^Control:\s+cancel\s+##i;
				chomp $data;
				$cancel_key = buildcancelkey($data, $key);
			} else {
				if (defined($Header{'supersedes'})) {
					($data = $Header{'supersedes'}) =~ s#^Supersedes: ##i;
					chomp $data;
					$cancel_key = buildcancelkey($data, $key);
				}
			}
		}
		if (defined($Header{'cancel-key'})) {
			chomp $Header{'cancel-key'};
			$Header{'cancel-key'} .= " " . $config{'canlock_algorithm'} . ":" . $cancel_key . "\n";
		} else {
			$Header{'cancel-key'} = "Cancel-Key: " . $config{'canlock_algorithm'} . ":" . $cancel_key . "\n";
		}
	}
}

# set Posted-And-Mailed if we send a mailcopy to someone else
if ($config{'sendmail'} && defined($Header{'newsgroups'}) && (defined($Header{'to'}) || defined($Header{'cc'}) || defined($Header{'bcc'}))) {
	foreach ('to', 'bcc', 'cc') {
		if (defined($Header{$_}) && $Header{$_} ne $Header{'from'}) {
			$Header{'posted-and-mailed'} = "Posted-And-Mailed: yes\n";
			last;
		}
	}
}

if (! $config{'no_sign'}) {
	if (!$config{'PGPSigner'}) {
		chomp($config{'PGPSigner'} = $Header{'from'});
		$config{'PGPSigner'} =~ s/^[^\s:]+: (.*)/$1/;
	}
	$PGPCommand = getpgpcommand($config{'PGPVersion'});
}

# (re)move mail-headers
my ($To, $Cc, $Bcc, $Newsgroups) = '';
$To = $Header{'to'} if (defined($Header{'to'}));
$Cc = $Header{'cc'} if (defined($Header{'cc'}));
$Bcc = $Header{'bcc'} if (defined($Header{'bcc'}));
delete $Header{$_} foreach ('to', 'cc', 'bcc');
$Newsgroups = $Header{'newsgroups'} if (defined($Header{'newsgroups'}));

my $MessageR = [];

if ($config{'no_sign'}) {
	# don't sign article
	push @$MessageR, $Header{$_} for (keys %Header);
	push @$MessageR, "\n", @Body;
} else {
	# sign article
	$MessageR = signarticle(\%Header, \@Body);
}

# post or save article
if (! $config{'savedir'}) {
	postarticle($MessageR) if ($Newsgroups);
} else {
	savearticle($MessageR) if ($Newsgroups);
}

# mail article
if (($To || $Cc || $Bcc) && $config{'sendmail'}) {
	open(my $MAIL, '|-', $config{'sendmail'}) || die("$!");
	unshift @$MessageR, "$To" if ($To);
	unshift @$MessageR, "$Cc" if ($Cc);
	unshift @$MessageR, "$Bcc" if ($Bcc);
	print($MAIL @$MessageR);
	close($MAIL);
}

# Game over. Insert new coin.
exit;


#-------- sub readarticle
#
sub readarticle {
	my ($HeaderR, $BodyR) = @_;
	my $currentheader;
	while (defined($_ = <>)) {
		if ($in_header) {
			if (m/^$/o) { #end of header
				$in_header = 0;
			} elsif (m/^([^\s:]+): (.*)$/s) {
				$currentheader = lc($1);
				$$HeaderR{$currentheader} = "$1: $2";
			} elsif (m/^[ \t]/o) {
				$$HeaderR{$currentheader} .= $_;
#			} elsif (m/^([^\s:]+):$/) { # skip over empty headers
#				next;
			} else {
				chomp($_);
				# TODO: quote esc. sequences?
				die("'$_' is not a correct header-line");
			}
		} else {
			push @$BodyR, $_;
		}
	}
	return;
}

#-------- sub getdate
# getdate generates a date and returns it.
#
sub getdate {
	my @time = localtime;
	my $ss = ($time[0]<10) ? "0".$time[0] : $time[0];
	my $mm = ($time[1]<10) ? "0".$time[1] : $time[1];
	my $hh = ($time[2]<10) ? "0".$time[2] : $time[2];
	my $day = $time[3];
	my $month = ($time[4]+1 < 10) ? "0".($time[4]+1) : $time[4]+1;
	my $monthN = ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")[$time[4]];
	my $wday = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$time[6]];
	my $year = $time[5] + 1900;
	my $offset = timelocal(localtime) - timelocal(gmtime);
	my $sign ="+";
	if ($offset < 0) {
		$sign ="-";
		$offset *= -1;
	}
	my $offseth = int($offset/3600);
	my $offsetm = int(($offset - $offseth*3600)/60);
	my $tz = sprintf ("%s%0.2d%0.2d", $sign, $offseth, $offsetm);
	return "$wday, $day $monthN $year $hh:$mm:$ss $tz";
}


#-------- sub AuthonNNTP
# AuthonNNTP opens the connection to a Server and returns a Net::NNTP-Object.
#
# User, Password and Server are defined before as elements
# of the global hash %config. If no values for user or password
# are defined, the sub will try to ask the user (only if
# $config{'Interactive'} is != 0).
sub AuthonNNTP {
	my $Server = Net::NNTP->new($config{'NNTPServer'}, Reader => 1, Debug => $config{'debug'}, Port => $config{'NNTPPort'})
		or die("$0: Can't connect to ".$config{'NNTPServer'}.":".$config{'NNTPPort'}."!\n");
	my $ServerMsg = "";
	my $ServerCod = $Server->code();

	# no read and/or write access - give up
	if ($ServerCod < 200 || $ServerCod > 201) {
		$ServerMsg = $Server->message();
		$Server->quit();
		die($0.": ".$ServerCod." ".$ServerMsg."\n");
	}

	# read access - try auth
	if ($ServerCod == 201 || $config{'force_auth'}) {
		if ($config{'NNTPPass'} eq "") {
			if ($config{'Interactive'}) {
				$config{'NNTPUser'} = $term->readline("Your Username at ".$config{'NNTPServer'}.": ");
				$attribs->{redisplay_function} = $attribs->{shadow_redisplay};
				$config{'NNTPPass'} = $term->readline("Password for ".$config{'NNTPUser'}." at ".$config{'NNTPServer'}.": ");
			} else {
				$ServerMsg = $Server->message();
				$Server->quit();
				die($0.": ".$ServerCod." ".$ServerMsg."\n");
			}
		}
		$Server->authinfo($config{'NNTPUser'}, $config{'NNTPPass'});
		$ServerCod = $Server->code();
		$ServerMsg = $Server->message();
		if ($ServerCod != 281) { # auth failed
			$Server->quit();
			die $0.": ".$ServerCod." ".$ServerMsg."\n";
		}
	}

	$Server->post();
	$ServerCod = $Server->code();
	if ($ServerCod == 480) {
		if ($config{'NNTPPass'} eq "") {
			if ($config{'Interactive'}) {
				$config{'NNTPUser'} = $term->readline("Your Username at ".$config{'NNTPServer'}.": ");
				$attribs->{redisplay_function} = $attribs->{shadow_redisplay};
				$config{'NNTPPass'} = $term->readline("Password for ".$config{'NNTPUser'}." at ".$config{'NNTPServer'}.": ");
			} else {
				$ServerMsg = $Server->message();
				$Server->quit();
				die($0.": ".$ServerCod." ".$ServerMsg."\n");
			}
		}
		$Server->authinfo($config{'NNTPUser'}, $config{'NNTPPass'});
		$Server->post();
	}
	return $Server;
}


#-------- sub getpgpcommand
# getpgpcommand generates the command to sign the message and returns it.
#
# Receives:
# 	- $PGPVersion: A scalar holding the PGPVersion
sub getpgpcommand {
	my ($PGPVersion) = @_;
	my $found = 0;

	if ($config{'pgp'} !~ /^\//) {
		foreach(split(/:/, $ENV{'PATH'})) {
			if (-x $_."/".$config{'pgp'}) {
				$found++;
				last;
			}
		}
	}
	if (!-x $config{'pgp'} && ! $found) {
		warn "PGP signing disabled: Can't locate executable ".$config{'pgp'}."\n" if $config{'debug'};
		$config{'no_sign'} = 1;
	}

	if ($PGPVersion eq '2') {
		if ($config{'PGPPass'}) {
			$PGPCommand = "PGPPASS=\"".$config{'PGPPass'}."\" ".$config{'pgp'}." -z -u \"".$config{'PGPSigner'}."\" +verbose=0 language='en' -saft <".$config{'pgptmpf'}.".txt >".$config{'pgptmpf'}.".txt.asc";
		} elsif ($config{'Interactive'}) {
			$PGPCommand = $config{'pgp'}." -z -u \"".$config{'PGPSigner'}."\" +verbose=0 language='en' -saft <".$config{'pgptmpf'}.".txt >".$config{'pgptmpf'}.".txt.asc";
		} else {
			die("$0: Passphrase is unknown!\n");
		}
	} elsif ($PGPVersion eq '5') {
		if ($config{'PathtoPGPPass'}) {
			$PGPCommand = "PGPPASSFD=".$config{'PGPPassFD'}." ".$config{'pgp'}."s -u \"".$config{'PGPSigner'}."\" -t --armor -o ".$config{'pgptmpf'}.".txt.asc -z -f < ".$config{'pgptmpf'}.".txt ".$config{'PGPPassFD'}."<".$config{'PathtoPGPPass'};
		} elsif ($config{'Interactive'}) {
			$PGPCommand = $config{'pgp'}."s -u \"".$config{'PGPSigner'}."\" -t --armor -o ".$config{'pgptmpf'}.".txt.asc -z -f < ".$config{'pgptmpf'}.".txt";
		} else {
			die("$0: Passphrase is unknown!\n");
		}
	} elsif ($PGPVersion eq '6') { # this is untested
		if ($config{'PathtoPGPPass'}) {
			$PGPCommand = "PGPPASSFD=".$config{'PGPPassFD'}." ".$config{'pgp'}." -u \"".$config{'PGPSigner'}."\" -saft -o ".$config{'pgptmpf'}.".txt.asc < ".$config{'pgptmpf'}.".txt ".$config{'PGPPassFD'}."<".$config{'PathtoPGPPass'};
		} elsif ($config{'Interactive'}) {
			$PGPCommand = $config{'pgp'}." -u \"".$config{'PGPSigner'}."\" -saft -o ".$config{'pgptmpf'}.".txt.asc < ".$config{'pgptmpf'}.".txt";
		} else {
			die("$0: Passphrase is unknown!\n");
		}
	} elsif ($PGPVersion =~ m/GPG1?$/io) {
		if ($config{'PathtoPGPPass'}) {
			$PGPCommand = $config{'pgp'}." --emit-version --digest-algo $config{'digest-algo'} -a -u \"".$config{'PGPSigner'}."\" -o ".$config{'pgptmpf'}.".txt.asc --no-tty --batch --passphrase-fd ".$config{'PGPPassFD'}." ".$config{'PGPPassFD'}."<".$config{'PathtoPGPPass'}." --clearsign ".$config{'pgptmpf'}.".txt";
		} elsif ($config{'Interactive'}) {
			$PGPCommand = $config{'pgp'}." --emit-version --digest-algo $config{'digest-algo'} -a -u \"".$config{'PGPSigner'}."\" -o ".$config{'pgptmpf'}.".txt.asc --no-secmem-warning --no-batch --clearsign ".$config{'pgptmpf'}.".txt";
		} else {
			die("$0: Passphrase is unknown!\n");
		}
	} elsif ($PGPVersion =~ m/GPG2$/io) {
		if ($config{'PathtoPGPPass'}) {
			$PGPCommand = $config{'pgp'}." --pinentry-mode loopback --emit-version --digest-algo $config{'digest-algo'} -a -u \"".$config{'PGPSigner'}."\" -o ".$config{'pgptmpf'}.".txt.asc --no-tty --batch --passphrase-fd ".$config{'PGPPassFD'}." ".$config{'PGPPassFD'}."<".$config{'PathtoPGPPass'}." --clearsign ".$config{'pgptmpf'}.".txt";
		} elsif ($config{'Interactive'}) {
			$PGPCommand = $config{'pgp'}." --emit-version --digest-algo $config{'digest-algo'} -a -u \"".$config{'PGPSigner'}."\" -o ".$config{'pgptmpf'}.".txt.asc --no-secmem-warning --no-batch --clearsign ".$config{'pgptmpf'}.".txt";
		} else {
			die("$0: Passphrase is unknown!\n");
		}
	} else {
		die("$0: Unknown PGP-Version $PGPVersion!");
	}
	return $PGPCommand;
}


#-------- sub postarticle
# postarticle posts your article to your Newsserver.
#
# Receives:
# 	- $ArticleR: A reference to an array containing the article
sub postarticle {
	my ($ArticleR) = @_;

	my $Server = AuthonNNTP();
	my $ServerCod = $Server->code();
	if ($ServerCod == 340) {
		$Server->datasend(@$ArticleR);
		$Server->dataend();
		if (!$Server->ok()) {
			my $ServerMsg = $Server->message();
			$Server->quit();
			die("\n$0: Posting failed! Response from news server:\n", $Server->code(), ' ', $ServerMsg);
		}
		$Server->quit();
	} else {
		die("\n".$0.": Posting failed!\n");
	}
	return;
}


#-------- sub savearticle
# savearticle saves your article to the directory $config{'savedir'}
#
# Receives:
# 	- $ArticleR: A reference to an array containing the article
sub savearticle {
	my ($ArticleR) = @_;
	my $timestamp = timelocal(localtime);
	(my $ng = $Newsgroups) =~ s#^Newsgroups:\s*([^,\s]+).*#$1#i;
	my $gn = join "", map { substr($_,0,1) } (split(/\./, $ng));
	my $filename = $config{'savedir'}."/".$timestamp."-".$gn."-".$$;
	open(my $SH, '>', $filename) or die("$0: can't open $filename: $!\n");
	print $SH @$ArticleR;
	close($SH) or warn "$0: Couldn't close: $!\n";
	return;
}


#-------- sub signarticle
# signarticle signs an article and returns a reference to an array
# containing the whole signed Message.
#
# Receives:
# 	- $HeaderR: A reference to a hash containing the articles headers.
# 	- $BodyR: A reference to an array containing the body.
#
# Returns:
# 	- $MessageRef: A reference to an array containing the whole message.
sub signarticle {
	my ($HeaderR, $BodyR) = @_;
	my (@pgphead, @pgpbody, $pgphead, $pgpbody, $signheaders, @signheaders);

	foreach (@{$config{'PGPSignHeaders'}}) {
		if (defined($$HeaderR{lc($_)}) && $$HeaderR{lc($_)} =~ m/^[^\s:]+: .+/o) {
			push @signheaders, $_;
		}
	}

	$pgpbody = join("", @$BodyR);

	# Delete and create the temporary pgp-Files
	unlink $config{'pgptmpf'}.".txt";
	unlink $config{'pgptmpf'}.".txt.asc";
	$signheaders = join(",", @signheaders);

	$pgphead = "X-Signed-Headers: $signheaders\n";
	foreach my $header (@signheaders) {
		if ($$HeaderR{lc($header)} =~ m/^[^\s:]+: (.+?)\n?$/so) {
			$pgphead .= $header.": ".$1."\n";
		}
	}

	unless (substr($pgpbody,-1,1)=~ /\n/ ) {$pgpbody.="\n"};
	open(my $FH, '>', $config{'pgptmpf'} . ".txt") or die("$0: can't open ".$config{'pgptmpf'}.": $!\n");
	print $FH $pgphead, "\n", $pgpbody;
	print $FH "\n" if ($config{'PGPVersion'} =~ m/GPG/io); # workaround a pgp/gpg incompatibility - should IMHO be fixed in pgpverify
	close($FH) or warn "$0: Couldn't close TMP: $!\n";

	# Start PGP, then read the signature;
	`$PGPCommand`;

	open($FH, '<', $config{'pgptmpf'} . ".txt.asc") or die("$0: can't open ".$config{'pgptmpf'}.".txt.asc: $!\n");
	local $/ = "\n".$config{'pgpbegin'}."\n";
	$_ = <$FH>;
	unless (m/\Q$config{'pgpbegin'}\E$/o) {
		unlink $config{'pgptmpf'} . ".txt";
		unlink $config{'pgptmpf'} . ".txt.asc";
		close($FH);
		die("$0: ".$config{'pgpbegin'}." not found in ".$config{'pgptmpf'}.".txt.asc\n");
	}
	unlink($config{'pgptmpf'} . ".txt") or warn "$0: Couldn't unlink ".$config{'pgptmpf'}.".txt: $!\n";

	local $/ = "\n";
	$_ = <$FH>;
	unless (m/^Version: (\S+)(?:\s(\S+))?/o) {
		unlink $config{'pgptmpf'} . ".txt.asc";
		close($FH);
		die("$0: didn't find PGP Version line where expected.\n");
	}
	if (defined($2)) {
		$$HeaderR{$config{'pgpheader'}} = $1."-".$2." ".$signheaders;
	} else {
		$$HeaderR{$config{'pgpheader'}} = $1." ".$signheaders;
	}
	do {			# skip other pgp headers like
		$_ = <$FH>;	# "charset:"||"comment:" until empty line
	} while ! /^$/;

	while (<$FH>) {
		chomp;
		last if /^\Q$config{'pgpend'}\E$/;
		$$HeaderR{$config{'pgpheader'}} .= "\n\t$_";
	}
	$$HeaderR{$config{'pgpheader'}} .= "\n" unless ($$HeaderR{$config{'pgpheader'}} =~ /\n$/s);

	$_ = <$FH>;
	unless (eof($FH)) {
		unlink $config{'pgptmpf'} . ".txt.asc";
		close($FH);
		die("$0: unexpected data following ".$config{'pgpend'}."\n");
	}
	close($FH);
	unlink $config{'pgptmpf'} . ".txt.asc";

	my $tmppgpheader = $config{'pgpheader'} . ": " . $$HeaderR{$config{'pgpheader'}};
	delete $$HeaderR{$config{'pgpheader'}};

	@pgphead = ();
	foreach my $header (@{$config{PGPorderheaders}}) {
		if ($$HeaderR{$header} && $$HeaderR{$header} ne "\n") {
			push(@pgphead, "$$HeaderR{$header}");
			delete $$HeaderR{$header};
		}
	}

	foreach my $header (keys %$HeaderR) {
		if ($$HeaderR{$header} && $$HeaderR{$header} ne "\n") {
			push(@pgphead, "$$HeaderR{$header}");
			delete $$HeaderR{$header};
		}
	}

	push @pgphead, ("X-PGP-Hash: " . $config{'digest-algo'} . "\n") if (defined($config{'digest-algo'}));
	push @pgphead, ("X-PGP-Key: " . $config{'PGPSigner'} . "\n"), $tmppgpheader;
	undef $tmppgpheader;

	@pgpbody = split(/$/m, $pgpbody);
	my @pgpmessage = (@pgphead, "\n", @pgpbody);
	return \@pgpmessage;
}

#-------- sub buildcancelkey
# buildcancelkey builds the cancel-key based on the configured HASH algorithm.
#
# Receives:
# 	- $data: The input data.
# 	- $key: The secret key to be used.
#
# Returns:
# 	- $cancel_key: The calculated cancel-key.
sub buildcancelkey {
	my ($data, $key) = @_;
	my $cancel_key;
	if ($config{'canlock_algorithm'} eq 'sha1') {
		$cancel_key = MIME::Base64::encode(Digest::HMAC_SHA1::hmac_sha1($data, $key), '');
	} elsif ($config{'canlock_algorithm'} eq 'sha256') {
		$cancel_key = MIME::Base64::encode(Digest::SHA::hmac_sha256($data, $key), '');
	} else {
		$cancel_key = MIME::Base64::encode(Digest::SHA::hmac_sha512($data, $key), '');
	}
	return $cancel_key;
}

#-------- sub buildcancellock
# buildcancellock builds the cancel-lock based on the configured HASH algorithm
# and the given cancel-key.
#
# Receives:
# 	- $sha_mod: A hint which module to be used for sha1.
# 	- $cancel_key: The cancel-key for which the lock has to be calculated.
#
# Returns:
# 	- $cancel_lock: The calculated cancel-lock.
sub buildcancellock {
	my ($cancel_key, $sha_mod) = @_;
	my $cancel_lock;
	if ($config{'canlock_algorithm'} eq 'sha1') {
		if ($sha_mod =~ m/SHA1/) {
			$cancel_lock = MIME::Base64::encode(Digest::SHA1::sha1($cancel_key, ''), '');
		} else {
			$cancel_lock = MIME::Base64::encode(Digest::SHA::sha1($cancel_key, ''), '');
		}
	} elsif ($config{'canlock_algorithm'} eq 'sha256') {
		$cancel_lock = MIME::Base64::encode(Digest::SHA::sha256($cancel_key, ''), '');
	} else {
		$cancel_lock = MIME::Base64::encode(Digest::SHA::sha512($cancel_key, ''), '');
	}
	return $cancel_lock;
}

sub version {
	print $pname." ".$version."\n";
	return;
}

sub usage {
	version();
	print "Usage: ".$pname." [OPTS] < article\n";
	print "  -a string  set Approved:-header to string\n";
	print "  -c string  set Control:-header to string\n";
	print "  -d string  set Distribution:-header to string\n";
	print "  -e string  set Expires:-header to string\n";
	print "  -f string  set From:-header to string\n";
	print "  -i string  list of headers to be ignored for signing\n";
	print "  -n string  set Newsgroups:-header to string\n";
	print "  -o string  set Organization:-header to string\n";
	print "  -p port    use port as NNTP port [default=".$config{'NNTPPort'}."]\n";
	print "  -r string  set Reply-To:-header to string\n";
	print "  -s string  save signed article to directory string instead of posting\n";
	print "  -t string  set Subject:-header to string\n";
	print "  -v         show version\n";
	print "  -w string  set Followup-To:-header to string\n";
	print "  -x string  set Path:-header to string\n";
	print "  -D         enable debugging\n";
	print "  -F string  set References:-header to string\n";
	print "  -H         show help\n";
	print "  -I         do not add Injection-Date: header\n";
	print "  -L         do not add Cancel-Lock: / Cancel-Key: headers\n";
	print "  -R         disallow control messages\n";
	print "  -S         do not append " . $config{'sig_path'} . "\n";
	print "  -X         do not sign article\n";
	print "  -Y         force authentication on connect\n";
	exit 0;
}

__END__

=head1 NAME

tinews.pl - Post and sign an article via NNTP

=head1 SYNOPSIS

B<tinews.pl> [B<OPTIONS>] E<lt> I<input>

=head1 DESCRIPTION

B<tinews.pl> reads an article on STDIN, signs it via L<pgp(1)> or
L<gpg(1)> and posts it to a news server.

The article shall not contain any raw 8-bit data or it needs to
already have the relevant MIME-headers as B<tinews.pl> will not
add any MIME-headers nor encode its input.

If the article contains To:, Cc: or Bcc: headers and mail-actions are
configured it will automatically add a "Posted-And-Mailed: yes" header
to the article and send out the mail-copies.

If a Cancel-Lock secret file is defined it will automatically add a
Cancel-Lock: (and Cancel-Key: if required) header.

The input should have unix line endings (<LF>, '\n').

=head1 OPTIONS
X<tinews, command-line options>

=over 4

=item -B<a> C<Approved> | --B<approved> C<Approved>
X<-a> X<--approved>

Set the article header field Approved: to the given value.

=item -B<c> C<Control> | --B<control> C<Control>
X<-c> X<--control>

Set the article header field Control: to the given value.

=item -B<d> C<Distribution> | --B<distribution> C<Distribution>
X<-d> X<--distribution>

Set the article header field Distribution: to the given value.

=item -B<e> C<Expires> | --B<expires> C<Expires>
X<-e> X<--expires>

Set the article header field Expires: to the given value.

=item -B<f> C<From> | --B<from> C<From>
X<-f> X<--from>

Set the article header field From: to the given value.

=item -B<i> F<header> | --B<ignore-headers> F<header>
X<-i> X<--ignore-headers>

Comma separated list of headers that will be ignored during signing.
Usually the following headers will be signed if present:

From, Newsgroups, Subject, Control, Supersedes, Followup-To,
Date, Injection-Date, Sender, Approved, Message-ID, Reply-To,
Cancel-Key, Also-Control and Distribution.

Some of them may be altered on the Server (i.e. Cancel-Key) which would
invalid the signature, this option can be used the exclude such headers
if required.

=item -B<n> C<Newsgroups> | --B<newsgroups> C<Newsgroups>
X<-n> X<--newsgroups>

Set the article header field Newsgroups: to the given value.

=item -B<o> C<Organization> | --B<organization> C<Organization>
X<-o> X<--organization>

Set the article header field Organization: to the given value.

=item -B<p> C<port> | --B<port> C<port>
X<-p> X<--port>

use C<port> as NNTP-port

=item -B<r> C<Reply-To> | --B<replyto> C<Reply-To>
X<-r> X<--replyto>

Set the article header field Reply-To: to the given value.

=item -B<s> F<directory> | --B<savedir> F<directory>
X<-s> X<--savedir>

Save signed article to directory F<directory> instead of posting.

=item -B<t> C<Subject> | --B<subject> C<Subject>
X<-t> X<--subject>

Set the article header field Subject: to the given value.

=item -B<v> | --B<version>
X<-v> X<--version>

Show version.

=item -B<w> C<Followup-To> | --B<followupto> C<Followup-To>
X<-w> X<--followupto>

Set the article header field Followup-To: to the given value.

=item -B<x> C<Path> | --B<path> C<Path>
X<-x> X<--path>

Set the article header field Path: to the given value.

=item -B<H> | --B<help>
X<-H> X<--help>

Show help-page.

=item -B<I> | --B<no-injection-date>
X<-I> X<--no-injection-date>

Do not add Injection-Date: header.

=item -B<L> | --B<no-canlock>
X<-L> X<--no-canlock>

Do not add Cancel-Lock: / Cancel-Key: headers.

=item --B<canlock-algorithm> C<Algorithm>
X<--canlock-algorithm>

Digest algorithm used for Cancel-Lock: / Cancel-Key: headers.
Supported algorithms are sha1, sha256 and sha512. Default is sha1.

=item -B<R> | --B<no-control>
X<-R> X<--no-control>

Restricted mode, disallow control-messages.

=item -B<S> | --B<no-signature>
X<-s> X<--no-signature>

Do not append F<$HOME/.signature>.

=item -B<X> | --B<no-sign>
X<-X> X<--no-sign>

Do not sign the article.

=item -B<Y> | --B<force-auth>
X<-Y> X<--force-auth>

Force authentication on connect even if not required by the server.

=item -B<A> -B<V> -B<W>
X<-A> X<-V> X<-W>

These options are accepted for compatibility reasons but ignored.

=item -B<h> | --B<headers>
X<-h> X<--headers>

These options are accepted for compatibility reasons but ignored.

=item -B<O> | --B<no-organization>
X<-O> X<--no-organization>

These options are accepted for compatibility reasons but ignored.

=item -B<D> | -B<N> | --B<debug>
X<-D> X<-N> X<--debug>

Enable warnings about raw 8-bit data and set L<Net::NNTP(3pm)> in debug
mode, enable warnings about raw 8-bit data, warn about disabled options
due to lacking perl-modules or executables and unreadable files.

=back

=head1 EXIT STATUS

The following exit values are returned:

=over 4

=item S< 0>

Successful completion.

=item S<!=0>

An error occurred.

=back

=head1 ENVIRONMENT
X<tinews, environment variables>

=over 4

=item B<$NEWSHOST>
X<$NEWSHOST> X<NEWSHOST>

Set to override the NNTP server configured in the source or config-file.
It has lower priority than B<$NNTPSERVER> and should be avoided.

=item B<$NNTPSERVER>
X<$NNTPSERVER> X<NNTPSERVER>

Set to override the NNTP server configured in the source or config-file.
This has higher priority than B<$NEWSHOST>.

=item B<$NNTPPORT>
X<$NNTPPORT> X<NNTPPORT>

The NNTP TCP-port to post news to. This variable only needs to be set if the
TCP-port is not 119 (the default). The '-B<p>' command-line option overrides
B<$NNTPPORT>.

=item B<$PGPPASS>
X<$PGPPASS> X<PGPPASS>

Set to override the passphrase configured in the source (used for
L<pgp(1)>-2.6.3).

=item B<$PGPPASSFILE>
X<$PGPPASSFILE> X<PGPPASSFILE>

Passphrase file used for L<pgp(1)> or L<gpg(1)>.

=item B<$SIGNER>
X<$SIGNER> X<SIGNER>

Set to override the user-id for signing configured in the source. If you
neither set B<$SIGNER> nor configure it in the source the contents of the
From:-field will be used.

=item B<$REPLYTO>
X<$REPLYTO> X<REPLYTO>

Set the article header field Reply-To: to the return address specified by
the variable if there isn't already a Reply-To: header in the article.
The '-B<r>' command-line option overrides B<$REPLYTO>.

=item B<$ORGANIZATION>
X<$ORGANIZATION> X<ORGANIZATION>

Set the article header field Organization: to the contents of the variable
if there isn't already an Organization: header in the article. The '-B<o>'
command-line option overrides B<$ORGANIZATION>.

=item B<$DISTRIBUTION>
X<$DISTRIBUTION> X<DISTRIBUTION>

Set the article header field Distribution: to the contents of the variable
if there isn't already a Distribution: header in the article. The '-B<d>'
command-line option overrides B<$DISTRIBUTION>.

=back

=head1 FILES

=over 4

=item F<pgptmp.txt>

Temporary file used to store the reformatted article.

=item F<pgptmp.txt.asc>

Temporary file used to store the reformatted and signed article.

=item F<$PGPPASSFILE>

The passphrase file to be used for L<pgp(1)> or L<gpg(1)>.

=item F<$HOME/.signature>

Signature file which will be automatically included.

=item F<$HOME/.cancelsecret>

The passphrase file to be used for Cancel-Locks. This feature is turned
off by default.

=item F<$HOME/.newsauth>

"nntpserver password [user]" pairs for NNTP servers that require
authorization. Any line that starts with "#" is a comment. Blank lines are
ignored. This file should be readable only for the user as it contains the
user's unencrypted password for reading news. First match counts. If no
matching entry is found F<$HOME/.nntpauth> is checked.

=item F<$HOME/.nntpauth>

"nntpserver user password" pairs for NNTP servers that require
authorization. First match counts. Lines starting with "#" are skipped and
blank lines are ignored. This file should be readable only for the user as
it contains the user's unencrypted password for reading news.
F<$HOME/.newsauth> is checked first.

=item F<$XDG_CONFIG_HOME/tinewsrc> F<$HOME/.config/tinewsrc> F<$HOME/.tinewsrc>

"option=value" configuration pairs. Lines that start with "#" are ignored.
If the file contains unencrypted passwords (e.g. NNTPPass or PGPPass), it
should be readable for the user only.

=back

=head1 SECURITY

If you've configured or entered a password, even if the variable that
contained that password has been erased, it may be possible for someone to
find that password, in plaintext, in a core dump. In short, if serious
security is an issue, don't use this script.

=head1 NOTES

B<tinews.pl> is designed to be used with L<pgp(1)>-2.6.3,
L<pgp(1)>-5, L<pgp(1)>-6, L<gpg(1)> and L<gpg2(1)>.

B<tinews.pl> requires the following standard modules to be installed:
L<Getopt::Long(3pm)>, L<Net::NNTP(3pm)>, <Time::Local(3pm)> and
L<Term::Readline(3pm)>.

If the Cancel-Lock feature (RFC 8315) is enabled the following additional
modules must be installed: L<MIME::Base64(3pm)>, L<Digest::SHA(3pm)> or
L<Digest::SHA1(3pm)> and L<Digest::HMAC_SHA1(3pm)>. sha256 and sha512 as
algorithms for B<canlock-algorithm> are only available with L<Digest::SHA(3pm)>.

L<gpg2(1)> users may need to set B<$GPG_TTY>, i.e.

 GPG_TTY=$(tty)
 export GPG_TTY

before using B<tinews.pl>. See L<https://www.gnupg.org/> for details.

B<tinews.pl> does not do any MIME encoding, its input should be already
properly encoded and have all relevant headers set.

=head1 AUTHOR

Urs Janssen E<lt>urs@tin.orgE<gt>,
Marc Brockschmidt E<lt>marc@marcbrockschmidt.deE<gt>

=head1 SEE ALSO

L<pgp(1)>, L<gpg(1)>, L<gpg2(1)>, L<pgps(1)>, L<Digest::HMAC_SHA1(3pm)>,
L<Digest::SHA(3pm)>, L<Digest::SHA1(3pm)>, L<Getopt::Long(3pm)>,
L<MIME::Base64(3pm)>, L<Net::NNTP(3pm)>, L<Time::Local(3pm)>,
L<Term::Readline(3pm)>

=cut
