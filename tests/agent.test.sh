#!/usr/bin/env bash
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"
A="$R/bin/herdmaster-agent.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME="$T"
unset HERDMASTER_PROJECT HERDMASTER_MODEL_LIGHT HERDMASTER_MODEL_DEFAULT HERDMASTER_MODEL_DEEP
argv=()
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"; }
same_argv() { # <quoted command> <quoted command>
  local -a x y; eval "x=($1)"; eval "y=($2)"
  [[ ${#x[@]} -eq ${#y[@]} ]] || fail "argv length differs: [$1] vs [$2]"
  local i; for ((i = 0; i < ${#x[@]}; i++)); do [[ ${x[i]} == "${y[i]}" ]] || fail "argv[$i] differs: [$1] vs [$2]"; done
}

# The orchestrator launch in the planner skill, verbatim.
line=$(grep -F 'herdmaster-layout.sh new-orchestrator' "$R/skills/herdmaster/SKILL.md")
skill=${line#*new-orchestrator }; skill=${skill%\`}; skill=${skill//<project>/demo}
HERDMASTER_MODEL_DEFAULT=model-d same_argv "$skill" "$(HERDMASTER_MODEL_DEFAULT=model-d "$A" command orchestrator default '/orchestrator demo')"

# The worker shape in the orchestrator skill (layout puts HERDMASTER_ROLE/HERDMASTER_MASTER in front of env).
line=$(grep -F 'Shape: `env -u' "$R/skills/orchestrator/SKILL.md")
shape=${line#*\`}; shape=${shape%\`.}; shape=${shape/HERDMASTER_ROLE=worker HERDMASTER_MASTER=<master name> /}
export MODEL=model-w
same_argv "${shape/\[--resume <id>\] /}" "$(HERDMASTER_MODEL_DEFAULT=model-w "$A" command worker default '<brief>')"
same_argv "${shape/\[--resume <id>\]/--resume sess-1}" "$(HERDMASTER_MODEL_DEFAULT=model-w "$A" command worker default --resume sess-1 '<brief>')"

eval "argv=($("$A" command worker deep 'x'))"
eq "${argv[3]}" claude
eq "${argv[4]}" --disallowedTools
[[ ${argv[6]} == --* ]] || fail "--disallowedTools must be followed by a flag"
eq "${argv[${#argv[@]}-1]}" x

# shellcheck disable=SC2016
brief=$'multi word "brief"\nwith it'"'"'s $HOME and `ticks`'
eval "argv=($("$A" command worker default "$brief"))"
eq "${argv[${#argv[@]}-1]}" "$brief"
eval "argv=($("$A" command worker default))"
eq "${argv[${#argv[@]}-1]}" --dangerously-skip-permissions

eq "$("$A" model worker light)" haiku
eq "$("$A" model worker default)" sonnet
eq "$("$A" model worker deep)" opus
eq "$(HERDMASTER_MODEL_DEEP=model-x "$A" model worker deep)" model-x
eq "$("$A" guard worker)" hook
"$A" model worker huge 2>/dev/null && fail "bad tier accepted"
"$A" command boss default x 2>/dev/null && fail "bad role accepted"
"$A" command worker default a b 2>/dev/null && fail "two prompt words accepted"

# Settings pick the adapter per role: agent_<role>, then agent, then claude.
export HERDMASTER_PROJECT=demo
B="$R/bin/herdmaster-board.sh"
eq "$("$B" settings get agent)" claude
eq "$("$B" settings get agent_worker)" claude
"$B" settings set agent nope 2>/dev/null && fail "agent without adapter accepted"
"$B" settings set agent claude
eq "$("$B" settings get agent_orchestrator)" claude
mkdir -p "$T/hm/bin" "$T/hm/adapters"
cp "$A" "$B" "$T/hm/bin/"
cp "$R/adapters/claude.sh" "$T/hm/adapters/"
cat > "$T/hm/adapters/fake.sh" <<'FAKE'
hm_kind() { echo fake; }
hm_env_unset() { :; }
hm_model() { echo "fake-$1"; }
hm_guard() { echo none; }
hm_prompt() { echo arg; }
hm_launch() { HM_ARGV=(fake-agent --role "$1" -m "$2"); }
hm_resume() { HM_ARGV=(fake-agent resume "$3" -m "$2"); }
FAKE
"$T/hm/bin/herdmaster-board.sh" settings set agent_worker fake
same_argv "$("$T/hm/bin/herdmaster-agent.sh" command worker deep hi)" "fake-agent --role worker -m fake-deep hi"
same_argv "$("$T/hm/bin/herdmaster-agent.sh" command worker light --resume s1)" "fake-agent resume s1 -m fake-light"
eq "$("$T/hm/bin/herdmaster-agent.sh" guard worker)" none
eq "$("$T/hm/bin/herdmaster-agent.sh" command orchestrator default hi | cut -d' ' -f4)" claude
"$T/hm/bin/herdmaster-board.sh" settings set agent fake
eq "$("$T/hm/bin/herdmaster-agent.sh" guard orchestrator)" none
rm -f -- "$T/.claude/orchestrator/demo/settings.json"

# herdmaster-layout.sh --tier launches exactly what the explicit command form launches.
cat > "$T/herdr" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") echo '{"result":{"pane":{"pane_id":"pane-a","tab_id":"tab-1","workspace_id":"ws-1"}}}' ;;
  "pane list") echo '{"result":{"panes":[{"pane_id":"pane-a","tab_id":"tab-1"}]}}' ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "pane layout") echo '{"result":{"layout":{"area":{"width":200,"height":60},"panes":[{"pane_id":"pane-a","rect":{"x":0,"y":0,"width":200,"height":60}}],"splits":[]}}}' ;;
  *) echo "MUTATION: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$T/herdr"
export HERDMASTER_HERDR="$T/herdr" HERDMASTER_MODEL_DEFAULT=model-d
L="$R/bin/herdmaster-layout.sh"
run_line() { "$L" --dry-run "$@" 2>&1 | grep -F "pane run"; }
eq "$(run_line new-worker build --tier default --resume sess-1 "$brief")" \
   "$(run_line new-worker build env -u ANTHROPIC_API_KEY claude --disallowedTools AskUserQuestion --model model-d --dangerously-skip-permissions --resume sess-1 "$brief")"
eq "$(run_line new-orchestrator --tier default '/orchestrator demo')" \
   "$(run_line new-orchestrator env -u ANTHROPIC_API_KEY claude --disallowedTools AskUserQuestion --model model-d --dangerously-skip-permissions '/orchestrator demo')"
"$L" --dry-run new-worker build --tier huge x >/dev/null 2>&1 && fail "layout accepted a bad tier"
# Codex adapter: selected per role by settings, own env strips, own model tiers, resume shape.
export HERDMASTER_PROJECT=demo
"$R/bin/herdmaster-board.sh" settings set agent_worker codex >/dev/null
eq "$("$A" command worker default 'do it')" \
   "env -u OPENAI_API_KEY -u CODEX_API_KEY codex --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m model-d do\\ it "
eq "$("$A" command worker default --resume sess-9)" \
   "env -u OPENAI_API_KEY -u CODEX_API_KEY codex resume sess-9 --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m model-d "
eq "$(HERDMASTER_MODEL_LIGHT= "$A" model worker light)" "gpt-6-luna"
eq "$("$A" guard worker)" hook
eq "$("$A" command planner default x)" "$(printf '%q ' env -u ANTHROPIC_API_KEY claude --disallowedTools AskUserQuestion --model model-d --dangerously-skip-permissions x)"
unset HERDMASTER_PROJECT
echo ok
