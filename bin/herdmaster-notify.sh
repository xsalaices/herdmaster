#!/usr/bin/env bash
# One pass of the decision notifier: one macOS notification per new open decision, and the herdr workspace label refresh.
# Run every 10 s by launchd (com.herdmaster.notify). Boards: $HOME/.claude/orchestrator/*/tasks.json.
# Quiet start: the first pass records a start marker; decisions already open at that time are marked announced, never notified.
# Per-project state: .notified next to tasks.json (announced ids). settings.json "notify": "off" silences a project.
# Test overrides: OSASCRIPT_BIN, LABELS_BIN.
set -uo pipefail

command -v jq >/dev/null || { echo "herdmaster-notify: jq is required" >&2; exit 1; }
HM_HOME=${HERDMASTER_HOME:-$HOME/.claude/herdmaster}
OSASCRIPT=${OSASCRIPT_BIN:-osascript}
LABELS=${LABELS_BIN:-$(cd "$(dirname "$0")" && pwd)/herdmaster-labels.sh}
ORCH="$HOME/.claude/orchestrator"
MARKER="$HM_HOME/state/notify.started"

if [[ ! -f $MARKER ]]; then
  mkdir -p "$HM_HOME/state"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
fi
started=$(cat "$MARKER")

for board in "$ORCH"/*/tasks.json; do
  [[ -f $board ]] || continue
  dir=$(dirname "$board"); project=$(basename "$dir")
  open=$(jq -c '[.entries[] | select(.kind == "decision" and .status == "open") | {id, title, created}]' "$board" 2>/dev/null) || continue
  [[ -n $open ]] || continue
  state="$dir/.notified"

  if [[ ! -f $state ]]; then
    jq -r --arg s "$started" '.[] | select(.created <= $s) | .id' <<<"$open" > "$state"
  fi

  notify=$(jq -r '.notify // "on"' "$dir/settings.json" 2>/dev/null) || notify=on
  while IFS=$'\t' read -r id title; do
    [[ -n $id ]] || continue
    grep -qxF -- "$id" "$state" && continue
    if [[ $notify == off ]] || "$OSASCRIPT" \
      -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
      -- "herdmaster: $project" "$id: $title" >/dev/null 2>&1; then
      echo "$id" >> "$state"
    fi
  done < <(jq -r '.[] | "\(.id)\t\(.title | gsub("[\t\r\n]"; " "))"' <<<"$open")

  ws=$(jq -r '.herdr_workspace // empty' "$dir/settings.json" 2>/dev/null) || ws=""
  [[ -n $ws ]] && HERDMASTER_PROJECT=$project "$LABELS" workspace "$ws" >/dev/null 2>&1
done
exit 0
