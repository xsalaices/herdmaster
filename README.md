# herdmaster

A planner + orchestrator setup for Claude Code.

You talk plans and design decisions in one window (the **master**). A background **orchestrator** session runs everything else: it launches **worker** panes in herdr, answers routine prompts, merges green PRs and closes finished panes. You are interrupted only when a real decision needs you.

## Why

Parallel Claude Code windows turn into a full-time job: approving prompts, watching CI, merging, closing panes. herdmaster moves that traffic to an orchestrator with clear escalation rules, and adds guard rails (pressure guard, cpu-reaper, brief template) so a fleet does not melt your machine.

## Architecture

```
            you
             |  plans, decisions
             v
      +-------------+   clean tasks / decisions     +----------------+
      |   master    | ----------------------------> |  orchestrator  |
      | (planner)   | <---------------------------- | (background)   |
      +-------------+   blocking decisions only     +----------------+
                                                       |   |   |
                                          briefs / approvals / merges
                                                       v   v   v
                                                 +------+ +------+ +------+
                                                 |worker| |worker| |worker|   herdr panes,
                                                 | pane | | pane | | pane |   one task + worktree each
                                                 +------+ +------+ +------+
                                                       |   |   |
                                                  report before idle
```

## Roles and message flow

- **Master**: holds the conversation, runs decision rounds, dispatches settled work as briefs. Never executes long work.
- **Orchestrator**: owns worker panes, PRs, merges and routine prompts. Logs to `~/.claude/orchestrator/<project>/status.md`.
- **Workers**: one task per pane in its own worktree; message the orchestrator before going idle.

Shared state lives in `~/.claude/orchestrator/<project>/` (`master`, `orchestrator`, `decisions.md`, `design-queue.md`, `status.md`). The `master` and `orchestrator` files hold each session's current name so messages never go to a dead session.

## Escalation rules

- Work signals (workers, CI, PRs, merges, load, stuck panes) go to the orchestrator.
- The orchestrator escalates to the master only for: a decision, a surprise, a breakthrough, or deploy-ready. Everything else is batched into check-ins or logged in `status.md`.
- Outside signals (email, people, money, security) go to the master only. Raw outside content is never forwarded to the orchestrator; the master sends clean tasks.
- Non-blocking questions go to `design-queue.md`; only blocking ones are messaged.

## Works well with wayfinder

[wayfinder](https://github.com/mattpocock/skills/tree/main/skills/engineering/wayfinder) (from [mattpocock/skills](https://github.com/mattpocock/skills), MIT, not part of herdmaster) plans big work as a map of decision tickets and grills you through them. Run both side by side: resolve decisions with `/wayfinder`, and as each ticket closes, hand it to `/herdmaster` as a brief. The orchestrator builds it in a worker pane while you keep deciding the next one. Dispatch only closed tickets, and tell the orchestrator when a later decision supersedes work in flight.

## Guard rails

| piece | what it does |
|---|---|
| `hooks/pressure-check.sh` | records load and free memory to `$HERDMASTER_HOME/state/pressure.json` every minute |
| `hooks/pressure-guard.sh` | PreToolUse hook: denies heavy commands while pressure is high, telling the agent to wait 2-5 minutes and retry. Emergency override: `HERDMASTER_IGNORE_PRESSURE=1` |
| `launchd/cpu-reaper` | kills orphaned leftovers by exact process name only, reports CPU hogs |
| `launchd/blocked-pane-watcher` | EXAMPLE: notifies when a herdr agent is blocked on a prompt |
| `agents/*.md` | pinned-model subagents: lookup (Haiku), worker (Sonnet), deep (Opus) |
| `examples/worker-brief-template.md` | generic fleet rules for every worker brief |

## Model routing

Sonnet is the default for everything. Opus is for genuinely complex work only: hard debugging, design, audits, calibration-critical work. Three pinned-model subagents ship in `agents/` and install to `~/.claude/agents/`:

| agent | model | use for |
|---|---|---|
| `lookup` | Haiku | lookups, greps, counts, status checks |
| `worker` | Sonnet | routine edits, tests, docs, merges, CI |
| `deep` | Opus | audits, design trade-offs, hard debugging |

Quota rules the skills follow: pause non-urgent Opus work when weekly usage passes ~85% (read it from the pane footer or usage line), keep Opus panes to a minimum, and never use high effort for batch drafting. Every worker brief names its model (`MODEL:` line in the template).

## Quick start

```sh
git clone <this repo> && cd herdmaster
scripts/install.sh --dry-run     # preview
scripts/install.sh               # install
```

The install step is required: the `/herdmaster` and `/orchestrator` skills, subagents and guard hooks only exist after `scripts/install.sh` copies them into `~/.claude`. The installer checks the requirements below and tells you what is missing.

Then in Claude Code, inside your project's repo: `/herdmaster`. It starts (or finds) the orchestrator. See [docs/install.md](docs/install.md).

Requirements: macOS, [herdr](https://herdr.dev), Claude Code, `jq`, `python3`.

## herdr patterns used

```sh
herdr pane split --pane <id> --direction right   # new worker pane
herdr pane read <pane>                           # see what a pane shows
herdr pane send-keys <pane> enter                # answer a safe prompt
herdr agent list                                 # statuses (idle, working, blocked)
herdr workspace create --cwd <dir> --label <name>
```

Check `herdr <command> --help` for your version; flags may differ.

## License

MIT
