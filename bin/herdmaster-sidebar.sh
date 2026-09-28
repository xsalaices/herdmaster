#!/usr/bin/env bash
# Read-only board watcher for a permanent pane: polls tasks.json and redraws a compact text view.
# Usage: herdmaster-sidebar.sh [--project <name>] [--once]
# Project comes from --project, else $HERDMASTER_PROJECT. Never writes anything, never touches the network.
# --once renders a single frame and exits; test-only, used by tests/sidebar.test.sh.
set -euo pipefail

die() { echo "herdmaster-sidebar: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"

PROJECT=${HERDMASTER_PROJECT:-}
ONCE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT=${2:-}; shift 2 ;;
    --once) ONCE=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n $PROJECT ]] || die "--project or HERDMASTER_PROJECT is required"

BOARD="$HOME/.claude/orchestrator/$PROJECT/tasks.json"
SETTINGS="$HOME/.claude/orchestrator/$PROJECT/settings.json"

# Mirrors the viewer's tickets() sort (bin/herdmaster-viewer.py): "Other" last, tickets with an
# open decision first, then by first-appearance order in entries[].
JQ_FILTER='
def order_uniq:
  reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

def dispid:
  if test("^T-[0-9]+$") then sub("^T-0*"; "T") else . end;

def pad($s; $n):
  $s + ([range(0; ([$n - ($s|length), 0] | max))] | map(" ") | join(""));

def bucket:
  if (.status=="in review" or .status=="finished") then "in review"
  elif .status=="deploy-ready" then "ready"
  else "working" end;

($word) as $word
| (.entries // []) as $entries
| ($entries | map(select(.kind=="decision" and (.status=="open" or .status=="settled")))) as $ds
| (.tickets // {}) as $tk
| ($ds | map(.group // "Other") | order_uniq) as $names
| ($names | to_entries | map({name: .value, i: .key})) as $named
| ($named | map(
    . as $g
    | $g + {qs: ($ds | map(select((.group // "Other") == $g.name)))}
  )) as $withqs
| ($withqs | map(. + {left: ([.qs[] | select(.status=="open")] | length), total: (.qs|length)})) as $tickets0
| ($tickets0 | sort_by([(.name=="Other"), (if .left>0 then 0 else 1 end), .i])) as $ts
| ($ts | map(
    ($tk[.name] // "") as $letter
    | (((.total-.left)|tostring) + "/" + (.total|tostring) + " answered") as $cnt
    | (if .left==0 then $cnt + "  Ready to hand off" else $cnt end) as $cnt2
    | "  " + (if $letter=="" then "" else $letter+" " end) + .name + "   " + $cnt2
  )) as $ticket_lines
| (if ($ticket_lines|length)==0 then ["  (none)"] else $ticket_lines end) as $ticket_out
| ($entries | map(select(.kind!="decision" and .status!="done" and .status!="cancelled"))) as $tasks
| ($tasks | map({id: (.id|dispid), b: bucket})) as $tb
| (["in review","working","ready"] | map(if .=="ready" then "ready to " + $word else . end)) as $labels
| (([$labels[] | length] | max) + 2) as $labelw
| (["in review","working","ready"] | map(
     . as $b
     | ($tb | map(select(.b==$b)) | map(.id) | join(", ")) as $list
     | (if $b=="ready" then "ready to " + $word else $b end) as $label
     | "  " + pad($label; $labelw) + (if $list=="" then "(none)" else $list end)
   )) as $task_out
| (["Tickets"] + $ticket_out + ["Tasks"] + $task_out) | .[]
'

release_word() {
  local w=deploy
  if [[ -f $SETTINGS ]]; then
    w=$(jq -r '.release // "deploy"' "$SETTINGS" 2>/dev/null) || w=deploy
    [[ $w =~ ^(merge|deploy|push|ship)$ ]] || w=deploy
  fi
  echo "$w"
}

render() {
  if [[ ! -f $BOARD ]]; then
    echo "No board file yet for project '$PROJECT'."
    return
  fi
  local word out
  word=$(release_word)
  if ! out=$(jq -r --arg word "$word" "$JQ_FILTER" "$BOARD" 2>/dev/null); then
    echo "Board file is invalid JSON."
    return
  fi
  printf '%s\n' "$out"
}

if (( ONCE )); then
  render
  exit 0
fi

cleanup() {
  tput rmcup 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

tput smcup 2>/dev/null || true
tput civis 2>/dev/null || true
while true; do
  tput clear 2>/dev/null || clear
  render
  sleep 2.5
done
