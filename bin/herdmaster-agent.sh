#!/usr/bin/env bash
# Builds fleet pane launch commands through the adapter in adapters/<agent>.sh (see docs/design/providers.md).
# Usage: herdmaster-agent.sh command <role> <tier> [--resume <id>] [prompt]   prints the argv, printf '%q ' per word
#        herdmaster-agent.sh model <role> <tier>                              prints the model id for the tier
#        herdmaster-agent.sh guard <role>                                     prints the guard type (hook, shim or none)
# Roles: planner, orchestrator, worker. Tiers: light, default, deep.
# Agent: settings key agent_<role>, then agent, then claude (read with herdmaster-board.sh when HERDMASTER_PROJECT is set).
set -euo pipefail

die() { echo "herdmaster-agent: $*" >&2; exit 2; }
BIN=$(cd "$(dirname "$0")" && pwd)
ADAPTERS="$BIN/../adapters"

use_adapter() {
  local role=$1 agent=claude
  [[ $role =~ ^(planner|orchestrator|worker)$ ]] || die "unknown role '$role'"
  if [[ -n ${HERDMASTER_PROJECT:-} ]]; then agent=$("$BIN/herdmaster-board.sh" settings get "agent_$role"); fi
  [[ -f $ADAPTERS/$agent.sh ]] || die "no adapter for agent '$agent'"
  # shellcheck source=/dev/null
  source "$ADAPTERS/$agent.sh"
}

model_for() { hm_model "$1" || die "unknown tier '$1'"; }

cmd_command() {
  [[ $# -ge 2 ]] || die "command: <role> <tier> required"
  local role=$1 tier=$2 resume="" model v argv=()
  shift 2
  if [[ ${1:-} == --resume ]]; then
    [[ -n ${2:-} ]] || die "command: --resume needs a session id"
    resume=$2; shift 2
  fi
  (( $# <= 1 )) || die "command: pass the prompt as one argument"
  use_adapter "$role"
  model=$(model_for "$tier")
  if [[ -n $resume ]]; then hm_resume "$role" "$model" "$resume"; else hm_launch "$role" "$model"; fi
  for v in $(hm_env_unset); do argv+=(-u "$v"); done
  if (( ${#argv[@]} )); then argv=(env "${argv[@]}"); fi
  argv+=("${HM_ARGV[@]}")
  if (( $# )); then
    [[ $(hm_prompt) == arg ]] || die "agent $(hm_kind) does not take the prompt on its command line"
    argv+=("$1")
  fi
  printf '%q ' "${argv[@]}"
}

sub=${1:-}; shift || true
case $sub in
  command) cmd_command "$@" ;;
  model) [[ $# -eq 2 ]] || die "model: <role> <tier> required"; use_adapter "$1"; model_for "$2" ;;
  guard) [[ $# -eq 1 ]] || die "guard: <role> required"; use_adapter "$1"; hm_guard ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
