# shellcheck shell=bash
# Claude Code adapter. Sourced by bin/herdmaster-agent.sh: defines functions only, no side effects.
# Interface (every adapter): hm_kind, hm_env_unset, hm_model TIER, hm_guard, hm_prompt,
# hm_launch ROLE MODEL and hm_resume ROLE MODEL ID (both set HM_ARGV).

hm_kind() { echo claude; }

hm_env_unset() { echo ANTHROPIC_API_KEY; }

hm_model() {
  case $1 in
    light) echo "${HERDMASTER_MODEL_LIGHT:-haiku}" ;;
    default) echo "${HERDMASTER_MODEL_DEFAULT:-sonnet}" ;;
    deep) echo "${HERDMASTER_MODEL_DEEP:-opus}" ;;
    *) return 1 ;;
  esac
}

# hook: the PreToolUse pressure guard applies (see hooks/pressure-guard.sh).
hm_guard() { echo hook; }

# arg: the prompt is the last word of the launch argv.
hm_prompt() { echo arg; }

# --disallowedTools is variadic: it stays right after `claude` and is followed by another flag, never by the prompt.
hm_launch() {
  # shellcheck disable=SC2034
  HM_ARGV=(claude --disallowedTools AskUserQuestion --model "$2" --dangerously-skip-permissions)
}

hm_resume() {
  hm_launch "$1" "$2"
  HM_ARGV+=(--resume "$3")
}
