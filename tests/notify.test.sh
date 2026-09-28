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

# --- Ticket-level "ready to hand off" notifications, isolated in a fresh project (a colon-prefixed
# "ticket:<letter>" marker in the same .notified state file, never colliding with a decision id). ---
export HERDMASTER_PROJECT=tix
STATE="$T/.claude/orchestrator/tix/.notified"
tlines() { grep -cxF -- "$1" "$STATE" 2>/dev/null || true; }

q1=$("$B" add decision "Sidebar or top nav" --group Nav --option "A|Sidebar" --option "B|Top" --recommend-key A)
q2=$("$B" add decision "Color scheme" --group Nav --option "A|Dark" --option "B|Light" --recommend-key A)
pass
eq "$(lines "$LOG")" 4 "tix is a brand new project: its 2 open decisions notify (no quiet start for a project seen for the first time long after notify.sh's own start marker)"
eq "$(tlines ticket:A)" 0 "ticket not ready while decisions are open"

"$B" settle "$q1" --answer A
"$B" settle "$q2" --answer A
pass
eq "$(lines "$LOG")" 5 "ticket becomes fully settled: exactly one notification"
grep -qF 'herdmaster: tix|Ready to hand off: A (Nav, 2 of 2)' "$LOG" || { echo "FAIL: ticket notification missing or wrong text" >&2; exit 1; }
eq "$(tlines ticket:A)" 1 "ticket marker set after notifying"
pass
eq "$(lines "$LOG")" 5 "second pass with no change: no repeat ticket notification"

q3=$("$B" add decision "Third nav question" --group Nav --option "A|Yes" --option "B|No" --recommend-key A)
pass
eq "$(lines "$LOG")" 6 "new open decision in the ticket: one per-decision notify, no ticket notify"
eq "$(tlines ticket:A)" 0 "adding a decision to a ready ticket clears its notified-ready marker"

"$B" settle "$q3" --answer A
pass
eq "$(lines "$LOG")" 7 "ticket fully settled again: fires exactly one more notification"
grep -qF 'herdmaster: tix|Ready to hand off: A (Nav, 3 of 3)' "$LOG" || { echo "FAIL: second ticket notification missing or wrong text" >&2; exit 1; }
eq "$(tlines ticket:A)" 1 "ticket marker set again after re-notifying"

# notify=off: the marker still gets set (same semantics as a muted decision), so it does not backlog-fire
# once notify is turned back on. Needs a pass between add and settle so the ticket is actually observed as
# reopened (and its marker cleared) before it is observed as ready again.
"$B" settings set notify off
q4=$("$B" add decision "Fourth nav question" --group Nav --option "A|Yes" --option "B|No" --recommend-key A)
pass
eq "$(lines "$LOG")" 7 "notify off: new open decision reopens the ticket silently"
eq "$(tlines ticket:A)" 0 "reopened ticket's marker cleared even while notify is off"
"$B" settle "$q4" --answer A
pass
eq "$(lines "$LOG")" 7 "notify off: ticket ready again but silent"
eq "$(tlines ticket:A)" 1 "notify off still sets the marker"
"$B" settings set notify on
pass
eq "$(lines "$LOG")" 7 "ticket already marked ready is not announced retroactively after re-enabling notify"
echo ok
