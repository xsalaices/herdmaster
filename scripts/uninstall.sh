#!/usr/bin/env bash
# Removes what install.sh added: com.herdmaster.* LaunchAgents, $HERDMASTER_HOME, the two skills,
# and the pressure-guard hook entry (other hooks are left untouched).
# Usage: scripts/uninstall.sh [--dry-run] [--keep-skills]
set -euo pipefail

DRY=0; KEEP_SKILLS=0
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    --keep-skills) KEEP_SKILLS=1 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

CLAUDE_DIR="$HOME/.claude"
HERDMASTER_HOME="${HERDMASTER_HOME:-$CLAUDE_DIR/herdmaster}"
LA_DIR="$HOME/Library/LaunchAgents"
SETTINGS="$CLAUDE_DIR/settings.json"
GUARD="$HERDMASTER_HOME/bin/pressure-guard.sh"
case $HERDMASTER_HOME in "$CLAUDE_DIR"/?*) ;; *) echo "HERDMASTER_HOME must be inside $CLAUDE_DIR" >&2; exit 2 ;; esac

run() { if (( DRY )); then echo "[dry-run] $*"; else "$@"; fi; }

for j in cpu-reaper pressure-check blocked-pane-watcher; do
  p="$LA_DIR/com.herdmaster.$j.plist"
  [[ -f $p ]] || continue
  run launchctl bootout "gui/$(id -u)/com.herdmaster.$j" || true
  run rm -f "$p"
done

if [[ -f $SETTINGS ]] && jq empty "$SETTINGS" 2>/dev/null; then
  merged=$(jq --arg cmd "$GUARD" '
    if .hooks.PreToolUse then
      .hooks.PreToolUse |= (map(.hooks |= map(select(.command != $cmd))) | map(select((.hooks | length) > 0)))
    else . end' "$SETTINGS")
  if (( DRY )); then
    echo "[dry-run] would remove pressure-guard hook from $SETTINGS"
  else
    cp "$SETTINGS" "$SETTINGS.herdmaster-backup-$(date +%Y%m%d%H%M%S)"
    printf '%s\n' "$merged" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi
fi

if (( ! KEEP_SKILLS )); then
  for s in master orchestrator; do
    [[ -f $CLAUDE_DIR/skills/$s/SKILL.md ]] && { run rm -f "$CLAUDE_DIR/skills/$s/SKILL.md"; run rmdir "$CLAUDE_DIR/skills/$s" 2>/dev/null || true; }
  done
fi

for f in pressure-check.sh pressure-guard.sh cpu-reaper.sh blocked-pane-watcher.sh; do
  [[ -f $HERDMASTER_HOME/bin/$f ]] && run rm -f "$HERDMASTER_HOME/bin/$f"
done
echo "State and logs in $HERDMASTER_HOME are kept; delete that folder by hand if you want them gone."
