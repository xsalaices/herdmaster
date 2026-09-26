#!/usr/bin/env bash
set -euo pipefail
B="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-board.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T" HERDMASTER_PROJECT=demo
D="$T/.claude/orchestrator/demo"
f="$D/tasks.json"
mkdir -p "$D"
eq() { [[ $1 == "$2" ]] || { echo "FAIL: got '$1' want '$2'" >&2; exit 1; }; }

cat > "$D/design-queue.md" <<'Q'
# Design queue

## Pick a colour scheme (2026-01-02 10:15, blocking: yes)
Question: Which palette should the app use?
Options: A) Warm tones B) Cool tones (recommended, because it reads better at night)
Context: Marketing wants a fresh look.

## Name the export button (2026-01-02 11:00, blocking: no)
Question: What should the button say?
Options: A) Export (recommended, because it is shortest) B) Download
Context: Only affects copy.
Q
cat > "$D/decisions.md" <<'Q'
# Decisions
- 2026-01-01 09:30 (master): Use weekly releases. Owner prefers a steady rhythm.
- 2026-01-01 Skip dark mode: too costly for now.
Q
cp "$D/design-queue.md" "$T/dq.bak"; cp "$D/decisions.md" "$T/dc.bak"

"$B" add task "Existing task" >/dev/null
"$B" add decision "Name the export button" >/dev/null
out=$("$B" import-legacy)
eq "$out" "imported open 1, imported settled 2, skipped 1"
eq "$(jq -r '.schema_version' "$f")" 1
eq "$(jq -r '.entries[] | select(.title == "Pick a colour scheme") | .id + "|" + .status + "|" + (.blocking | tostring) + "|" + .recommend' "$f")" "D-002|open|true|Cool tones"
eq "$(jq -r '.entries[] | select(.title == "Pick a colour scheme") | .note' "$f")" "Which palette should the app use? Marketing wants a fresh look."
eq "$(jq -r '.entries[] | select(.title == "Use weekly releases") | .id + "|" + .status' "$f")" "D-003|settled"
eq "$(jq -r '.entries[] | select(.title == "Skip dark mode") | .status' "$f")" settled
eq "$(jq -r '.entries[0].id' "$f")" T-001
[[ -f $D/.legacy-imported ]] || { echo "FAIL: no marker" >&2; exit 1; }
cmp -s "$D/design-queue.md" "$T/dq.bak" && cmp -s "$D/decisions.md" "$T/dc.bak" || { echo "FAIL: legacy files changed" >&2; exit 1; }

before=$(cat "$f")
eq "$("$B" import-legacy)" "already imported"
eq "$(cat "$f")" "$before"

rm -f -- "$D/.legacy-imported"
eq "$("$B" import-legacy)" "imported open 0, imported settled 0, skipped 4"
eq "$(jq '.entries | length' "$f")" 5
echo ok
