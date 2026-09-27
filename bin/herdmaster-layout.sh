#!/usr/bin/env bash
# Places worker panes and keeps the grid even.
# Usage: herdmaster-layout.sh [--dry-run] new-worker <label> <command...>   prints the new pane id
#        herdmaster-layout.sh [--dry-run] new-orchestrator <command...>    splits the current pane right, labels it orchestrator, prints the new pane id
#        herdmaster-layout.sh [--dry-run] rebalance [pane]                 equal widths for the tab of pane (default: current)
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

cmd_new_worker() {
  local label=${1:-}; shift || true
  [[ -n $label && $# -gt 0 ]] || die "new-worker: <label> <command...> required"
  local cur ws tab pane="" dir
  cur=$(current_pane_json); ws=$(jq -r .workspace_id <<<"$cur"); tab=$(jq -r .tab_id <<<"$cur")

  if [[ $LAYOUT == main ]] && (( $(tab_panes "$tab" "$ws" | wc -l) - FIXED_PANES < MAXP )); then
    read -r target dir < <(split_target "$tab" "$ws")
    pane=$(mut_json .result.pane.pane_id "<new-pane>" pane split "$target" --direction "$dir" --no-focus)
  else
    local wtab
    wtab=$("$HERDR" tab list | jq -r --arg ws "$ws" --argjson g "$GRID" '
      [.result.tabs[] | select(.workspace_id == $ws and (.label | test("^workers( [0-9]+)?$")) and .pane_count < $g)]
      | (last // empty) | .tab_id')
    if [[ -n $wtab ]]; then
      read -r target dir < <(split_target "$wtab" "$ws")
      pane=$(mut_json .result.pane.pane_id "<new-pane>" pane split "$target" --direction "$dir" --no-focus)
    else
      local n tlabel=workers
      n=$("$HERDR" tab list | jq --arg ws "$ws" '[.result.tabs[] | select(.workspace_id == $ws and (.label | test("^workers( [0-9]+)?$")))] | length')
      (( n > 0 )) && tlabel="workers $((n + 1))"
      pane=$(mut_json .result.root_pane.pane_id "<new-pane>" tab create --workspace "$ws" --label "$tlabel" --no-focus)
    fi
  fi

  local master; master=$(master_name)
  mut pane rename "$pane" "$label" >&2
  mut pane run "$pane" "HERDMASTER_ROLE=worker HERDMASTER_MASTER=$(printf '%q' "$master") $(printf '%q ' "$@")" >&2
  if (( DRY )); then cmd_rebalance >&2; else cmd_rebalance "$pane" >&2; fi
  echo "$pane"
}

cmd_new_orchestrator() {
  [[ $# -gt 0 ]] || die "new-orchestrator: <command...> required"
  local pane master; master=$(master_name)
  pane=$(mut_json .result.pane.pane_id "<new-pane>" pane split --current --direction right --no-focus)
  mut pane rename "$pane" orchestrator >&2
  mut pane run "$pane" "HERDMASTER_ROLE=orchestrator HERDMASTER_MASTER=$(printf '%q' "$master") $(printf '%q ' "$@")" >&2
  echo "$pane"
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
  rebalance) cmd_rebalance "$@" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
