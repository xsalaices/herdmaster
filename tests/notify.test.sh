#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)/bin"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T"
B="$R/herdmaster-board.sh" N="$R/herdmaster-notify.sh"
LOG="$T/osa.log" LBL="$T/labels.log"
cat > "$T/osa" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${@: -2:1}|${@: -1}" >> "$OSA_LOG"
SH
cat > "$T/lbl" <<'SH'
#!/usr/bin/env bash
echo "$HERDMASTER_PROJECT $*|$("$B_BIN" show 2>/dev/null | awk -F'\t' '$1 !~ /^T-[0-9]+$/ && $2 == "open"' | wc -l | tr -d ' ')" >> "$LBL_LOG"
SH
chmod +x "$T/osa" "$T/lbl"
export B_BIN="$B" OSA_LOG="$LOG" LBL_LOG="$LBL" OSASCRIPT_BIN="$T/osa" LABELS_BIN="$T/lbl"
: > "$LOG"; : > "$LBL"
lines() { wc -l < "$1" | tr -d ' '; }
eq() { [[ $1 == "$2" ]] || { echo "FAIL: $3: got '$1' want '$2'" >&2; exit 1; }; }
pass() { "$N"; }

export HERDMASTER_PROJECT=demo
"$B" add decision 'Old question' >/dev/null
pass
eq "$(lines "$LOG")" 0 "existing decision stays quiet on first run"
sleep 1

"$B" add decision 'Pick "a" db; $(x) \ ok' >/dev/null
pass
eq "$(lines "$LOG")" 1 "new decision notifies once"
grep -qF 'herdmaster: demo|A2: Pick "a" db; $(x) \ ok' "$LOG" || { echo "FAIL: text not passed verbatim" >&2; exit 1; }
pass
eq "$(lines "$LOG")" 1 "second pass silent"

sleep 1
"$B" add decision 'Second' >/dev/null
pass
eq "$(lines "$LOG")" 2 "second new id notifies once"
pass
eq "$(lines "$LOG")" 2 "no repeat"

sleep 1
"$B" add decision 'Will settle' >/dev/null
"$B" status A4 settled
"$B" add decision 'Will supersede' >/dev/null
"$B" supersede A5
pass
eq "$(lines "$LOG")" 2 "settled and superseded ignored"

"$B" settings set notify off
sleep 1
"$B" add decision 'Muted' >/dev/null
pass
eq "$(lines "$LOG")" 2 "notify off silent"
"$B" settings set notify on
pass
eq "$(lines "$LOG")" 2 "muted decision not announced after turning back on"
"$B" settings set notify maybe 2>/dev/null && { echo "FAIL: bad notify value accepted" >&2; exit 1; }

mkdir -p "$T/.claude/orchestrator/broken"
echo '{not json' > "$T/.claude/orchestrator/broken/tasks.json"
pass
eq "$(lines "$LOG")" 2 "invalid tasks.json skipped"

eq "$(lines "$LBL")" 0 "no label refresh without herdr_workspace"
"$B" settings set herdr_workspace ws-1
pass
grep -q '^demo workspace ws-1|' "$LBL" || { echo "FAIL: labels not called" >&2; exit 1; }
grep -q "|4$" <(tail -1 "$LBL") || { echo "FAIL: wrong count: $(tail -1 "$LBL")" >&2; exit 1; }
echo ok
