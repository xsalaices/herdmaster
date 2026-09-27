#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT

"$R/scripts/build-skills.sh" --out "$T"
for f in skills/herdmaster/SKILL.md skills/orchestrator/SKILL.md examples/worker-brief-template.md; do
  cmp "$R/$f" "$T/$f" || { echo "FAIL: $f differs from roles/; run scripts/build-skills.sh" >&2; exit 1; }
done

mkdir -p "$T/repo/scripts" "$T/repo/roles"
cp "$R/scripts/build-skills.sh" "$T/repo/scripts/"
cp "$R"/roles/transport-claude.md "$R"/roles/orchestrator.md "$R"/roles/worker.md "$T/repo/roles/"
printf '# Master\n\nUse {{no_such_key}}.\n' > "$T/repo/roles/planner.md"
if "$T/repo/scripts/build-skills.sh" --out "$T/out" 2>"$T/err"; then echo "FAIL: unknown placeholder accepted" >&2; exit 1; fi
grep -qF "unknown placeholder {{no_such_key}}" "$T/err" || { echo "FAIL: no error for unknown placeholder" >&2; exit 1; }
echo ok
