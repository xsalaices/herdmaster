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
"$B" status A1 settled
has "$("$L" --dry-run workspace ws-1)" "--token decisions=1"

out=$("$L" --dry-run pane pane-1 T-001)
has "$out" "T1"
has "$out" 'Build\ the\ thing'
has "$out" "in\ review"
has "$("$L" --dry-run clear pane-1)" "--clear-title"
"$L" --dry-run pane pane-1 T-999 2>/dev/null && { echo "FAIL: bad task accepted" >&2; exit 1; }
"$L" --dry-run bogus 2>/dev/null && { echo "FAIL: bad subcommand" >&2; exit 1; }
echo ok
