#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)/bin"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T" HERDMASTER_PROJECT=demo HERDMASTER_HERDR=herdr
B="$R/herdmaster-board.sh" L="$R/herdmaster-labels.sh"
has() { grep -qF -- "$2" <<<"$1" || { echo "FAIL: missing '$2' in: $1" >&2; exit 1; }; }

"$B" add decision "Pick a db" >/dev/null
"$B" add decision "Pick a cache" >/dev/null
"$B" add task "Build the thing" >/dev/null
"$B" status T-001 "in review"

out=$("$L" --dry-run workspace ws-1)
has "$out" "workspace report-metadata"
has "$out" "--token project=demo"
has "$out" "--token decisions=2"
has "$out" "--token ready=0"
"$B" status A1 settled
out=$("$L" --dry-run workspace ws-1)
has "$out" "--token decisions=1"
has "$out" "--token ready=0"
"$B" status A2 settled
has "$("$L" --dry-run workspace ws-1)" "--token ready=1"

# A ticket that currently has zero decisions (every one of them moved to another ticket via set-group) never
# counts as ready, even though its letter is still reserved forever in the board's 'tickets' map.
HERDMASTER_PROJECT=tix2 "$B" add decision "Only one" --group Empty >/dev/null
HERDMASTER_PROJECT=tix2 "$B" set-group A1 Elsewhere >/dev/null
HERDMASTER_PROJECT=tix2 "$B" status B1 settled >/dev/null
has "$(HERDMASTER_PROJECT=tix2 "$L" --dry-run workspace ws-2)" "--token ready=1"

out=$("$L" --dry-run pane pane-1 T-001)
has "$out" "T1"
has "$out" 'Build\ the\ thing'
has "$out" "in\ review"
has "$("$L" --dry-run clear pane-1)" "--clear-title"
"$L" --dry-run pane pane-1 T-999 2>/dev/null && { echo "FAIL: bad task accepted" >&2; exit 1; }
"$L" --dry-run bogus 2>/dev/null && { echo "FAIL: bad subcommand" >&2; exit 1; }
echo ok
