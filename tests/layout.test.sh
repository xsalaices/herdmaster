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
lacks() { grep -qF -- "$2" <<<"$1" && { echo "FAIL: unexpected '$2' in:" >&2; echo "$1" >&2; exit 1; }; return 0; }

export FAKE_TABS='[{"tab_id":"tab-1","workspace_id":"ws-1","label":"1","pane_count":2}]'
out=$("$L" --dry-run new-worker build echo hi 2>&1)
has "$out" "tab create --workspace ws-1 --label workers"
has "$out" "pane rename <new-pane> build"
has "$out" "HERDMASTER_ROLE=worker HERDMASTER_MASTER=planner-1 echo hi"
has "$out" "pane resize --pane pane-b --direction left --amount 0.2500"

export FAKE_TABS='[{"tab_id":"tab-1","workspace_id":"ws-1","label":"1","pane_count":2}]'
out=$("$L" --dry-run new-worker build --cwd "/tmp/my project" echo hi 2>&1)
has "$out" 'cd /tmp/my\ project && echo hi'
out=$("$L" --dry-run new-worker build --cwd /tmp/work --tier default '/orchestrator demo' 2>&1)
has "$out" 'cd /tmp/work && env -u ANTHROPIC_API_KEY claude'
has "$out" '/orchestrator\ demo'
out=$("$L" --dry-run new-worker build echo hi 2>&1)
lacks "$out" "cd /tmp"

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

out=$("$L" --dry-run new-orchestrator --cwd /tmp/work claude hi 2>&1)
has "$out" "cd /tmp/work && claude hi"

has "$("$L" --dry-run new-orchestrator claude hi 2>&1)" "settings set herdr_workspace ws-1"
[[ ! -f $T/.claude/orchestrator/demo/settings.json ]] || { echo "FAIL: dry-run wrote settings" >&2; exit 1; }
cp "$T/herdr" "$T/herdr-real"
cat > "$T/herdr" <<'FAKE2'
#!/usr/bin/env bash
case "$1 $2" in
  "pane split") echo '{"result":{"pane":{"pane_id":"pane-n"}}}' ;;
  "pane rename"|"pane run") ;;
  *) exec "$(dirname "$0")/herdr-real" "$@" ;;
esac
FAKE2
"$L" new-orchestrator claude hi >/dev/null 2>&1
[[ $(jq -r .herdr_workspace "$T/.claude/orchestrator/demo/settings.json") == ws-1 ]] || { echo "FAIL: workspace not recorded" >&2; exit 1; }
rm -f -- "$T/.claude/orchestrator/demo/settings.json"
mv "$T/herdr-real" "$T/herdr"

out=$("$L" --dry-run new-orchestrator claude "/orchestrator my proj" "it's a \"brief\"" 2>&1)
line=$(grep -F "pane run" <<<"$out")
eval "argv=(${line#*HERDMASTER_MASTER=planner-1 })"
[[ ${#argv[@]} -eq 3 && ${argv[1]} == "/orchestrator my proj" && ${argv[2]} == "it's a \"brief\"" ]] || { echo "FAIL: quoting: $line" >&2; exit 1; }

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
unset HERDMASTER_PROJECT

# adopt: fake herdr that answers pane get/layout by pane id (unlike the canned fixture above,
# which ignores its arguments) so each candidate pane can carry its own label.
cat > "$T/herdr-adopt" <<'FAKE3'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get")
    case "$3" in
      pane-m) echo '{"result":{"pane":{"pane_id":"pane-m","tab_id":"tab-1","label":"master"}}}' ;;
      pane-o) echo '{"result":{"pane":{"pane_id":"pane-o","tab_id":"tab-1","label":"orchestrator"}}}' ;;
      pane-c1) echo '{"result":{"pane":{"pane_id":"pane-c1","tab_id":"tab-1","label":"Fix the parser bug"}}}' ;;
      pane-c2) echo '{"result":{"pane":{"pane_id":"pane-c2","tab_id":"tab-1","label":""}}}' ;;
      pane-c3) echo '{"result":{"pane":{"pane_id":"pane-c3","tab_id":"tab-1","label":"pane-c3"}}}' ;;
      *) echo "UNKNOWN GET: $3" >&2; exit 98 ;;
    esac ;;
  "pane layout")
    if [[ $4 == "pane-m" ]]; then
      echo '{"result":{"layout":{"area":{"width":200,"height":60},"panes":[
        {"pane_id":"pane-m","rect":{"x":0,"y":0,"width":50,"height":60}},
        {"pane_id":"pane-o","rect":{"x":51,"y":0,"width":50,"height":60}},
        {"pane_id":"pane-c1","rect":{"x":102,"y":0,"width":49,"height":30}},
        {"pane_id":"pane-c2","rect":{"x":102,"y":31,"width":49,"height":29}},
        {"pane_id":"pane-c3","rect":{"x":152,"y":0,"width":48,"height":60}}],
        "splits":[]}}}'
    elif [[ $4 == "pane-a" ]]; then
      echo '{"result":{"layout":{"area":{"width":200,"height":60},"panes":[
        {"pane_id":"pane-a","rect":{"x":0,"y":0,"width":150,"height":60}},
        {"pane_id":"pane-b","rect":{"x":151,"y":0,"width":49,"height":60}}],
        "splits":[{"direction":"right","ratio":0.75,"rect":{"x":0,"y":0,"width":200,"height":60}}]}}}'
    else
      echo "UNKNOWN LAYOUT: $*" >&2; exit 97
    fi ;;
  "tab list") echo "{\"result\":{\"tabs\":$FAKE_TABS}}" ;;
  "pane list") jq -nc --argjson n "${FAKE_MAIN_PANES:-2}" '{result:{panes:([range($n)|{pane_id:"pane-\(.)",tab_id:"tab-1"}]+[{pane_id:"pane-a",tab_id:"tab-2"}])}}' ;;
  *) echo "MUTATION: $*" >&2; exit 99 ;;
esac
FAKE3
chmod +x "$T/herdr-adopt"

# Same fixture (workers tab, pane_count 3, room to spare) that earlier made new-worker choose
# "pane-a --direction right" -- adopt must land its candidates on the exact same slot.
export FAKE_TABS='[{"tab_id":"tab-2","workspace_id":"ws-1","label":"workers","pane_count":3}]'
out=$(HERDMASTER_HERDR="$T/herdr-adopt" "$L" --dry-run adopt --workspace ws-1 --master pane-m --orchestrator pane-o 2>&1)
has "$out" "pane move pane-c1 --tab tab-2 --split right --target-pane pane-a --no-focus"
has "$out" "pane move pane-c2 --tab tab-2 --split right --target-pane pane-a --no-focus"
has "$out" "pane move pane-c3 --tab tab-2 --split right --target-pane pane-a --no-focus"
[[ $(grep -c "pane move" <<<"$out") -eq 3 ]] || { echo "FAIL: expected exactly 3 moves: $out" >&2; exit 1; }
has "$out" "pane-c1 -> <new-pane> (Fix the parser bug)"        # task-title label kept, no rename
has "$out" "pane rename <new-pane> adopted pane-c2"            # empty label -> adopted <id>
has "$out" "pane rename <new-pane> adopted pane-c3"            # label == own pane id -> adopted <id>
[[ $(grep -c "pane rename" <<<"$out") -eq 2 ]] || { echo "FAIL: expected exactly 2 renames: $out" >&2; exit 1; }
has "$out" "adopted 3 pane(s)"
for id in pane-m pane-o; do
  lacks "$out" "pane move $id "
  lacks "$out" "pane rename $id "
  lacks "$out" "pane close $id"
done

# No existing workers tab and an explicit --workspace other than any pane's own: falls back to
# the same "new workers tab" decision new-worker makes when none exists, via pane move --new-tab.
export FAKE_TABS='[]'
out=$(HERDMASTER_HERDR="$T/herdr-adopt" "$L" --dry-run adopt --workspace ws-9 --master pane-m --orchestrator pane-o 2>&1)
has "$out" "pane move pane-c1 --new-tab --workspace ws-9 --no-focus"
has "$out" "tab rename <new-tab> workers"

# Missing --master/--orchestrator must fail before any herdr call (fake exits 99 on unhandled
# commands, so a non-2 exit would mean the check ran late).
set +e
out=$(HERDMASTER_HERDR="$T/herdr-adopt" "$L" --dry-run adopt --orchestrator pane-o 2>&1); rc=$?
set -e
[[ $rc -eq 2 ]] || { echo "FAIL: missing --master should exit 2, got $rc: $out" >&2; exit 1; }
has "$out" "--master is required"

set +e
out=$(HERDMASTER_HERDR="$T/herdr-adopt" "$L" --dry-run adopt --master pane-m 2>&1); rc=$?
set -e
[[ $rc -eq 2 ]] || { echo "FAIL: missing --orchestrator should exit 2, got $rc: $out" >&2; exit 1; }
has "$out" "--orchestrator is required"

echo ok
