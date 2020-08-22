#! /usr/bin/perl -w
# example of how to call an appropriate viewer
#
# URLs must start with a scheme and shell metas should be already quoted
# (tin doesn't recognize URLs without a scheme and it quotes the metas)

use strict;
use warnings;

(my $pname = $0) =~ s#^.*/##;
die "Usage: $pname URL" if $#ARGV != 0;

# version Number
my $version = "0.1.2";

my ($method, $url, $match, @try);
$method = $url = $ARGV[0];
$method =~ s#^([^:]+):.*#$1#io;

# shell escape
$url =~ s#([\&\;\`\'\\\"\|\*\?\~\<\>\^\(\)\[\]\{\}\$\010\013\020\011])#\\$1#g;

if ($ENV{"BROWSER_".uc($method)}) {
	push(@try, split(/:/, $ENV{"BROWSER_".uc($method)}));
} else {
	if ($ENV{BROWSER}) {
		push(@try, split(/:/, $ENV{BROWSER}));
	} else { # set some defaults
		push(@try, 'firefox -a firefox -remote openURL\(%s\)');
		push(@try, 'mozilla -remote openURL\(%s\)');
		push(@try, 'opera -remote openURL\(%s\)');
		push(@try, qw(chromium 'galeon -n' 'epiphany -n' konqueror));
		push(@try, 'lynx'); # prefer lynx over links as it can handle news:-urls
		push(@try, qw('links2 -g' links w3m surf arora));
		push(@try, 'kfmclient newTab'); # has no useful return-value on error
		push(@try, 'xdg-open'); # xdg-open evaluates $BROWSER which is unset
	}
}

for my $browser (@try) {
	# ignore empty parts
	next if ($browser =~ m/^$/o);
	# expand %s if not preceded by odd number of %
	$match = $browser =~ s/(?<!%)((?:%%)*)%s/$1$url/og;
	# expand %c if not preceded by odd number of %
	$browser =~ s/(?<!%)((?:%%)*)%c/$1:/og;
	# reduce dubble %
	$browser =~ s/%%/%/og;
	# append URL if no %s expansion took place
	$browser .= " ".$url if (!$match);
	# leave loop if $browser was started successful
	last if (system("$browser 2>/dev/null") == 0);
}
exit 0;

__END__

=head1 NAME

url_handler.pl - Spawn appropriate viewer for a given URL

=head1 SYNOPSIS

B<url_handler.pl> I<URL>

=head1 DESCRIPTION

B<url_handler.pl> takes an URL as argument and spawns the first executable
viewer found in either B<$BROWSER_I<SCHEME>> or B<$BROWSER>.

=head1 ENVIRONMENT

=over 4

=item B<$BROWSER_I<SCHEME>>

=back

The user's preferred utility to browse URLs of type I<SCHEME>. May actually
consist of a sequence of colon-separated browser commands to be tried in
order until one succeeds. If a command part contains %s, the URL is
substituted there, otherwise the browser command is simply called with the
URL as its last argument. %% is replaced by a single percent sign (%), and
%c is replaced by a colon (:).
Examples:

=over 2

=item $BROWSER_FTP="wget:ncftp"

=item $BROWSER_GOPHER="lynx:links"

=item $BROWSER_MAILTO="mutt:pine -url"

=item $BROWSER_NEWS="lynx"

=item $BROWSER_NNTP="lynx"

=back

Z<>

=over 4

=item B<$BROWSER>

=back

The user's preferred utility to browse URLs for which there is no special
viewer defined via B<$BROWSER_I<SCHEME>>. Again it may actually consist of a
sequence of colon-separated browser commands to be tried in order until one
succeeds. If a command part contains %s, the URL is substituted there,
otherwise the browser command is simply called with the URL as its last
argument. %% is replaced by a single percent sign (%), and %c is replaced
by a colon (:).
Examples:

=over 2

=item $BROWSER="firefox -a firefox -remote openURL\(%s\):opera:konqueror:links2 -g:lynx:w3m"

=back

=head1 SECURITY

B<url_handler.pl> was designed to work together with L<tin(1)> which only
issues shell escaped absolute URLs thus B<url_handler.pl> does not try hard
to shell escape its input nor does it convert relative URLs into absolute
ones! If you use B<url_handler.pl> from other applications be sure to at
least shell escaped its input!

=head1 AUTHOR

Urs Janssen E<lt>urs@tin.orgE<gt>

=head1 SEE ALSO

L<http://www.catb.org/~esr/BROWSER/>
L<http://www.dwheeler.com/browse/secure_browser.html>

=cut
