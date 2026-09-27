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

"$B" status "$t2" paused; "$B" status "$t2" done; "$B" status "$t2" cancelled
"$B" status "$t2" bogus 2>/dev/null && { echo "FAIL: bad status accepted" >&2; exit 1; }
"$B" release-when-done "$t1"
eq "$(jq -r '.entries[] | select(.id == "T-001") | .release_when_done' "$f")" true
"$B" release-when-done "$t1" false
eq "$(jq -r '.entries[] | select(.id == "T-001") | .release_when_done' "$f")" false
"$B" release-when-done "$d" 2>/dev/null && { echo "FAIL: decision accepted" >&2; exit 1; }

s="$T/.claude/orchestrator/demo/settings.json"
eq "$("$B" settings get release)" deploy
"$B" settings set release merge
"$B" settings set grid_panes 4
eq "$("$B" settings get release)" merge
eq "$(jq -r '.grid_panes | type' "$s")" number
"$B" settings set release nope 2>/dev/null && { echo "FAIL: bad release accepted" >&2; exit 1; }
"$B" settings set herdr_workspace w11
eq "$("$B" settings get herdr_workspace)" w11
"$B" settings set herdr_workspace 'a b' 2>/dev/null && { echo "FAIL: bad workspace accepted" >&2; exit 1; }
"$B" settings set grid_panes 0 2>/dev/null && { echo "FAIL: bad grid accepted" >&2; exit 1; }

jq '.entries += [range(205) | {id: "T-\(100 + .)", kind: "task", title: "x", status: "done", review: "auto", depends_on: [], attempts: [], created: "2020-01-01T00:00:00Z", updated: "2021-01-01T00:\(10 + (. / 60 | floor)):\(10 + (. % 60))Z"}]' "$f" > "$T/big.json"
mv "$T/big.json" "$f"
eq "$("$B" archive)" "archived 6"
eq "$(jq '[.entries[] | select(.status == "done" or .status == "cancelled")] | length' "$f")" 200
eq "$(jq '.entries | length' "$T/.claude/orchestrator/demo/tasks-archive.json")" 6
eq "$("$B" archive)" ""
echo "ok"
