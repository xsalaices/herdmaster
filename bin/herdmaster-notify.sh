#!/usr/bin/env bash
# One pass of the decision notifier: one macOS notification per new open decision, one per ticket newly
# ready to hand off (every decision in it settled), and the herdr workspace label refresh.
# Run every 10 s by launchd (com.herdmaster.notify). Boards: $HOME/.claude/orchestrator/*/tasks.json.
# Quiet start: the first pass records a start marker; decisions already open at that time are marked announced, never notified.
# Per-project state: .notified next to tasks.json (announced decision ids, plus "ticket:<letter>" markers for
# tickets already notified ready). settings.json "notify": "off" silences a project, for both kinds.
# Ticket readiness is recomputed fresh every pass (no quiet start for it, unlike decisions): a ticket already
# marked ready that no longer is (a decision was added or reopened, via 'add decision --group' or
# 'set-group') has its marker dropped here so it notifies again once every decision in it is settled again.
# Ceiling: a ticket already fully settled before this feature existed for a project notifies once on the
# first pass after upgrading (there is no historical "created <= started" cutoff for tickets as there is for
# decisions); acceptable since it only ever over-notifies once per pre-existing ready ticket.
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

  # Ticket readiness: a ticket (decisions grouped by .group, default "Other") is ready to hand off once it
  # has at least one decision and none open. Markers live in the same $state file as "ticket:<letter>" (a
  # colon can never appear in a decision id, so there is no collision) and are recomputed fresh every pass --
  # keep this jq filter in sync with the one in herdmaster-labels.sh.
  ready=$(jq -c '
    (.tickets // {}) as $tickets
    | [.entries[] | select(.kind == "decision" and (.status == "open" or .status == "settled"))] as $ds
    | ($ds | group_by(.group // "Other")
        | map({name: (.[0].group // "Other"),
               open: ([.[] | select(.status == "open")] | length),
               total: length}))
    | map(select(.open == 0))
    | map({name, letter: ($tickets[.name] // .name), total})
  ' "$board" 2>/dev/null) || ready='[]'
  ready_letters=$(jq -r '.[].letter' <<<"$ready" 2>/dev/null) || ready_letters=""
  if [[ -f $state ]]; then
    tmp=$(mktemp "$dir/.notified.XXXXXX")
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -n $line ]] || continue
      if [[ $line == ticket:* ]]; then
        grep -qxF -- "${line#ticket:}" <<<"$ready_letters" && printf '%s\n' "$line" >> "$tmp"
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$state"
    mv "$tmp" "$state"
  fi
  while IFS=$'\t' read -r letter name total; do
    [[ -n $letter ]] || continue
    grep -qxF -- "ticket:$letter" "$state" 2>/dev/null && continue
    if [[ $notify == off ]] || "$OSASCRIPT" \
      -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
      -- "herdmaster: $project" "Ready to hand off: $letter ($name, $total of $total)" >/dev/null 2>&1; then
      echo "ticket:$letter" >> "$state"
    fi
  done < <(jq -r '.[] | "\(.letter)\t\(.name | gsub("[\t\r\n]"; " "))\t\(.total)"' <<<"$ready")

  ws=$(jq -r '.herdr_workspace // empty' "$dir/settings.json" 2>/dev/null) || ws=""
  [[ -n $ws ]] && HERDMASTER_PROJECT=$project "$LABELS" workspace "$ws" >/dev/null 2>&1
done
exit 0
