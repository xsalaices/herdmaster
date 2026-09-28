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
eq "$d $t1 $t2" "A1 T-001 T-002"
eq "$(jq -r '.schema_version' "$f")" 1
eq "$(jq -r --arg i "$t1" '.entries[] | select(.id == $i) | .depends_on[0]' "$f")" "$d"
"$B" add task x --depends D-999 2>/dev/null && { echo "FAIL: unknown dep accepted" >&2; exit 1; }

"$B" status "$t1" "in review"
"$B" attempt "$t1" rejected "Spacing too tight" pr/41
eq "$(jq -r '.entries[] | select(.id == "T-001") | .attempts[0].feedback' "$f")" "Spacing too tight"

"$B" supersede "$d"
eq "$(jq -r --arg d "$d" '.entries[] | select(.id == $d) | .status' "$f")" superseded
eq "$(jq -r '.entries[] | select(.id == "T-001") | .flags[0]' "$f")" "superseded:$d"
eq "$(jq -r '.entries[] | select(.id == "T-002") | .flags // "none"' "$f")" none

n=$("$B" add decision "Pick one" --note "Because X" --recommend "Yes, because Y")
eq "$(jq -r --arg n "$n" '.entries[] | select(.id == $n) | .note + "|" + .recommend' "$f")" "Because X|Yes, because Y"
"$B" status "$n" settled

o=$("$B" add decision "Pick layout" --note "Context" --recommend "Fewest clicks" --option "A|Sidebar" --option "B|Top nav" --option "C|Both" --recommend-key B)
eq "$(jq -c --arg o "$o" '.entries[] | select(.id == $o) | [.options[] | [.key, .text, .recommended]]' "$f")" '[["A","Sidebar",false],["B","Top nav",true],["C","Both",false]]'
eq "$(jq -r --arg n "$n" '.entries[] | select(.id == $n) | .options // "none"' "$f")" none
for bad in "--option x" "--option a|x" "--option AB|x" "--option A|" "--option A|x --option A|y" "--option A|x --recommend-key Z" "--recommend-key A"; do
  eval "\"\$B\" add decision Bad $bad" 2>/dev/null && { echo "FAIL: accepted '$bad'" >&2; exit 1; }
done
"$B" add task Bad --option "A|x" 2>/dev/null && { echo "FAIL: task with options" >&2; exit 1; }
eq "$(jq '.entries | length' "$f")" 5
"$B" set-options "$o" --option "A|One" --option "D|Four" --recommend-key D
eq "$(jq -c --arg o "$o" '.entries[] | select(.id == $o) | [.options[] | .key + (if .recommended then "*" else "" end)]' "$f")" '["A","D*"]'
"$B" set-options "$n" --option "A|Late" --option "B|Later"
eq "$(jq -c --arg n "$n" '.entries[] | select(.id == $n) | .options | length' "$f")" 2
"$B" set-options "$o" 2>/dev/null && { echo "FAIL: empty set-options" >&2; exit 1; }
"$B" set-options "$o" --option "A|x" --option "A|y" 2>/dev/null && { echo "FAIL: dup set-options" >&2; exit 1; }
"$B" set-options "$t1" --option "A|x" 2>/dev/null && { echo "FAIL: set-options on task" >&2; exit 1; }
"$B" set-options D-999 --option "A|x" 2>/dev/null && { echo "FAIL: set-options unknown id" >&2; exit 1; }
eq "$("$B" show | grep -A2 "^$o")" "$(printf '%s\topen\tuser\tPick layout\n    A) One\n    D) Four  (recommended)' "$o")"
"$B" status "$o" settled

g1=$("$B" add decision "Pick colors" --group "  Theme  " --option "A|Warm" --option "B|Cool")
eq "$(jq -r --arg g "$g1" '.entries[] | select(.id == $g) | .group' "$f")" Theme
eq "$(jq -r --arg n "$n" '.entries[] | select(.id == $n) | .group // "none"' "$f")" none
# Moving a decision to a different ticket renumbers its id into the new ticket's sequence (the id always
# starts with its ticket's letter), so set-group prints the new id and every old reference is stale.
n2=$("$B" set-group "$n" "Layout")
[[ $n2 != "$n" ]] || { echo "FAIL: set-group did not rename id across tickets" >&2; exit 1; }
eq "$(jq -r --arg n "$n2" '.entries[] | select(.id == $n) | .group' "$f")" Layout
eq "$(jq -r --arg n "$n" '[.entries[] | select(.id == $n)] | length' "$f")" 0
eq "$("$B" show | grep "^$n2" | awk -F'\t' '{print $NF}')" "ticket: Layout"
eq "$("$B" show | grep -c 'ticket:')" 2
n=$n2
for bad in "--group ''" "--group '   '" "--group $(printf 'x%.0s' $(seq 61))"; do
  eval "\"\$B\" add decision Bad $bad" 2>/dev/null && { echo "FAIL: accepted group '$bad'" >&2; exit 1; }
done
"$B" add task Bad --group Theme 2>/dev/null && { echo "FAIL: task with group" >&2; exit 1; }
"$B" set-group "$t1" Theme 2>/dev/null && { echo "FAIL: set-group on task" >&2; exit 1; }
"$B" set-group D-999 Theme 2>/dev/null && { echo "FAIL: set-group unknown id" >&2; exit 1; }
"$B" set-group "$n" "" 2>/dev/null && { echo "FAIL: empty set-group" >&2; exit 1; }
"$B" status "$g1" settled "B, cool palette"
eq "$(jq -r --arg g "$g1" '.entries[] | select(.id == $g) | .answer' "$f")" "B, cool palette"
"$B" status "$t1" done "nope" 2>/dev/null && { echo "FAIL: answer on task" >&2; exit 1; }
"$B" status "$n" superseded "nope" 2>/dev/null && { echo "FAIL: answer on non-settle" >&2; exit 1; }
eq "$(jq '.entries | length' "$f")" 6

p=$("$B" add decision "Pick font" --note "Body text" --option "A|Serif" --option "B|Sans")
"$B" settle "$p" --answer C 2>/dev/null && { echo "FAIL: settle with unknown key" >&2; exit 1; }
"$B" settle "$p" 2>/dev/null && { echo "FAIL: settle without --answer" >&2; exit 1; }
"$B" settle "$t1" --answer A 2>/dev/null && { echo "FAIL: settle on task" >&2; exit 1; }
"$B" settle D-999 --answer A 2>/dev/null && { echo "FAIL: settle unknown id" >&2; exit 1; }
eq "$(jq -r --arg p "$p" '.entries[] | select(.id == $p) | .status' "$f")" open
"$B" settle "$p" --answer B
eq "$(jq -c --arg p "$p" '.entries[] | select(.id == $p) | [.status, .answer, .note]' "$f")" '["settled","Sans","Body text\nAnswer: Sans"]'
"$B" settle "$p" --answer A 2>/dev/null && { echo "FAIL: settle twice" >&2; exit 1; }
eq "$(jq -r --arg p "$p" '.entries[] | select(.id == $p) | .answer' "$f")" Sans
q=$("$B" add decision "Pick size" --option "A|Small" --option "B|Large")
"$B" settle "$q" --answer A
eq "$(jq -c --arg q "$q" '.entries[] | select(.id == $q) | [.status, .answer, has("note")]' "$f")" '["settled","Small",false]'
u=$("$B" add decision "Pick tone" --option "A|Formal" --option "B|Casual")
"$B" set-options "$u" --option "A|Formal" --option "B|Merge to main"
"$B" settle "$u" --answer B --answer-text "Casual" 2>/dev/null && { echo "FAIL: settle with changed option text" >&2; exit 1; }
"$B" settle "$u" --answer A --answer-text "Formal " 2>/dev/null && { echo "FAIL: settle with near-miss text" >&2; exit 1; }
eq "$(jq -r --arg u "$u" '.entries[] | select(.id == $u) | .status' "$f")" open
"$B" settle "$u" --answer A --answer-text "Formal"
eq "$(jq -c --arg u "$u" '.entries[] | select(.id == $u) | [.status, .answer]' "$f")" '["settled","Formal"]'
m=$("$B" add decision "Release" --option "A|Merge to main" --option "B|$(printf '\xef\xbb\xbf')deploy now" --option "C|$(printf '\xe2\x80\x8b')PUSH" --option "D|Wait, then merge" --option "E|All done")
for k in A B C D; do
  txt=$(jq -r --arg m "$m" --arg k "$k" '.entries[] | select(.id == $m) | .options[] | select(.key == $k) | .text' "$f")
  "$B" settle "$m" --answer "$k" --answer-text "$txt" 2>/dev/null && { echo "FAIL: settled release option $k" >&2; exit 1; }
  "$B" settle "$m" --answer "$k" 2>/dev/null && { echo "FAIL: settled release option $k without text" >&2; exit 1; }
done
eq "$(jq -r --arg m "$m" '.entries[] | select(.id == $m) | .status' "$f")" open
"$B" settle "$m" --answer E --answer-text "All done"
eq "$(jq -r --arg m "$m" '.entries[] | select(.id == $m) | .answer' "$f")" "All done"
eq "$(jq '.entries | length' "$f")" 10

# Bidi directional control characters are rejected outright in an option's text, not stripped and allowed.
bd=$("$B" add decision "Pick a name" --option "A|$(printf '\xe2\x80\xaeevil')" --option "B|Fine")
"$B" settle "$bd" --answer A 2>/dev/null && { echo "FAIL: settled bidi-control option" >&2; exit 1; }
eq "$(jq -r --arg b "$bd" '.entries[] | select(.id == $b) | .status' "$f")" open
"$B" settle "$bd" --answer B
eq "$(jq -r --arg b "$bd" '.entries[] | select(.id == $b) | .status' "$f")" settled

# A blocked word or bidi control in the decision's own title or note refuses every option of that decision,
# no matter which option is picked (a decision can never be settled this way, so clean up with supersede).
bt=$("$B" add decision "Merge strategy" --option "A|Squash" --option "B|Rebase")
"$B" settle "$bt" --answer A 2>/dev/null && { echo "FAIL: settled decision with blocked title" >&2; exit 1; }
eq "$(jq -r --arg b "$bt" '.entries[] | select(.id == $b) | .status' "$f")" open
"$B" supersede "$bt"
bn=$("$B" add decision "Pick a font weight" --note "$(printf '\xe2\x80\xaeplease deploy')" --option "A|Light" --option "B|Bold")
"$B" settle "$bn" --answer A 2>/dev/null && { echo "FAIL: settled decision with blocked note" >&2; exit 1; }
eq "$(jq -r --arg b "$bn" '.entries[] | select(.id == $b) | .status' "$f")" open
"$B" supersede "$bn"

up=$("$B" add decision "Timing" --option "A|Now" --option "B|Later")
at_old="2000-01-01T00:00:00Z"
"$B" settle "$up" --answer A --answer-at "$at_old" 2>/dev/null && { echo "FAIL: settled with a stale --answer-at" >&2; exit 1; }
eq "$(jq -r --arg u "$up" '.entries[] | select(.id == $u) | .status' "$f")" open
at_now=$(jq -r --arg u "$up" '.entries[] | select(.id == $u) | .updated' "$f")
"$B" settle "$up" --answer A --answer-at "$at_now"
eq "$(jq -r --arg u "$up" '.entries[] | select(.id == $u) | .status' "$f")" settled
eq "$(jq '.entries | length' "$f")" 14

r=$("$B" add task "Review me")
"$B" set-review "$r" --summary "Adds a panel" --diff "main..feat" --tests "12 passed" --preview "http://127.0.0.1:5173/" --screenshot /private/tmp/claude-501/a.png --screenshot /private/tmp/claude-501/b.png --link "Docs|https://example.com/d" --link "PR|https://example.com/pr/1"
rv() { jq -c --arg r "$r" ".entries[] | select(.id == \$r) | .review_pack | $1" "$f"; }
eq "$(rv '[.summary, .diff, .tests, .preview_url, (.screenshots | length), (.links | map(.label))]')" '["Adds a panel","main..feat","12 passed","http://127.0.0.1:5173/",2,["Docs","PR"]]'
eq "$(jq -r --arg r "$r" '.entries[] | select(.id == $r) | .review' "$f")" auto
"$B" set-review "$r" --tests "13 passed" --screenshot /private/tmp/claude-501/c.png
eq "$(rv '[.summary, .tests, .screenshots, (.links | length)]')" '["Adds a panel","13 passed",["/private/tmp/claude-501/c.png"],2]'
"$B" set-review "$r" --preview ""
eq "$(rv 'has("preview_url")')" false
eq "$("$B" show | grep -c '^    review: ')" 1
eq "$("$B" show | grep '^    review: ')" "    review: Adds a panel | 1 shot | 2 links | tests: 13 passed"
for bad in "--preview javascript:alert(1)" "--preview ftp://h/x" "--preview 'http://a b'" "--link 'x|javascript:1'" "--link 'noseparator'" "--link '|http://a.b'" "--link 'x|file:///etc/passwd'" "--screenshot relative.png" "--nope 1"; do
  eval "\"\$B\" set-review \"\$r\" $bad" 2>/dev/null && { echo "FAIL: set-review accepted '$bad'" >&2; exit 1; }
done
"$B" set-review "$d" --summary x 2>/dev/null && { echo "FAIL: set-review on decision" >&2; exit 1; }
"$B" set-review T-999 --summary x 2>/dev/null && { echo "FAIL: set-review unknown id" >&2; exit 1; }
eq "$(rv '.tests')" '"13 passed"'
"$B" status "$r" cancelled

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

adir="$T/.claude/orchestrator/demo"
eq "$("$B" consume-answers demo)" "settled 0, refused 0, unparseable 0"
[[ ! -e "$adir/answers.done.jsonl" ]] || { echo "FAIL: nothing to consume should not create answers.done.jsonl" >&2; exit 1; }

ca1=$("$B" add decision "Pick spacing" --option "A|Compact" --option "B|Comfortable")
ca2=$("$B" add decision "Pick weight" --option "A|Light" --option "B|Bold")
now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '{"project":"demo","id":"%s","key":"B","text":"Comfortable","at":"%s"}\n' "$ca1" "$now_ts"
  printf '{"project":"other","id":"%s","key":"A","text":"Light","at":"%s"}\n' "$ca2" "$now_ts"
} > "$adir/answers.jsonl"
out=$("$B" consume-answers demo)
eq "$(head -1 <<<"$out")" "settled 1, refused 1, unparseable 0"
eq "$(jq -r --arg id "$ca1" '.entries[] | select(.id == $id) | .status' "$f")" settled
eq "$(jq -r --arg id "$ca1" '.entries[] | select(.id == $id) | .answer' "$f")" "Comfortable"
eq "$(jq -r --arg id "$ca2" '.entries[] | select(.id == $id) | .status' "$f")" open
[[ ! -e "$adir/answers.jsonl" ]] || { echo "FAIL: no concurrent write, answers.jsonl should be gone" >&2; exit 1; }
eq "$(wc -l < "$adir/answers.done.jsonl" | tr -d ' ')" 2
eq "$(jq -r --arg id "$ca1" 'select(.id == $id) | .result' "$adir/answers.done.jsonl")" settled
eq "$(jq -r --arg id "$ca2" 'select(.id == $id) | .result' "$adir/answers.done.jsonl")" refused
eq "$(jq -r --arg id "$ca2" 'select(.id == $id) | has("reason")' "$adir/answers.done.jsonl")" true

# A line whose answer predates the decision's last change (e.g. it was reopened) is refused, not reconsidered.
ca3=$("$B" add decision "Pick tone" --option "A|Warm" --option "B|Cool")
stale_at=$(jq -r --arg id "$ca3" '.entries[] | select(.id == $id) | .updated' "$f")
sleep 1.1
"$B" status "$ca3" open
printf '{"project":"demo","id":"%s","key":"B","text":"Cool","at":"%s"}\n' "$ca3" "$stale_at" > "$adir/answers.jsonl"
eq "$("$B" consume-answers demo | head -1)" "settled 0, refused 1, unparseable 0"
eq "$(jq -r --arg id "$ca3" '.entries[] | select(.id == $id) | .status' "$f")" open
eq "$(wc -l < "$adir/answers.done.jsonl" | tr -d ' ')" 3

# A malformed line (not even JSON, or not a JSON object) is recorded as unparseable, never aborts the run,
# and a valid line elsewhere in the same file still settles.
ca3b=$("$B" add decision "Pick density" --option "A|Loose" --option "B|Snug")
now_ts2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf 'not json at all\n'
  printf '["also","not","an","object"]\n'
  printf '{"project":"demo","id":"%s","key":"B","text":"Snug","at":"%s"}\n' "$ca3b" "$now_ts2"
} > "$adir/answers.jsonl"
before_unp=$(wc -l < "$adir/answers.done.jsonl" | tr -d ' ')
eq "$("$B" consume-answers demo 2>/dev/null | head -1)" "settled 1, refused 0, unparseable 2"
eq "$(jq -r --arg id "$ca3b" '.entries[] | select(.id == $id) | .status' "$f")" settled
eq "$(jq -r --arg id "$ca3b" '.entries[] | select(.id == $id) | .answer' "$f")" "Snug"
eq "$(wc -l < "$adir/answers.done.jsonl" | tr -d ' ')" "$((before_unp + 3))"
eq "$(jq -c 'select(.result == "unparseable") | .raw' "$adir/answers.done.jsonl" | sort -u | wc -l | tr -d ' ')" 2
eq "$(jq -r 'select(.raw == "not json at all") | .result' "$adir/answers.done.jsonl")" unparseable

"$B" consume-answers other 2>/dev/null && { echo "FAIL: consume-answers rejects mismatched project" >&2; exit 1; }

# Atomicity: a line appended to the fresh answers.jsonl left behind by consume-answers's rename is never lost.
race_ids=()
for i in $(seq 1 40); do race_ids+=("$("$B" add decision "Race $i" --option "A|Yes $i" --option "B|No $i")"); done
race_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
: > "$adir/answers.jsonl"
for id in "${race_ids[@]}"; do
  txt=$(jq -r --arg id "$id" '.entries[] | select(.id == $id) | .options[0].text' "$f")
  printf '{"project":"demo","id":"%s","key":"A","text":"%s","at":"%s"}\n' "$id" "$txt" "$race_ts" >> "$adir/answers.jsonl"
done
before_done=$(wc -l < "$adir/answers.done.jsonl" | tr -d ' ')
"$B" consume-answers demo > "$T/race.out" &
race_pid=$!
sleep 0.15
printf '{"project":"demo","id":"bogus","key":"A","text":"x","at":"1970-01-01T00:00:00Z"}\n' > "$adir/answers.jsonl"
wait "$race_pid"
eq "$(head -1 "$T/race.out")" "settled 40, refused 0, unparseable 0"
[[ -f "$adir/answers.jsonl" ]] || { echo "FAIL: concurrently-appended answers.jsonl lost" >&2; exit 1; }
eq "$(cat "$adir/answers.jsonl")" '{"project":"demo","id":"bogus","key":"A","text":"x","at":"1970-01-01T00:00:00Z"}'
eq "$(wc -l < "$adir/answers.done.jsonl" | tr -d ' ')" "$((before_done + 40))"
for id in "${race_ids[@]}"; do
  eq "$(jq -r --arg id "$id" '.entries[] | select(.id == $id) | .status' "$f")" settled
done
eq "$("$B" consume-answers demo | head -1)" "settled 0, refused 1, unparseable 0"
[[ ! -e "$adir/answers.jsonl" ]] || { echo "FAIL: the concurrent line should now be claimed" >&2; exit 1; }

# Concurrent writers: two 'add' calls launched together against the same board must not clobber
# each other's read-modify-write, and must get distinct sequential ids (proves the flock in with_lock
# serializes the load-modify-save cycle instead of racing).
before_n=$(jq '.entries | length' "$f")
"$B" add task "Concurrent A" > "$T/conc_a.out" 2> "$T/conc_a.err" &
conc_a_pid=$!
"$B" add task "Concurrent B" > "$T/conc_b.out" 2> "$T/conc_b.err" &
conc_b_pid=$!
wait "$conc_a_pid"; conc_a_rc=$?
wait "$conc_b_pid"; conc_b_rc=$?
eq "$conc_a_rc" 0
eq "$conc_b_rc" 0
conc_a_id=$(cat "$T/conc_a.out")
conc_b_id=$(cat "$T/conc_b.out")
[[ $conc_a_id != "$conc_b_id" ]] || { echo "FAIL: concurrent adds produced duplicate id $conc_a_id" >&2; exit 1; }
eq "$(jq '.entries | length' "$f")" "$((before_n + 2))"
eq "$(jq -r --arg i "$conc_a_id" '.entries[] | select(.id == $i) | .title' "$f")" "Concurrent A"
eq "$(jq -r --arg i "$conc_b_id" '.entries[] | select(.id == $i) | .title' "$f")" "Concurrent B"

# Stress variant: a burst of concurrent adds must all land, with unique sequential ids and no gaps.
before_stress=$(jq '.entries | length' "$f")
stress_pids=()
for i in $(seq 1 12); do
  "$B" add task "Stress $i" > "$T/stress_$i.out" &
  stress_pids+=($!)
done
for pid in "${stress_pids[@]}"; do wait "$pid"; done
stress_ids=()
for i in $(seq 1 12); do stress_ids+=("$(cat "$T/stress_$i.out")"); done
eq "$(printf '%s\n' "${stress_ids[@]}" | sort -u | wc -l | tr -d ' ')" 12
eq "$(jq '.entries | length' "$f")" "$((before_stress + 12))"
for id in "${stress_ids[@]}"; do
  eq "$(jq -r --arg i "$id" '[.entries[] | select(.id == $i)] | length' "$f")" 1
done

# Lock timeout: while another process holds tasks.json.lock, a write must fail fast with a clear
# non-zero exit and message instead of hanging forever.
lockfile="$adir/tasks.json.lock"
mkdir -p "$adir"
flock -x "$lockfile" -c "sleep 3" &
holder_pid=$!
sleep 0.3
before_timeout=$(jq '.entries | length' "$f")
set +e
HERDMASTER_LOCK_TIMEOUT=1 "$B" add task "Should not land" > "$T/timeout.out" 2> "$T/timeout.err"
timeout_rc=$?
set -e
wait "$holder_pid" 2>/dev/null || true
[[ $timeout_rc -ne 0 ]] || { echo "FAIL: add succeeded despite held lock" >&2; exit 1; }
grep -qi "lock" "$T/timeout.err" || { echo "FAIL: lock timeout message unclear: $(cat "$T/timeout.err")" >&2; exit 1; }
eq "$(jq '.entries | length' "$f")" "$before_timeout"

jq '.entries += [range(205) | {id: "T-\(100 + .)", kind: "task", title: "x", status: "done", review: "auto", depends_on: [], attempts: [], created: "2020-01-01T00:00:00Z", updated: "2021-01-01T00:\(10 + (. / 60 | floor)):\(10 + (. % 60))Z"}]' "$f" > "$T/big.json"
mv "$T/big.json" "$f"
eq "$("$B" archive)" "archived 7"
eq "$(jq '[.entries[] | select(.status == "done" or .status == "cancelled")] | length' "$f")" 200
eq "$(jq '.entries | length' "$T/.claude/orchestrator/demo/tasks-archive.json")" 7
eq "$("$B" archive)" ""

# --- Ticket-letter decision ids: sequential per-ticket numbering, isolated in a fresh project so the
# letter/number assignments below are exact and don't depend on the giant scenario above. ---
tf="$T/.claude/orchestrator/tix/tasks.json"
tx1=$(HERDMASTER_PROJECT=tix "$B" add decision "Q1" --group Nav)
tx2=$(HERDMASTER_PROJECT=tix "$B" add decision "Q2" --group Nav)
tx3=$(HERDMASTER_PROJECT=tix "$B" add decision "Q3" --group Perf)
eq "$tx1 $tx2 $tx3" "A1 A2 B1"
eq "$(jq -c '.tickets' "$tf")" '{"Nav":"A","Perf":"B"}'
# A decision with no --group goes under a ticket literally named "Other", with its own sequence.
tx4=$(HERDMASTER_PROJECT=tix "$B" add decision "Q4")
tx5=$(HERDMASTER_PROJECT=tix "$B" add decision "Q5")
eq "$tx4 $tx5" "C1 C2"
eq "$(jq -r --arg i "$tx4" '.entries[] | select(.id == $i) | .group // "none"' "$tf")" none
eq "$(jq -c '.tickets' "$tf")" '{"Nav":"A","Perf":"B","Other":"C"}'
# Adding a fourth question to an existing ticket continues that ticket's own sequence.
tx6=$(HERDMASTER_PROJECT=tix "$B" add decision "Q6" --group Nav)
eq "$tx6" "A3"
# set-group across tickets renumbers into the target ticket's sequence and rewrites every reference.
HERDMASTER_PROJECT=tix "$B" add task "Depends on Q3" --depends "$tx3" >/dev/null
HERDMASTER_PROJECT=tix "$B" supersede "$tx4"
tx3b=$(HERDMASTER_PROJECT=tix "$B" set-group "$tx3" Nav)
eq "$tx3b" "A4"
eq "$(jq -r --arg i "$tx3b" '.entries[] | select(.kind == "task") | .depends_on[0]' "$tf")" "$tx3b"
eq "$(jq -c '[.entries[] | select(.id == "'"$tx3"'")]' "$tf")" '[]'
# Moving a decision back to the ticket it is already in is a no-op (same id, no spurious renumber).
tx6b=$(HERDMASTER_PROJECT=tix "$B" set-group "$tx6" Nav)
eq "$tx6b" "$tx6"

echo "ok"
