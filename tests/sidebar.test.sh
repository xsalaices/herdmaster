#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)/bin"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T" HERDMASTER_PROJECT=demo
B="$R/herdmaster-board.sh" S="$R/herdmaster-sidebar.sh"
has() { grep -qF -- "$2" <<<"$1" || { echo "FAIL: missing '$2' in: $1" >&2; exit 1; }; }
lacks() { grep -qF -- "$2" <<<"$1" && { echo "FAIL: unexpected '$2' in: $1" >&2; exit 1; }; return 0; }

# No board file yet: one clear line, exit 0, no crash.
out=$("$S" --project demo --once)
has "$out" "No board file yet"

mkdir -p "$T/.claude/orchestrator/demo"
echo "not json" > "$T/.claude/orchestrator/demo/tasks.json"
out=$("$S" --project demo --once)
has "$out" "invalid JSON"
rm -f -- "$T/.claude/orchestrator/demo/tasks.json"

"$B" add decision "Sidebar or top nav" --group "Navigation redesign" >/dev/null
"$B" add decision "Pick a color" --group "Navigation redesign" >/dev/null
"$B" status A1 settled >/dev/null
"$B" add decision "Pick a db" >/dev/null # ungrouped -> Other, still open
"$B" add task "Build the thing" >/dev/null
"$B" status T-001 "in review" >/dev/null
"$B" add task "Ship the widget" >/dev/null
"$B" status T-002 "deploy-ready" >/dev/null
"$B" add task "Draft the plan" >/dev/null # stays "working"

out=$("$S" --project demo --once)
has "$out" "Tickets"
has "$out" "A Navigation redesign"
has "$out" "1/2 answered"
has "$out" "B Other"
has "$out" "Tasks"
has "$out" "in review"
has "$out" "T1"
has "$out" "working"
has "$out" "T3"
has "$out" "ready to deploy"
has "$out" "T2"

"$B" status A2 settled >/dev/null
out=$("$S" --project demo --once)
has "$out" "Ready to hand off"

"$B" settings set release merge >/dev/null
out=$("$S" --project demo --once)
has "$out" "ready to merge"
lacks "$out" "ready to deploy"

echo ok
