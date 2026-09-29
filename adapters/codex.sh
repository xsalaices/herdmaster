# shellcheck shell=bash
# Codex CLI adapter. Sourced by bin/herdmaster-agent.sh: defines functions only, no side effects.
# Interface (every adapter): hm_kind, hm_env_unset, hm_model TIER, hm_guard, hm_prompt,
# hm_launch ROLE MODEL and hm_resume ROLE MODEL ID (both set HM_ARGV).

hm_kind() { echo codex; }

# Codex bills the API instead of the ChatGPT login when either key is set.
hm_env_unset() { echo OPENAI_API_KEY CODEX_API_KEY; }

hm_model() {
  case $1 in
    light) echo "${HERDMASTER_MODEL_LIGHT:-gpt-6-luna}" ;;
    default) echo "${HERDMASTER_MODEL_DEFAULT:-gpt-6.1-sol}" ;;
    deep) echo "${HERDMASTER_MODEL_DEEP:-gpt-6-astra}" ;;
    *) return 1 ;;
  esac
}

# hook: Codex PreToolUse hooks take the same deny shape as Claude's, so hooks/pressure-guard.sh applies
# once the owner has approved the hook definition in Codex (a one-time interactive step).
hm_guard() { echo hook; }

# arg: the prompt is the last word of the launch argv.
hm_prompt() { echo arg; }

# --yolo = no approvals and no sandbox, the counterpart of --dangerously-skip-permissions (the sandbox
# would otherwise block the herdr socket that herdmaster-send.sh needs). forced_login_method pins the
# ChatGPT login; the plain config key is ignored (openai/codex#46914) but the -c override works.
# --dangerously-bypass-hook-trust skips Codex's per-hook manual approval; the only hooks are the owner's own
# (examples/codex-hooks.json), and an unattended fleet pane cannot answer that prompt.
hm_launch() {
  # shellcheck disable=SC2034
  HM_ARGV=(codex --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m "$2")
}

# `codex resume ID` takes the same flags.
hm_resume() {
  # shellcheck disable=SC2034
  HM_ARGV=(codex resume "$3" --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m "$2")
}
