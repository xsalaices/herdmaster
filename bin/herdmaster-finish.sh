#!/usr/bin/env bash
# A worker's last action once its task is fully done: report to the orchestrator, record what it learned, close its own pane.
# Usage: herdmaster-finish.sh --summary "<what changed, test results, anything not done>"
#          [--to <orchestrator name>] [--memory "<one non-obvious fact worth keeping>" --memory-name <slug> [--memory-type project|feedback|reference|user]]
#          [--no-exit]
# --to defaults to ~/.claude/orchestrator/$HERDMASTER_PROJECT/orchestrator. The report goes through herdmaster-send.sh; the pane is
# only closed if that succeeded, so a failed report leaves the worker alive to retry. Memory lands in the main checkout's Claude
# memory dir (override: HERDMASTER_MEMORY_DIR): one file per fact plus an index line in MEMORY.md; an existing name is refused.
set -euo pipefail

die() { echo "herdmaster-finish: $*" >&2; exit 2; }
BIN=$(cd "$(dirname "$0")" && pwd)
SUMMARY="" TO="" MEM="" MEMNAME="" MEMTYPE=project EXIT=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --summary) SUMMARY=${2:-}; shift 2 ;;
    --to) TO=${2:-}; shift 2 ;;
    --memory) MEM=${2:-}; shift 2 ;;
    --memory-name) MEMNAME=${2:-}; shift 2 ;;
    --memory-type) MEMTYPE=${2:-}; shift 2 ;;
    --no-exit) EXIT=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n ${SUMMARY//[[:space:]]/} ]] || die "--summary is required"
if [[ -z $TO ]]; then
  [[ -n ${HERDMASTER_PROJECT:-} ]] || die "--to or HERDMASTER_PROJECT is required"
  TO=$(tr -d '[:space:]' < "$HOME/.claude/orchestrator/$HERDMASTER_PROJECT/orchestrator" 2>/dev/null) || true
  [[ -n $TO ]] || die "no orchestrator name in ~/.claude/orchestrator/$HERDMASTER_PROJECT/orchestrator"
fi
if [[ -n $MEM ]]; then
  [[ $MEMNAME =~ ^[a-z0-9][a-z0-9-]{0,60}$ ]] || die "--memory-name must be a kebab-case slug"
  [[ $MEMTYPE =~ ^(project|feedback|reference|user)$ ]] || die "--memory-type must be project, feedback, reference or user"
fi

# Memory first (local and cheap), so a report is never sent for work whose lesson then fails to save.
if [[ -n $MEM ]]; then
  MDIR=${HERDMASTER_MEMORY_DIR:-}
  if [[ -z $MDIR ]]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not in a git repo; set HERDMASTER_MEMORY_DIR"
    main=${common%/.git}
    MDIR="$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$main")/memory"
  fi
  mkdir -p -- "$MDIR"
  [[ ! -e $MDIR/$MEMNAME.md ]] || die "memory '$MEMNAME' already exists; pick another name"
  desc=$(head -n1 <<<"$MEM" | cut -c1-120)
  printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  type: %s\n---\n\n%s\n' "$MEMNAME" "$desc" "$MEMTYPE" "$MEM" > "$MDIR/$MEMNAME.md"
  printf -- '- [%s](%s.md) — %s\n' "$MEMNAME" "$MEMNAME" "$desc" >> "$MDIR/MEMORY.md"
fi

"$BIN/herdmaster-send.sh" "$TO" "FULLY DONE: $SUMMARY" >/dev/null

if (( EXIT )); then
  [[ -n ${HERDR_PANE_ID:-} ]] || die "HERDR_PANE_ID not set; report sent, pane not closed"
  exec "${HERDR_BIN:-herdr}" pane close "$HERDR_PANE_ID"
fi
echo "reported to $TO"
