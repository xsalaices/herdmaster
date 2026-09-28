#!/usr/bin/env bash
# Installs herdmaster into ~/.claude and ~/Library/LaunchAgents (com.herdmaster.* only).
# Usage: scripts/install.sh [--dry-run] [--with-watcher] [--force]
set -euo pipefail

DRY=0; WATCHER=0; FORCE=0
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    --with-watcher) WATCHER=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
HERDMASTER_HOME="${HERDMASTER_HOME:-$CLAUDE_DIR/herdmaster}"
LA_DIR="$HOME/Library/LaunchAgents"
SETTINGS="$CLAUDE_DIR/settings.json"
GUARD="$HERDMASTER_HOME/bin/pressure-guard.sh"

case $HERDMASTER_HOME in "$CLAUDE_DIR"/*) ;; *) echo "HERDMASTER_HOME must be inside $CLAUDE_DIR" >&2; exit 2 ;; esac

missing=0
[[ $(uname) == Darwin ]] || { echo "requirement missing: macOS (launchd jobs are macOS-only)" >&2; missing=1; }
for c in claude herdr jq python3 flock; do
  command -v "$c" >/dev/null || { echo "requirement missing: $c" >&2; missing=1; }
done
if (( missing )); then
  echo "Requirements: macOS, Claude Code (claude), herdr (https://herdr.dev), jq, python3, flock (brew install flock on macOS if missing). Install the missing ones and re-run." >&2
  exit 1
fi

run() { if (( DRY )); then echo "[dry-run] $*"; else "$@"; fi; }
say() { echo "$*"; }

say "herdmaster install (dry-run=$DRY) HOME=$HOME"

# 1. helper scripts
run mkdir -p "$HERDMASTER_HOME/bin" "$HERDMASTER_HOME/adapters" "$HERDMASTER_HOME/state" "$HERDMASTER_HOME/logs"
for f in "$REPO/hooks/pressure-check.sh" "$REPO/hooks/pressure-guard.sh" \
         "$REPO/launchd/cpu-reaper/cpu-reaper.sh" "$REPO/launchd/blocked-pane-watcher/blocked-pane-watcher.sh" \
         "$REPO/bin/herdmaster-board.sh" "$REPO/bin/herdmaster-layout.sh" "$REPO/bin/herdmaster-viewer.py" "$REPO/bin/herdmaster-labels.sh" \
         "$REPO/bin/herdmaster-agent.sh" "$REPO/bin/herdmaster-notify.sh"; do
  run install -m 755 "$f" "$HERDMASTER_HOME/bin/$(basename "$f")"
done
run install -m 644 "$REPO/adapters/claude.sh" "$HERDMASTER_HOME/adapters/claude.sh"

# 2. skills (never overwrite an existing skill unless --force)
for s in herdmaster orchestrator; do
  dest="$CLAUDE_DIR/skills/$s"
  if [[ -e $dest && $FORCE -eq 0 ]]; then
    say "skip skill $s: $dest exists (use --force to replace)"
    continue
  fi
  run mkdir -p "$dest"
  run install -m 644 "$REPO/skills/$s/SKILL.md" "$dest/SKILL.md"
done

# 3. model-routing subagents (never overwrite an existing agent unless --force)
run mkdir -p "$CLAUDE_DIR/agents"
for a in lookup worker deep; do
  dest="$CLAUDE_DIR/agents/$a.md"
  if [[ -e $dest && $FORCE -eq 0 ]]; then
    say "skip agent $a: $dest exists (use --force to replace)"
    continue
  fi
  run install -m 644 "$REPO/agents/$a.md" "$dest"
done

# 4. launchd jobs from templates
jobs=(cpu-reaper pressure-check viewer notify)
VIEWER_PORT=${HERDMASTER_VIEWER_PORT:-8766}
(( WATCHER )) && jobs+=(blocked-pane-watcher)
run mkdir -p "$LA_DIR"
for j in "${jobs[@]}"; do
  tmpl="$REPO/launchd/$j/com.herdmaster.$j.plist.tmpl"
  out="$LA_DIR/com.herdmaster.$j.plist"
  if (( DRY )); then
    say "[dry-run] render $tmpl -> $out"
  else
    sed -e "s|__HERDMASTER_HOME__|$HERDMASTER_HOME|g" -e "s|__HOME__|$HOME|g" -e "s|__VIEWER_PORT__|$VIEWER_PORT|g" "$tmpl" > "$out"
    plutil -lint "$out" >/dev/null
    launchctl bootout "gui/$(id -u)/com.herdmaster.$j" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$out"
  fi
done

# 5. merge the PreToolUse hook into settings.json (backup first, idempotent, never removes other hooks)
if [[ -f $SETTINGS ]] && ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "settings.json is not valid JSON; refusing to touch it" >&2; exit 1
fi
base='{}'; [[ -f $SETTINGS ]] && base=$(cat "$SETTINGS")
merged=$(jq --arg cmd "$GUARD" '
  .hooks //= {} | .hooks.PreToolUse //= []
  | if any(.hooks.PreToolUse[]?; any(.hooks[]?; .command == $cmd)) then .
    else .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$cmd}]}] end
' <<<"$base")
if [[ $merged == "$(jq . <<<"$base")" ]]; then
  say "settings.json: pressure-guard hook already present"
elif (( DRY )); then
  say "[dry-run] would merge into $SETTINGS:"
  diff <(jq . <<<"$base") <(jq . <<<"$merged") || true
else
  mkdir -p "$CLAUDE_DIR"
  [[ -f $SETTINGS ]] && cp "$SETTINGS" "$SETTINGS.herdmaster-backup-$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$merged" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  say "settings.json: hook merged"
fi
say "done"
