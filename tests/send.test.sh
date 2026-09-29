#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"
S="$R/bin/herdmaster-send.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub herdr: `pane current` reports a codex pane; `agent prompt` records its args.
cat > "$T/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane current") echo '{"agent":"codex","pane_id":"w9:p3"}' ;;
  "agent prompt") printf '%s\n%s\n' "\$3" "\$4" > "$T/got" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/herdr"
export HERDR_BIN="$T/herdr"
unset HERDMASTER_PROJECT

"$S" w19:p1 "hello there" >/dev/null
[[ $(sed -n 1p "$T/got") == w19:p1 ]] || fail "wrong target"
[[ $(sed -n 2p "$T/got") == "[herdmaster msg from codex w9:p3] hello there" ]] || fail "wrong body: $(sed -n 2p "$T/got")"
[[ ! -e $T/.claude ]] || fail "wrote a message log without HERDMASTER_PROJECT"

echo "from stdin" | "$S" w19:p1 - >/dev/null
[[ $(sed -n 2p "$T/got") == *"from stdin" ]] || fail "stdin body"

HERDMASTER_PROJECT=demo "$S" w19:p1 'quote "q" and $x' >/dev/null
[[ $(jq -r .message "$T/.claude/orchestrator/demo/messages.jsonl") == 'quote "q" and $x' ]] || fail "log message"
[[ $(jq -r .from "$T/.claude/orchestrator/demo/messages.jsonl") == "codex w9:p3" ]] || fail "log from"

"$S" w19:p1 "   " 2>/dev/null && fail "empty message accepted"
"$S" w19:p1 2>/dev/null && fail "missing message accepted"
"$S" w19:p1 "$(head -c 4001 /dev/zero | tr '\0' a)" 2>/dev/null && fail "oversize accepted"
echo ok
