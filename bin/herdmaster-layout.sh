#!/usr/bin/env bash
# Places worker panes and keeps the grid even.
# Usage: herdmaster-layout.sh [--dry-run] new-worker <label> [--cwd <dir>] <launch>   prints the new pane id
#        herdmaster-layout.sh [--dry-run] new-orchestrator [--classic] [--cwd <dir>] <launch>
#                                                                      default: puts herdmaster-sidebar.sh in tab 1's right half and
#                                                                      places the orchestrator in the workers tab (same grid logic as
#                                                                      new-worker), labeled orchestrator. --classic restores the old
#                                                                      behavior: orchestrator in tab 1's right half, no sidebar pane.
#                                                                      Records the herdr workspace in settings, prints the orchestrator pane id.
#        herdmaster-layout.sh [--dry-run] rebalance [pane]             equal widths for the tab of pane (default: current)
#        herdmaster-layout.sh [--dry-run] adopt [--workspace <id>] --master <pane-id> --orchestrator <pane-id>
#                                                                      moves every other pane on that workspace's tab 1 into the worker layout
# <launch> is either <command...>, or --tier <light|default|deep> [--resume <id>] [prompt] to build it with herdmaster-agent.sh.
# --cwd <dir> makes the pane cd into <dir> before running <launch> (works with either launch form); without it, behavior is unchanged.
# Per-project settings.json (worker_layout, grid_panes, max_panes) overrides the env vars below.
# Env: HERDMASTER_WORKER_LAYOUT (tab|main, default tab), HERDMASTER_GRID_PANES (default 6),
#      HERDMASTER_MAX_PANES (default 4, workers on the main tab when layout is main), HERDMASTER_PROJECT.
# --dry-run prints the mutating herdr commands instead of running them; read-only queries still run.
set -euo pipefail

die() { echo "herdmaster-layout: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"

HERDR=${HERDMASTER_HERDR:-herdr}
DRY=0
[[ ${1:-} == --dry-run ]] && { DRY=1; shift; }

LAYOUT=${HERDMASTER_WORKER_LAYOUT:-tab}
GRID=${HERDMASTER_GRID_PANES:-6}
MAXP=${HERDMASTER_MAX_PANES:-4}
SETTINGS="$HOME/.claude/orchestrator/${HERDMASTER_PROJECT:-}/settings.json"
if [[ -n ${HERDMASTER_PROJECT:-} && -f $SETTINGS ]]; then
  LAYOUT=$(jq -r --arg d "$LAYOUT" '.worker_layout // $d' "$SETTINGS")
  GRID=$(jq -r --arg d "$GRID" '.grid_panes // $d' "$SETTINGS")
  MAXP=$(jq -r --arg d "$MAXP" '.max_panes // $d' "$SETTINGS")
fi
FIXED_PANES=2 # planner and orchestrator share the main tab; everything else there is a worker
[[ $LAYOUT == tab || $LAYOUT == main ]] || die "HERDMASTER_WORKER_LAYOUT must be tab or main"
[[ $GRID =~ ^[1-9][0-9]*$ && $MAXP =~ ^[1-9][0-9]*$ ]] || die "pane limits must be positive integers"

mut() {
  if (( DRY )); then echo "[dry-run] $HERDR $*"; else "$HERDR" "$@"; fi
}

# Mutating call whose JSON reply carries an id; dry-run yields a placeholder.
mut_json() {
  local jq_expr=$1 placeholder=$2; shift 2
  if (( DRY )); then echo "[dry-run] $HERDR $*" >&2; echo "$placeholder"; else "$HERDR" "$@" | jq -r "$jq_expr"; fi
}

current_pane_json() { "$HERDR" pane current | jq -c .result.pane; }

master_name() {
  local f="$HOME/.claude/orchestrator/${HERDMASTER_PROJECT:-}/master"
  [[ -n ${HERDMASTER_PROJECT:-} && -f $f ]] && tr -d '\n' < "$f" || true
}

tab_panes() { "$HERDR" pane list --workspace "$2" | jq -r --arg t "$1" '.result.panes[] | select(.tab_id == $t) | .pane_id'; }

# Split target: the largest pane in the tab, cut across its longer side (cells are about twice as tall as wide).
split_target() {
  local tab=$1 ws=$2 first
  first=$(tab_panes "$tab" "$ws" | head -n1)
  "$HERDR" pane layout --pane "$first" | jq -r '
    .result.layout.panes | max_by(.rect.width * .rect.height)
    | "\(.pane_id) \(if .rect.width >= 2 * .rect.height then "right" else "down" end)"'
}

# The pane's command, one printf '%q' word per argument so briefs with spaces or quotes survive the pane shell.
launch_cmd() {
  local role=$1; shift
  if [[ $1 == --tier ]]; then "$(dirname "$0")/herdmaster-agent.sh" command "$role" "${@:2}"; else printf '%q ' "$@"; fi
}

# Decides where the next worker pane belongs: a split within an existing tab, or a new
# "workers" tab. Shared by new-worker (which creates the pane) and adopt (which moves one in).
# main_tab is the tab holding the master/orchestrator, consulted only when LAYOUT=main.
# Echoes "split\t<target-pane>\t<direction>\t<tab-id>" or "newtab\t<label>" (tab-separated:
# a "workers N" label must survive intact through the caller's read).
worker_slot() {
  local ws=$1 main_tab=$2
  if [[ $LAYOUT == main ]] && (( $(tab_panes "$main_tab" "$ws" | wc -l) - FIXED_PANES < MAXP )); then
    read -r target dir < <(split_target "$main_tab" "$ws")
    printf 'split\t%s\t%s\t%s\n' "$target" "$dir" "$main_tab"
    return
  fi
  local wtab
  wtab=$("$HERDR" tab list | jq -r --arg ws "$ws" --argjson g "$GRID" '
    [.result.tabs[] | select(.workspace_id == $ws and (.label | test("^workers( [0-9]+)?$")) and .pane_count < $g)]
    | (last // empty) | .tab_id')
  if [[ -n $wtab ]]; then
    read -r target dir < <(split_target "$wtab" "$ws")
    printf 'split\t%s\t%s\t%s\n' "$target" "$dir" "$wtab"
  else
    local n tlabel=workers
    n=$("$HERDR" tab list | jq --arg ws "$ws" '[.result.tabs[] | select(.workspace_id == $ws and (.label | test("^workers( [0-9]+)?$")))] | length')
    (( n > 0 )) && tlabel="workers $((n + 1))"
    printf 'newtab\t%s\n' "$tlabel"
  fi
}

# Places <cmd> under <label> using the grid: a split within an existing tab/workers tab, or a
# new "workers" tab, exactly per worker_slot. Shared by new-worker and the default new-orchestrator.
place_worker_pane() {
  local label=$1 cmd=$2
  local cur ws tab pane slot kind a b c
  cur=$(current_pane_json); ws=$(jq -r .workspace_id <<<"$cur"); tab=$(jq -r .tab_id <<<"$cur")

  slot=$(worker_slot "$ws" "$tab")
  IFS=$'\t' read -r kind a b c <<<"$slot"
  case $kind in
    split) pane=$(mut_json .result.pane.pane_id "<new-pane>" pane split "$a" --direction "$b" --no-focus) ;;
    newtab) pane=$(mut_json .result.root_pane.pane_id "<new-pane>" tab create --workspace "$ws" --label "$a" --no-focus) ;;
  esac

  mut pane rename "$pane" "$label" >&2
  mut pane run "$pane" "$cmd" >&2
  if (( DRY )); then cmd_rebalance >&2; else cmd_rebalance "$pane" >&2; fi
  echo "$pane"
}

cmd_new_worker() {
  local label=${1:-}; shift || true
  [[ -n $label && $# -gt 0 ]] || die "new-worker: <label> <launch> required"
  local cwd=""
  [[ ${1:-} == --cwd ]] && { cwd=${2:-}; [[ -n $cwd ]] || die "new-worker: --cwd requires a directory"; shift 2; }
  [[ $# -gt 0 ]] || die "new-worker: <launch> required"
  local cmd; cmd=$(launch_cmd worker "$@")
  local master; master=$(master_name)
  cmd="HERDMASTER_ROLE=worker HERDMASTER_MASTER=$(printf '%q' "$master") $cmd"
  [[ -n $cwd ]] && cmd="cd $(printf '%q' "$cwd") && $cmd"
  place_worker_pane "$label" "$cmd"
}

# Plain (no-agent) pane running herdmaster-sidebar.sh, split into tab 1's right half -- the slot the
# orchestrator itself used to take. Its command carries no HERDMASTER_ROLE/HERDMASTER_MASTER, unlike
# every agent launch, so it reads as a plain script run rather than a fleet pane.
place_sidebar_pane() {
  local pane cmd
  cmd="HERDMASTER_PROJECT=$(printf '%q' "${HERDMASTER_PROJECT:-}") $(dirname "$0")/herdmaster-sidebar.sh"
  pane=$(mut_json .result.pane.pane_id "<new-pane>" pane split --current --direction right --no-focus)
  mut pane rename "$pane" sidebar >&2
  mut pane run "$pane" "$cmd" >&2
}

cmd_new_orchestrator() {
  local classic=0 cwd=""
  while [[ ${1:-} == --classic || ${1:-} == --cwd ]]; do
    case $1 in
      --classic) classic=1; shift ;;
      --cwd) cwd=${2:-}; [[ -n $cwd ]] || die "new-orchestrator: --cwd requires a directory"; shift 2 ;;
    esac
  done
  [[ $# -gt 0 ]] || die "new-orchestrator: <launch> required"
  local pane master cmd; master=$(master_name)
  cmd=$(launch_cmd orchestrator "$@")
  cmd="HERDMASTER_ROLE=orchestrator HERDMASTER_MASTER=$(printf '%q' "$master") $cmd"
  [[ -n $cwd ]] && cmd="cd $(printf '%q' "$cwd") && $cmd"
  if (( classic )); then
    pane=$(mut_json .result.pane.pane_id "<new-pane>" pane split --current --direction right --no-focus)
    mut pane rename "$pane" orchestrator >&2
    mut pane run "$pane" "$cmd" >&2
  else
    place_sidebar_pane
    pane=$(place_worker_pane orchestrator "$cmd")
  fi
  record_workspace >&2
  echo "$pane"
}

# A label a worker pane was never deliberately given: empty, the pane's own id, or the
# generic default a fresh agent pane starts with.
is_default_label() {
  local label=$1 pane_id=$2
  [[ -z $label || $label == "$pane_id" || $label == "Claude Code" ]]
}

# Moves a pane into a brand-new "workers" tab and labels the tab to match (pane move --new-tab
# has no --tab-label; the tab starts unlabeled, so we rename it after, mirroring tab create).
newtab_move() {
  local old=$1 ws=$2 tlabel=$3
  if (( DRY )); then
    echo "[dry-run] $HERDR pane move $old --new-tab --workspace $ws --no-focus" >&2
    echo "[dry-run] $HERDR tab rename <new-tab> $tlabel" >&2
    echo "<new-pane>"
    return
  fi
  local resp newpane newtab
  resp=$("$HERDR" pane move "$old" --new-tab --workspace "$ws" --no-focus)
  newpane=$(jq -r .result.move_result.pane.pane_id <<<"$resp")
  newtab=$(jq -r .result.move_result.pane.tab_id <<<"$resp")
  "$HERDR" tab rename "$newtab" "$tlabel" >&2
  echo "$newpane"
}

# Re-homes every pre-existing pane on --master's tab (other than --master and --orchestrator)
# into the standard worker layout, using the same placement logic as new-worker.
cmd_adopt() {
  local ws="" master="" orchestrator=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --workspace) ws=${2:-}; shift 2 ;;
      --master) master=${2:-}; shift 2 ;;
      --orchestrator) orchestrator=${2:-}; shift 2 ;;
      *) die "adopt: unknown argument $1" ;;
    esac
  done
  [[ -n $master ]] || die "adopt: --master is required"
  [[ -n $orchestrator ]] || die "adopt: --orchestrator is required"
  [[ -n $ws ]] || ws=$(current_pane_json | jq -r .workspace_id)

  local main_tab panes
  main_tab=$("$HERDR" pane get "$master" | jq -r .result.pane.tab_id)
  panes=$("$HERDR" pane layout --pane "$master" | jq -r '.result.layout.panes[].pane_id')

  local moved=0 pane
  while IFS= read -r pane; do
    [[ -n $pane && $pane != "$master" && $pane != "$orchestrator" ]] || continue
    local label newlabel slot kind a b c newpane
    label=$("$HERDR" pane get "$pane" | jq -r '.result.pane.label // ""')
    newlabel=$label
    is_default_label "$label" "$pane" && newlabel="adopted $pane"

    slot=$(worker_slot "$ws" "$main_tab")
    IFS=$'\t' read -r kind a b c <<<"$slot"
    case $kind in
      split) newpane=$(mut_json .result.move_result.pane.pane_id "<new-pane>" pane move "$pane" --tab "$c" --split "$b" --target-pane "$a" --no-focus) ;;
      newtab) newpane=$(newtab_move "$pane" "$ws" "$a") ;;
    esac

    [[ $newlabel == "$label" ]] || mut pane rename "$newpane" "$newlabel" >&2
    echo "$pane -> $newpane ($newlabel)"
    moved=$((moved + 1))
  done <<<"$panes"

  echo "adopted $moved pane(s)"
}

# Lets the viewer follow the focused herdr workspace (see docs/design/board.md).
record_workspace() {
  [[ -n ${HERDMASTER_PROJECT:-} ]] || return 0
  local ws board; ws=$(current_pane_json | jq -r '.workspace_id // empty'); [[ -n $ws ]] || return 0
  board="$(dirname "$0")/herdmaster-board.sh"
  if (( DRY )); then echo "[dry-run] $board settings set herdr_workspace $ws"; else "$board" settings set herdr_workspace "$ws"; fi
}

# Columns are the distinct x origins of the tab's panes. Each column boundary is a "right" split; --amount is a
# delta on that split's ratio (resize grows the named pane toward --direction, so shrinking uses the pane on the far side), so one resize lands it on target (sweeps repeat because moving a parent split rescales its children).
# Ceiling: only right-direction splits are balanced, rows in a column are left as split.
cmd_rebalance() {
  local anchor=${1:-} layout ncols i sweep moved
  layout_of() { if [[ -n $anchor ]]; then "$HERDR" pane layout --pane "$anchor"; else "$HERDR" pane layout --current; fi | jq -c .result.layout; }
  layout=$(layout_of)
  ncols=$(jq '[.panes[].rect.x] | unique | length' <<<"$layout")
  (( ncols > 1 )) || return 0
  for ((sweep = 0; sweep < 8; sweep++)); do
    moved=0
    for ((i = 0; i < ncols - 1; i++)); do
      local info amount pane
      info=$(jq -r --argjson i "$i" '
        .area.width as $w | ([.panes[].rect.x] | unique) as $xs
        | (($w * ($i + 1) / ($xs | length)) | round) as $want
        | $xs[$i + 1] as $edge
        | ([.splits[] | select(.direction == "right")]
           | min_by((.rect.x + .ratio * .rect.width - $edge) | fabs)) as $s
        | ((($want - $s.rect.x) / $s.rect.width) - $s.ratio) as $d
        | (if $d > 0
           then ([.panes[] | select(.rect.y == $s.rect.y and .rect.x >= $s.rect.x and .rect.x + .rect.width <= $edge)]
                 | max_by(.rect.x + .rect.width) | .pane_id)
           else ([.panes[] | select(.rect.y == $s.rect.y and .rect.x == $edge)] | first | .pane_id) end) as $p
        | "\($d) \($p) \(($want - $edge) | fabs)"' <<<"$layout")
      local d gap
      read -r d pane gap <<<"$info"
      (( $(awk -v g="$gap" 'BEGIN { print (g <= 1) }') )) && continue
      amount=$(awk -v d="$d" 'BEGIN { printf "%.4f", (d < 0 ? -d : d) }')
      if (( DRY )); then
        echo "[dry-run] $HERDR pane resize --pane $pane --direction $(awk -v d="$d" 'BEGIN { print (d < 0 ? "left" : "right") }') --amount $amount"; return 0
      fi
      "$HERDR" pane resize --pane "$pane" --direction "$(awk -v d="$d" 'BEGIN { print (d < 0 ? "left" : "right") }')" --amount "$amount" >/dev/null
      moved=1
      layout=$(layout_of)
    done
    (( moved )) || break
  done
}

sub=${1:-}; shift || true
case $sub in
  new-worker) cmd_new_worker "$@" ;;
  new-orchestrator) cmd_new_orchestrator "$@" ;;
  adopt) cmd_adopt "$@" ;;
  rebalance) cmd_rebalance "$@" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
