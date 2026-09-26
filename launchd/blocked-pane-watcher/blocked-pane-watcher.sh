#!/usr/bin/env bash
# EXAMPLE: blocked-pane watcher. One pass per run (schedule via launchd, or loop it yourself).
# Lists herdr agents whose status is "blocked" (waiting on a permission prompt or input),
# records new ones in $HERDMASTER_HOME/state/blocked-panes.txt and sends a macOS notification.
# It never answers prompts. The master or orchestrator reads the pane (herdr pane read <pane>),
# answers safe prompts, and escalates anything destructive or outward-facing.
# Adjust the jq paths if your herdr version prints a different JSON shape.
HERDMASTER_HOME="${HERDMASTER_HOME:-$HOME/.claude/herdmaster}"
OUT="$HERDMASTER_HOME/state/blocked-panes.txt"
SEEN="$HERDMASTER_HOME/state/blocked-panes.seen"
mkdir -p "$HERDMASTER_HOME/state"
touch "$SEEN"

blocked=$(herdr agent list 2>/dev/null | jq -r '.result.agents[]? | select(.agent_status=="blocked") | .pane_id')
: > "$OUT.tmp"
for pane in $blocked; do
  echo "$pane" >> "$OUT.tmp"
  if ! grep -qx "$pane" "$SEEN"; then
    echo "$pane" >> "$SEEN"
    osascript -e "display notification \"Pane $pane is blocked\" with title \"herdmaster\"" 2>/dev/null
  fi
done
mv "$OUT.tmp" "$OUT"
# Forget panes that are no longer blocked so a later block notifies again.
if [[ -s $OUT ]]; then grep -Fxf "$OUT" "$SEEN" > "$SEEN.tmp"; else : > "$SEEN.tmp"; fi
mv "$SEEN.tmp" "$SEEN"
exit 0
