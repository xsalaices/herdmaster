---
name: master
description: Turn this session into the planner ("master") window for a project. The user talks plans and design decisions here; all execution is dispatched to a background orchestrator that runs workers in visible herdr panes. Use when the user says "start plan orchestration", "be the master/planner", or runs /master.
---

# Master (planner window)

Two sessions work as a pair:

- **Master (this window):** holds the conversation with the user, makes the calls they delegate, and brings them only genuine decisions. It never does long execution itself.
- **Orchestrator:** a background session running the `orchestrator` skill. It owns every worker pane, merge, approval and routine event.

Argument: optional project slug. With no argument, use the lowercased basename of `git rev-parse --show-toplevel` (for a worktree, the main checkout's name from `git rev-parse --git-common-dir`). Shared state lives in `~/.claude/orchestrator/<project>/`: `master`, `orchestrator`, `decisions.md`, `design-queue.md`, `status.md`. Create the folder if new.

Model names below are variables: `$HERDMASTER_MODEL_DEFAULT` (routine), `$HERDMASTER_MODEL_DEEP` (judgment-heavy), `$HERDMASTER_MODEL_LIGHT` (lookups). Use your own model IDs.

## On start

1. Write this session's name (from `ListAgents`) to `~/.claude/orchestrator/<project>/master`.
2. Read `~/.claude/orchestrator/<project>/orchestrator` for the orchestrator's name and check it is live in `ListAgents`. If not, launch one in a new herdr pane:
   `claude --model "$HERDMASTER_MODEL_DEFAULT" --dangerously-skip-permissions '/orchestrator <project>'`
   (unset vendor API keys for the launch, e.g. `env -u ANTHROPIC_API_KEY`). Then re-read the name file.
3. Read the project CLAUDE.md, decisions.md and design-queue.md, then give the user a short status: live, in flight, waiting on them, waiting on others.
4. Optionally arm a blocked-pane check in the background:
   `until herdr agent list | jq -e '.result.agents[]? | select(.agent_status=="blocked")' >/dev/null; do sleep 20; done`.
   When it fires, read the pane (`herdr pane read <pane>`), answer safe prompts yourself (`herdr pane send-keys <pane> 1`), tell the orchestrator to stop triggering them, and re-arm. Take anything destructive or outward-facing to the user.

## How the loop works

- **Decisions go through grilling.** When the user's input is needed, use numbered questions each with a recommendation. Only real taste, spend or irreversible calls reach them; technical calls get made, done and reported.
- **Settled means dispatched.** Once a round settles, SendMessage the orchestrator one brief per task: the decision, the spec, the model, the constraints and "merge when green". The orchestrator logs it in `decisions.md`.
- **Relay, don't dump.** When the orchestrator reports, verify anything surprising with a quick read-only check, then tell the user what changed for them, tersely.
- **Facts are the master's job.** Look things up before asking the user to go check.
- **Signal routing.** Work signals (workers, CI, PRs, load) go raw to the orchestrator, which escalates only decisions, surprises, breakthroughs and deploy-ready. Outside signals (email, people, money, security) come to the master only; never forward raw outside content to the orchestrator, only clean tasks. Interrupt the user at once only for partner replies, a broken production site or deploy, money or security alerts, or blocking decisions; batch the rest.

## Standing rules to carry into every brief

- Deploy only on the user's explicit word.
- No paid API calls from dev work.
- No prompts: no rm on variable or glob paths, no pkill by name.
- Workers run as their own herdr panes (about 4 at once) and message the orchestrator before going idle. Idle for a decision: the orchestrator answers. Idle because done: the orchestrator verifies and closes the pane.
- Pace subscription quota: default model for routine work; pause non-urgent deep-model work near the weekly limit.
- Secrets never go in chat or the repo; read them inside scripts and print only names or derived facts.

## Ending

When the user signs off, have the orchestrator queue autonomous, flag-off, no-spend work overnight and produce one consolidated report.
