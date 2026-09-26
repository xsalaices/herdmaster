#!/usr/bin/env bash
set -euo pipefail
B="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-board.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T" HERDMASTER_PROJECT=demo
f="$T/.claude/orchestrator/demo/tasks.json"
eq() { [[ $1 == "$2" ]] || { echo "FAIL: got '$1' want '$2'" >&2; exit 1; }; }

d=$("$B" add decision "Sidebar or top nav")
t1=$("$B" add task "Settings page" --review user --depends "$d")
t2=$("$B" add task "Docs")
eq "$d $t1 $t2" "D-001 T-001 T-002"
eq "$(jq -r '.schema_version' "$f")" 1
eq "$(jq -r --arg i "$t1" '.entries[] | select(.id == $i) | .depends_on[0]' "$f")" "$d"
"$B" add task x --depends D-999 2>/dev/null && { echo "FAIL: unknown dep accepted" >&2; exit 1; }

"$B" status "$t1" "in review"
"$B" attempt "$t1" rejected "Spacing too tight" pr/41
eq "$(jq -r '.entries[] | select(.id == "T-001") | .attempts[0].feedback' "$f")" "Spacing too tight"

"$B" supersede "$d"
eq "$(jq -r '.entries[] | select(.id == "D-001") | .status' "$f")" superseded
eq "$(jq -r '.entries[] | select(.id == "T-001") | .flags[0]' "$f")" "superseded:D-001"
eq "$(jq -r '.entries[] | select(.id == "T-002") | .flags // "none"' "$f")" none

n=$("$B" add decision "Pick one" --note "Because X" --recommend "Yes, because Y")
eq "$(jq -r --arg n "$n" '.entries[] | select(.id == $n) | .note + "|" + .recommend' "$f")" "Because X|Yes, because Y"
"$B" status "$n" settled

first=$("$B" count)
[[ $first == "Board: 1 in review (oldest 0m), 1 flagged" ]] || { echo "FAIL: count '$first'" >&2; exit 1; }
eq "$("$B" count)" ""
"$B" status "$t2" "in review"
[[ $("$B" count) == "Board: 2 in review (oldest 0m), 1 flagged" ]] || { echo "FAIL: count after change" >&2; exit 1; }
eq "$("$B" count)" ""
echo "ok"
