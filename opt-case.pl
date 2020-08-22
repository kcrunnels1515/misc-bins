#! /usr/bin/perl -w
#
# reads a tin filter file with regexp filters on STDIN and turns all case
# insensitive regexp into case sensitive ones whenever possible, as case
# sensitive regexp are (a bit) faster.
#
# 2000-04-27 <urs@tin.org>
#
# NOTE: the case= line must come before any line with a regexp pattern,
#       (that is the order tin saves the filter file, if you created the
#       filter by hand and never let tin rewrite the file, you might want to
#       check that first)
#
# NOTE: don't use opt-case.pl on wildmat filters, transform them into regexp
#       filter via w2r.pl first

# version number
# $VERSION = "0.2.2";

# perl 5 is needed for lookahead assertions and perl < 5.004 is known to be
# buggy
require 5.004;

$mod=""; 	# (?i) modifier

while (defined($line = <>)) {
	chomp $line;

	# ignore comments
	if ($line =~ m/^[#\s]/o) {
		print "$line\n";
		next;
	}

	# skip 'empty' patterns, they are nonsense
	next if ($line =~ m/^[^=]+=$/o);

	# new scope || case sensitive rule
	if ($line =~ m/^group=/o || $line =~ m/^case=0/) {
		$mod="";	# clean modifier
		print "$line\n";
		next;
	}

	# case insensitive rule
	if ($line =~ m/^case=1/o) {
		$mod="(?i)";	# set modifier
		print "case=0\n";	# set case to sensitive
		next;
	}

	# check if regexp-line needs (?i)-modifer
	# [^\W\d_] is just a charset independent way to look for any
	# upper/lowercase letters, this will miss a few possible
	# optimizations (on lines with \s, \S, \d, \D as only 'letters') but
	# that won't hurt, it just doesn't optimize'em
	if ($line =~ m/^(subj|from|msgid(?:|_last|_only)|refs_only|xref)=(.*[^\W\d_].*)$/o) {
		print "# rule rewritten, it might be possible that it can be further optimized\n";
		print "# check lines with (?i) if they really need to be case insensitive and if\n";
		print "# not remove leading (?i) manually\n";
		print "$1=$mod$2\n";
		next;
        }

	# other lines don't need to be translated
	print "$line\n";
}

__END__

=head1 NAME

opt-case.pl - Optimize case insensitive regexp filters for tin

=head1 SYNOPSIS

B<opt-case.pl> E<lt> I<input> [E<gt> I<output>]

=head1 DESCRIPTION

B<opt-case.pl> reads a L<tin(1)> filter-file (L<tin(5)>) with regexp
filters on STDIN and turns all case insensitive regexp into case
sensitive ones whenever possible, as case sensitive regexp are (a
bit) faster.

=head1 NOTES

The case= line must come before any line with a regexp pattern, (that
is the order L<tin(1)> saves the filter file, if you created the
filter by hand and never let L<tin(1)> rewrite the file, you might
want to check that first).

Don't use B<opt-case.pl> on wildmat filters, transform them into
regexp filter via L<w2r.pl(1)> first.

=head1 AUTHOR

Urs Janssen E<lt>urs@tin.orgE<gt>

=head1 SEE ALSO

L<tin(1)>, L<tin(5)>, L<w2r.pl(1)>

=cut
