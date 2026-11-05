#!/bin/sh
# Copies the Swiss engine block of index.html (from "/* Swiss engine." to
# "/* End of the Swiss engine. */") into the Edge Function
# supabase/functions/tournament-auto/index.ts, between the lines
#   // >>> SWISS ENGINE
#   // <<< END SWISS ENGINE
# so the function stays one file you can paste in the Supabase dashboard and
# pairs exactly like the organizer's page. Run it from Git Bash whenever the
# engine block changes, then paste the new index.ts:
#   sh tools/sync-swiss-engine.sh           update index.ts
#   sh tools/sync-swiss-engine.sh --check   only compare (exit 1 when they differ)
# Needs only sh and perl (both come with Git for Windows).
root=$(cd "$(dirname "$0")/.." && pwd)
exec perl -e '
use strict; use warnings;
my ($root, $mode) = @ARGV;
$mode //= "";
die "usage: sync-swiss-engine.sh [--check]\n" if $mode ne "" && $mode ne "--check";
sub slurp { my $f = shift; open my $h, "<:raw", $f or die "cannot read $f\n"; local $/; my $s = <$h>; close $h; $s }
my $html = slurp("$root/index.html");
$html =~ m{(/\* Swiss engine\..*?/\* End of the Swiss engine\. \*/)}s or die "engine block not found in index.html\n";
(my $block = $1) =~ s/\r\n/\n/g;
my $tsf = "$root/supabase/functions/tournament-auto/index.ts";
my $ts = slurp($tsf);
my $crlf = $ts =~ /\r\n/;
my $open = "// >>> SWISS ENGINE";
my $close = "// <<< END SWISS ENGINE";
my $i = index($ts, $open);
die "marker \"$open\" not found in index.ts\n" if $i < 0 || index($ts, $open, $i + 1) >= 0;
my $s = index($ts, "\n", $i);
die "no line after \"$open\"\n" if $s < 0;
$s++;
my $e = index($ts, "\n$close", $s - 1);
die "marker \"$close\" not found after \"$open\" in index.ts\n" if $e < 0;
$e++;
(my $have = substr($ts, $s, $e - $s)) =~ s/\r\n/\n/g;
my $want = "$block\n";
if ($have eq $want) { print "tournament-auto/index.ts: the Swiss engine is in sync with index.html\n"; exit 0 }
if ($mode eq "--check") { print STDERR "DRIFT: the Swiss engine in tournament-auto/index.ts differs from index.html. Run sh tools/sync-swiss-engine.sh, then paste the new index.ts in the dashboard.\n"; exit 1 }
my $put = $want;
$put =~ s/\n/\r\n/g if $crlf;
substr($ts, $s, $e - $s) = $put;
open my $o, ">:raw", $tsf or die "cannot write $tsf\n"; print $o $ts; close $o;
print "tournament-auto/index.ts: Swiss engine updated from index.html. Paste the new index.ts in the dashboard (Edge Functions > tournament-auto > Code).\n";
' "$root" "$@"
