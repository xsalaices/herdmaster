#!/usr/bin/env bash
set -euo pipefail
L="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-layout.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T" HERDMASTER_PROJECT=demo
mkdir -p "$T/.claude/orchestrator/demo"
printf 'planner-1\n' > "$T/.claude/orchestrator/demo/master"

# Fake herdr: canned read-only answers; any mutating subcommand fails the test.
cat > "$T/herdr" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") echo '{"result":{"pane":{"pane_id":"pane-a","tab_id":"tab-1","workspace_id":"ws-1"}}}' ;;
  "pane list") jq -nc --argjson n "${FAKE_MAIN_PANES:-2}" '{result:{panes:([range($n)|{pane_id:"pane-\(.)",tab_id:"tab-1"}]+[{pane_id:"pane-x",tab_id:"tab-2"}])}}' ;;
  "tab list") echo "{\"result\":{\"tabs\":$FAKE_TABS}}" ;;
  "pane layout") echo '{"result":{"layout":{"area":{"width":200,"height":60},"panes":[
    {"pane_id":"pane-a","rect":{"x":0,"y":0,"width":150,"height":60}},
    {"pane_id":"pane-b","rect":{"x":151,"y":0,"width":49,"height":60}}],
    "splits":[{"direction":"right","ratio":0.75,"rect":{"x":0,"y":0,"width":200,"height":60}}]}}}' ;;
  *) echo "MUTATION: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$T/herdr"
export HERDMASTER_HERDR="$T/herdr"
has() { grep -qF -- "$2" <<<"$1" || { echo "FAIL: missing '$2' in:" >&2; echo "$1" >&2; exit 1; }; }

export FAKE_TABS='[{"tab_id":"tab-1","workspace_id":"ws-1","label":"1","pane_count":2}]'
out=$("$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "tab create --workspace ws-1 --label workers"
has "$out" "pane rename <new-pane> build"
has "$out" "HERDMASTER_ROLE=worker HERDMASTER_MASTER=planner-1 echo hi"
has "$out" "pane resize --pane pane-b --direction left --amount 0.2500"

export FAKE_TABS='[{"tab_id":"tab-2","workspace_id":"ws-1","label":"workers","pane_count":3}]'
out=$("$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "pane split pane-a --direction right --no-focus"

export FAKE_TABS='[{"tab_id":"tab-2","workspace_id":"ws-1","label":"workers","pane_count":6}]'
out=$("$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "--label workers 2"

export FAKE_TABS='[{"tab_id":"tab-1","workspace_id":"ws-1","label":"1","pane_count":2}]'
out=$(HERDMASTER_WORKER_LAYOUT=main "$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "pane split"
out=$(HERDMASTER_WORKER_LAYOUT=main HERDMASTER_MAX_PANES=2 FAKE_MAIN_PANES=3 "$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "pane split"
out=$(HERDMASTER_WORKER_LAYOUT=main HERDMASTER_MAX_PANES=2 FAKE_MAIN_PANES=4 "$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "tab create"

out=$("$L" --dry-run new-orchestrator claude hi 2>&1)
has "$out" "pane split --current --direction right --no-focus"
has "$out" "pane rename <new-pane> orchestrator"
has "$out" "HERDMASTER_ROLE=orchestrator HERDMASTER_MASTER=planner-1 claude hi"

out=$("$L" --dry-run rebalance 2>&1)
has "$out" "pane resize --pane pane-b --direction left"

so="$T/.claude/orchestrator/demo/settings.json"
printf '{"grid_panes":2}\n' > "$so"
export FAKE_TABS='[{"tab_id":"tab-2","workspace_id":"ws-1","label":"workers","pane_count":2}]'
out=$(HERDMASTER_GRID_PANES=6 "$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "--label workers 2"
printf '{"worker_layout":"main"}\n' > "$so"
out=$("$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "pane split"
rm -f -- "$so"
echo ok
