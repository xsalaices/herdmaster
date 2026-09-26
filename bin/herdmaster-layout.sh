#!/usr/bin/env bash
# Places worker panes and keeps the grid even.
# Usage: herdmaster-layout.sh [--dry-run] new-worker <label> <command...>   prints the new pane id
#        herdmaster-layout.sh [--dry-run] rebalance                        equal widths for the current tab's grid
# Env: HERDMASTER_WORKER_LAYOUT (tab|main, default tab), HERDMASTER_GRID_PANES (default 6),
#      HERDMASTER_MAX_PANES (default 4, total panes on the main tab when layout is main), HERDMASTER_PROJECT.
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

  if [[ $LAYOUT == main ]] && (( $(tab_panes "$tab" "$ws" | wc -l) < MAXP )); then
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
  mut pane run "$pane" "HERDMASTER_ROLE=worker HERDMASTER_MASTER=$(printf '%q' "$master") $*" >&2
  if (( DRY )); then cmd_rebalance >&2; else cmd_rebalance "$pane" >&2; fi
  echo "$pane"
}

# Columns are the distinct x origins of the tab's panes. The resize step size is not documented, so step
# small, re-read the layout, and stop as soon as a boundary stops getting closer to its target.
cmd_rebalance() {
  local anchor=${1:-} layout ncols step=0.05
  if [[ -n $anchor ]]; then layout=$("$HERDR" pane layout --pane "$anchor" | jq -c .result.layout)
  else layout=$("$HERDR" pane layout --current | jq -c .result.layout); fi
  ncols=$(jq '[.panes[].rect.x] | unique | length' <<<"$layout")
  (( ncols > 1 )) || return 0
  local i
  for ((i = 0; i < ncols - 1; i++)); do
    local prev=999999 tries=0
    while (( tries++ < 12 )); do
      local info delta pane dir
      info=$(jq -r --argjson i "$i" '
        .area.width as $w | ([.panes[].rect.x] | unique) as $xs
        | (($w * ($i + 1) / ($xs | length)) | round) as $want
        | ($xs[$i + 1] - $want) as $have
        | ([.panes[] | select(.rect.x == $xs[$i])] | min_by(.rect.y) | .pane_id) as $p
        | "\(-$have) \($p)"' <<<"$layout")
      delta=${info% *}; pane=${info#* }
      local abs=${delta#-}
      (( abs <= 1 || abs >= prev )) && break
      prev=$abs
      if (( delta > 0 )); then dir=right; else dir=left; fi
      mut pane resize --pane "$pane" --direction "$dir" --amount "$step"
      (( DRY )) && break
      layout=$("$HERDR" pane layout --pane "$pane" | jq -c .result.layout)
    done
  done
}

sub=${1:-}; shift || true
case $sub in
  new-worker) cmd_new_worker "$@" ;;
  rebalance) cmd_rebalance ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
