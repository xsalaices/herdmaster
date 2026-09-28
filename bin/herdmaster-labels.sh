#!/usr/bin/env bash
# Writes board summaries into herdr display metadata.
# Usage: herdmaster-labels.sh [--dry-run] workspace <workspace-id>   token "project" = project name, "decisions" = open decision count,
#                                                                     "ready" = tickets with every decision settled (at least one, none open)
#        herdmaster-labels.sh [--dry-run] pane <pane-id> <task-id>   pane title "<handle> <task title> · <status>", handle T-003 -> T3
#        herdmaster-labels.sh [--dry-run] clear <pane-id>            removes the pane title
# Project comes from $HERDMASTER_PROJECT. --dry-run prints the herdr commands instead of running them.
set -euo pipefail

die() { echo "herdmaster-labels: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
[[ -n ${HERDMASTER_PROJECT:-} ]] || die "HERDMASTER_PROJECT is not set"

HERDR=${HERDMASTER_HERDR:-herdr}
BOARD="$(cd "$(dirname "$0")" && pwd)/herdmaster-board.sh"
SOURCE=herdmaster
TTL_MS=${HERDMASTER_LABEL_TTL_MS:-86400000}
DRY=0
[[ ${1:-} == --dry-run ]] && { DRY=1; shift; }

run() {
  if ((DRY)); then printf '%q ' "$@"; echo; else "$@" >/dev/null; fi
}

sub=${1:-}; shift || true
case $sub in
  workspace)
    ws=${1:-}; [[ -n $ws ]] || die "workspace: <workspace-id> required"
    # Decision ids are ticket letters + a number (never a dash); task ids are always T-XXX, so anything not
    # matching the task pattern is a decision (a ticket can be assigned the letter "T" itself, so matching
    # decisions directly by a leading letter would be wrong here).
    n=$("$BOARD" show | awk -F'\t' '$1 !~ /^T-[0-9]+$/ && $2 == "open"' | wc -l | tr -d ' ')
    # Ready-to-hand-off ticket count: reads tasks.json directly (same file herdmaster-notify.sh polls) since
    # readiness needs per-ticket grouping that "board show" doesn't carry for ungrouped (Other) decisions.
    # Keep this jq filter in sync with the one in herdmaster-notify.sh.
    board_file="$HOME/.claude/orchestrator/$HERDMASTER_PROJECT/tasks.json"
    ready=0
    if [[ -f $board_file ]]; then
      ready=$(jq -r '
        [.entries[] | select(.kind == "decision" and (.status == "open" or .status == "settled"))] as $ds
        | ($ds | group_by(.group // "Other")
            | map({open: ([.[] | select(.status == "open")] | length)}))
        | map(select(.open == 0)) | length
      ' "$board_file" 2>/dev/null) || ready=0
    fi
    run "$HERDR" workspace report-metadata --source "$SOURCE" --ttl-ms "$TTL_MS" \
      --token "project=$HERDMASTER_PROJECT" --token "decisions=$n" --token "ready=$ready" "$ws"
    ;;
  pane)
    pane=${1:-} id=${2:-}
    [[ -n $pane && -n $id ]] || die "pane: <pane-id> <task-id> required"
    line=$("$BOARD" show | awk -F'\t' -v id="$id" '$1 == id') || true
    [[ -n $line ]] || die "no such entry: $id"
    IFS=$'\t' read -r _ status _ title _ <<<"$line"
    handle=$(sed -E 's/^([A-Za-z]+)-0*([0-9]+)$/\1\2/' <<<"$id")
    run "$HERDR" pane report-metadata --source "$SOURCE" --ttl-ms "$TTL_MS" \
      --title "$handle $title · $status" "$pane"
    ;;
  clear)
    pane=${1:-}; [[ -n $pane ]] || die "clear: <pane-id> required"
    run "$HERDR" pane report-metadata --source "$SOURCE" --clear-title "$pane"
    ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
