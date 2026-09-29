# Codex transport

Codex CLI values for the `{{key}}` placeholders in `roles/*.md`. `scripts/build-skills.sh --transport codex` substitutes them and writes `skills-codex/herdmaster/SKILL.md` (planner), `skills-codex/orchestrator/SKILL.md` (orchestrator) and `examples/worker-brief-template.codex.md` (worker). Codex has no `SendMessage`, `ListAgents` or modal question tool, so those map to `herdmaster-send.sh`, `herdr agent list` and plain chat. Its subagents are custom agent roles (`lookup`, `worker`, `deep`) defined in `~/.codex/config.toml` with per-role model files (see `examples/codex-agents/`). Edit here or in `roles/`, never in the generated files.

## planner.frontmatter
~~~
---
name: herdmaster
description: Turn this session into the planner ("master") window for a project. The user talks plans and design decisions here; all execution is dispatched to a background orchestrator that runs workers in visible herdr panes. Use when the user says "start plan orchestration", "be the master/planner", "start herdmaster", or runs $herdmaster.
---
~~~

## orchestrator.frontmatter
~~~
---
name: orchestrator
description: Turn this session into the background orchestrator for a multi-pane herdr fleet. It owns all worker-pane traffic (approvals, obvious next steps, merges, starting and closing panes) and sends only genuine design decisions to the master window. Use when asked to "be the orchestrator" or launched with $orchestrator <project>.
---
~~~

## agent_name
~~~
Codex CLI
~~~

## project_instructions
~~~
AGENTS.md (and CLAUDE.md, which holds the same rules)
~~~

## agent_list
~~~
`herdr agent list` (agent names come from `herdr agent rename <pane> <name>`; name your own pane first)
~~~

## send
~~~
`~/.claude/herdmaster/bin/herdmaster-send.sh <agent-name-or-pane> "<message>"`
~~~

## idle_watch
~~~
Workers message you before going idle, and a brief-named report file is the source of truth for "done". To wait on a pane that has not reported, use `herdr agent wait <name> --until idle --until done --timeout 600`; herdr's Codex state detection is unreliable, so never treat a timeout or a state flip as proof.
~~~

## modal_tool
~~~
a modal question prompt (none; ask in plain chat)
~~~

## resume_flag
~~~
codex resume
~~~

## quota_source
~~~
the Codex footer or `/status`
~~~

## subagents
~~~
Delegate small jobs to the `lookup`, `worker` and `deep` subagents (Codex agent roles pinned to `gpt-6-luna`, `gpt-6.1-sol` and `gpt-6-astra`): ask Codex to spawn the named subagent.
~~~

## headless
~~~
headless `codex exec`
~~~

## orchestrator_role
~~~
the `orchestrator` skill
~~~

## orchestrator_launch
~~~
env -u OPENAI_API_KEY -u CODEX_API_KEY codex --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m "$HERDMASTER_MODEL_DEFAULT" '$orchestrator <project>'
~~~

## worker_launch
~~~
Build the launch with `herdmaster-agent.sh command worker <tier> "<brief>"` (adapter `codex`), which strips `OPENAI_API_KEY`/`CODEX_API_KEY` and adds `--yolo`, `--dangerously-bypass-hook-trust` and the ChatGPT-login pin.
  Shape: `env -u OPENAI_API_KEY -u CODEX_API_KEY HERDMASTER_ROLE=worker HERDMASTER_MASTER=<master name> codex --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m "$MODEL" "<brief>"`.
~~~

## model_line
~~~
MODEL: <light=gpt-6-luna | default=gpt-6.1-sol | deep=gpt-6-astra>  (set by the orchestrator at launch; default gpt-6.1-sol, gpt-6-astra only for judgment-heavy work)
~~~
