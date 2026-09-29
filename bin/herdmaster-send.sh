#!/usr/bin/env bash
# SendMessage for agents that lack one (Codex etc.): types a labeled message into another herdr pane.
# Usage: herdmaster-send.sh <target pane-id or agent name> <message...>     ("-" as message reads stdin)
# The message is prefixed "[herdmaster msg from <agent> <pane>]" so the receiver can tell it is not the owner.
# With HERDMASTER_PROJECT set, a copy is appended to ~/.claude/orchestrator/<project>/messages.jsonl (durable, since
# herdr prompts can be dropped). Never waits: herdr's --wait is unreliable for some agents (see docs/design/providers.md).
set -euo pipefail

die() { echo "herdmaster-send: $*" >&2; exit 2; }
HERDR=${HERDR_BIN:-herdr}
command -v "$HERDR" >/dev/null || die "herdr is required"
command -v jq >/dev/null || die "jq is required"

[[ $# -ge 2 ]] || die "usage: herdmaster-send.sh <target> <message...>"
TARGET=$1; shift
if [[ $* == "-" ]]; then MSG=$(cat); else MSG=$*; fi
[[ -n ${MSG//[[:space:]]/} ]] || die "empty message"
(( ${#MSG} <= 4000 )) || die "message over 4000 chars; write it to a file and send the path"

# Own identity: agent kind and pane id from herdr, else just the pane id from the environment.
KIND=agent PANE=${HERDR_PANE_ID:-unknown}
if cur=$("$HERDR" pane current 2>/dev/null); then
  KIND=$(jq -r '.agent // .result.pane.agent // "agent"' <<<"$cur")
  PANE=$(jq -r '.pane_id // .result.pane.pane_id // empty' <<<"$cur")
  PANE=${PANE:-${HERDR_PANE_ID:-unknown}}
fi
LABEL="[herdmaster msg from $KIND $PANE]"

if [[ -n ${HERDMASTER_PROJECT:-} ]]; then
  DIR="$HOME/.claude/orchestrator/$HERDMASTER_PROJECT"
  mkdir -p -- "$DIR"
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg from "$KIND $PANE" --arg to "$TARGET" --arg msg "$MSG" \
    '{ts:$ts, from:$from, to:$to, message:$msg}' >> "$DIR/messages.jsonl"
fi

"$HERDR" agent prompt "$TARGET" "$LABEL $MSG" >/dev/null
echo "sent to $TARGET"
