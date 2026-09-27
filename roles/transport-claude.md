# Claude transport

Claude Code values for the `{{key}}` placeholders in `roles/*.md`. `scripts/build-skills.sh` substitutes them and writes `skills/herdmaster/SKILL.md` (planner), `skills/orchestrator/SKILL.md` (orchestrator) and `examples/worker-brief-template.md` (worker); `<role>.frontmatter` goes on top of that role's skill. Each value is the text between the `~~~` lines under its heading. Edit here or in `roles/`, never in the generated files.

## planner.frontmatter
~~~
---
name: herdmaster
description: Turn this session into the planner ("master") window for a project. The user talks plans and design decisions here; all execution is dispatched to a background orchestrator that runs workers in visible herdr panes. Use when the user says "start plan orchestration", "be the master/planner", "start herdmaster", or runs /herdmaster.
---
~~~

## orchestrator.frontmatter
~~~
---
name: orchestrator
description: Turn this session into the background orchestrator for a multi-pane herdr fleet. It owns all worker-pane traffic (approvals, obvious next steps, merges, starting and closing panes) and sends only genuine design decisions to the master window. Use when asked to "be the orchestrator" or launched with /orchestrator <project>.
---
~~~

## agent_name
~~~
Claude Code
~~~

## project_instructions
~~~
CLAUDE.md
~~~

## agent_list
~~~
`ListAgents`
~~~

## send
~~~
SendMessage
~~~

## idle_watch
~~~
Subscribe with `notify_when_idle: true` and re-arm after every notice (subscriptions are one-shot).
~~~

## modal_tool
~~~
AskUserQuestion
~~~

## resume_flag
~~~
--resume
~~~

## quota_source
~~~
the pane footer or usage line
~~~

## subagents
~~~
Delegate small jobs to the `lookup`, `worker` and `deep` subagents in `~/.claude/agents/`.
~~~

## headless
~~~
headless `claude -p`
~~~

## orchestrator_role
~~~
the `orchestrator` skill
~~~

## orchestrator_launch
~~~
env -u ANTHROPIC_API_KEY claude --disallowedTools AskUserQuestion --model "$HERDMASTER_MODEL_DEFAULT" --dangerously-skip-permissions '/orchestrator <project>'
~~~

## worker_launch
~~~
Every fleet pane, the orchestrator included, launches with `--disallowedTools AskUserQuestion`. That flag is variadic: put it right after `claude` and follow it with another flag, never directly before the brief text.
  Shape: `env -u ANTHROPIC_API_KEY HERDMASTER_ROLE=worker HERDMASTER_MASTER=<master name> claude --disallowedTools AskUserQuestion --model "$MODEL" --dangerously-skip-permissions [--resume <id>] "<brief>"`.
~~~

## model_line
~~~
MODEL: <lookup=haiku | worker=sonnet | deep=opus>  (set by the orchestrator at launch; default sonnet, opus only for judgment-heavy work)
~~~
