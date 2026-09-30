#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"
F="$R/bin/herdmaster-finish.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T" HERDMASTER_PROJECT=demo HERDR_PANE_ID=w1:p7
fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub herdr: `pane current` is a codex pane, `agent prompt` and `pane close` record their args.
cat > "$T/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane current") echo '{"agent":"codex","pane_id":"w1:p7"}' ;;
  "agent prompt") printf '%s\n%s\n' "\$3" "\$4" > "$T/sent" ;;
  "pane close") echo "\$3" > "$T/closed" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/herdr"
export HERDR_BIN="$T/herdr"
mkdir -p "$T/.claude/orchestrator/demo"
echo "demo-orchestrator" > "$T/.claude/orchestrator/demo/orchestrator"
export HERDMASTER_MEMORY_DIR="$T/mem"

# Report goes to the named orchestrator, marked FULLY DONE, then the own pane is closed.
"$F" --summary "added doctor, tests pass" >/dev/null
[[ $(sed -n 1p "$T/sent") == demo-orchestrator ]] || fail "wrong recipient"
[[ $(sed -n 2p "$T/sent") == *"FULLY DONE: added doctor, tests pass" ]] || fail "wrong body: $(sed -n 2p "$T/sent")"
[[ $(cat "$T/closed") == w1:p7 ]] || fail "own pane not closed"
[[ ! -e $T/mem ]] || fail "wrote memory without --memory"

# --to overrides the file; --no-exit keeps the pane; memory file + index line are written.
rm -f "$T/closed"
"$F" --summary s --to other --no-exit --memory "Codex hooks need /hooks trust once per machine." --memory-name codex-hook-trust >/dev/null
[[ $(sed -n 1p "$T/sent") == other ]] || fail "--to ignored"
[[ ! -e $T/closed ]] || fail "--no-exit closed the pane"
grep -q '^name: codex-hook-trust$' "$T/mem/codex-hook-trust.md" || fail "memory frontmatter"
grep -q 'type: project' "$T/mem/codex-hook-trust.md" || fail "memory type"
grep -q 'codex-hook-trust.md' "$T/mem/MEMORY.md" || fail "memory index"

# Refusals: existing memory name, bad slug, missing summary, failed report must not close the pane.
"$F" --summary s --no-exit --memory x --memory-name codex-hook-trust 2>/dev/null && fail "overwrote existing memory"
"$F" --summary s --no-exit --memory x --memory-name "Bad Name" 2>/dev/null && fail "bad slug accepted"
"$F" --to other 2>/dev/null && fail "missing summary accepted"
cat > "$T/herdr" <<STUB
#!/usr/bin/env bash
[[ \$1 == pane && \$2 == close ]] && { echo closed > "$T/closed2"; exit 0; }
exit 1
STUB
"$F" --summary s 2>/dev/null && fail "failed report still succeeded"
[[ ! -e $T/closed2 ]] || fail "pane closed after a failed report"
echo ok
