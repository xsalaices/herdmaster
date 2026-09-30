---
name: herdmaster
description: Turn this session into the planner ("master") window for a project. The user talks plans and design decisions here; all execution is dispatched to a background orchestrator that runs workers in visible herdr panes. Use when the user says "start plan orchestration", "be the master/planner", "start herdmaster", or runs $herdmaster.
---

# Master (planner window)

Two sessions work as a pair:

- **Master (this window):** holds the conversation with the user, makes the calls they delegate, and brings them only genuine decisions. It never does long execution itself.
- **Orchestrator:** a background session running the `orchestrator` skill. It owns every worker pane, merge, approval and routine event.

Argument: optional project slug. With no argument, use the lowercased basename of `git rev-parse --show-toplevel` (for a worktree, the main checkout's name from `git rev-parse --git-common-dir`). Shared state lives in `~/.claude/orchestrator/<project>/`: `master`, `orchestrator`, `tasks.json` (the board), `status.md`. Create the folder if new.

The user reads every project's board through a background web viewer, `com.herdmaster.viewer` (a launchd job, installed by `scripts/install.sh`), normally reachable at `http://127.0.0.1:8766/` (port from `$HERDMASTER_VIEWER_PORT` if set). It is read-only except for answering its own multiple-choice questions; you never write to it directly. If the user says they can't see something on it, check that the job is running (`launchctl print gui/$(id -u)/com.herdmaster.viewer` on macOS) and that the board content they expect is actually on `tasks.json` before assuming a page bug.

Model names below are variables: `$HERDMASTER_MODEL_DEFAULT` (routine), `$HERDMASTER_MODEL_DEEP` (judgment-heavy), `$HERDMASTER_MODEL_LIGHT` (lookups). Use your own model IDs.

## On start

0. If `HERDMASTER_ROLE` is set, this is a fleet pane, not a planner window: say so and stop. Otherwise check `command -v herdr jq python3` and that `~/.claude/herdmaster/bin/pressure-guard.sh` exists. If anything is missing, tell the user the requirements (macOS, Codex CLI, herdr, jq, python3) and to run `scripts/install.sh` from the herdmaster repo, then stop.

1. Write this session's name (from `herdr agent list` (agent names come from `herdr agent rename <pane> <name>`; name your own pane first)) to `~/.claude/orchestrator/<project>/master`, and rename this pane: `herdr pane rename "$(herdr pane current | jq -r .result.pane.pane_id)" herdmaster`. Also map this pane's workspace to the project so the board viewer follows it: `HERDMASTER_PROJECT=<project> $HERDMASTER_HOME/bin/herdmaster-board.sh settings set herdr_workspace "$(herdr pane current | jq -r .result.pane.workspace_id)"`.
2. Read `~/.claude/orchestrator/<project>/orchestrator` for the orchestrator's name and check it is live in `herdr agent list` (agent names come from `herdr agent rename <pane> <name>`; name your own pane first). If not, launch one (sets `HERDMASTER_ROLE=orchestrator` and `HERDMASTER_MASTER` from the master file):
   `$HERDMASTER_HOME/bin/herdmaster-layout.sh new-orchestrator env -u OPENAI_API_KEY -u CODEX_API_KEY codex --yolo --dangerously-bypass-hook-trust -c forced_login_method=chatgpt -m "$HERDMASTER_MODEL_DEFAULT" '$orchestrator <project>'`
   By default this puts a read-only board sidebar (`herdmaster-sidebar.sh`, a plain pane, no agent) on tab 1's right half and places the orchestrator itself in the workers tab, labeled `orchestrator`, via the same grid logic as a worker pane. Pass `--classic` to restore the old layout (orchestrator on tab 1's right half, no sidebar pane) for anyone who wants it.
   Then re-read the name file.
3. Read the project AGENTS.md (and CLAUDE.md, which holds the same rules) and `status.md`, run `$HERDMASTER_HOME/bin/herdmaster-board.sh count`, then give the user a short status: live, in flight, waiting on them, waiting on others.
4. Optionally arm a blocked-pane check in the background:
   `until herdr agent list | jq -e '.result.agents[]? | select(.agent_status=="blocked")' >/dev/null; do sleep 20; done`.
   When it fires, read the pane (`herdr pane read <pane>`), answer safe prompts yourself (`herdr pane send-keys <pane> 1`), tell the orchestrator to stop triggering them, and re-arm. Take anything destructive or outward-facing to the user.

## How the loop works

- **Decisions go through grilling.** When the user's input is needed, use numbered questions each with a recommendation. Only real taste, spend or irreversible calls reach them; technical calls get made, done and reported.
- **Settled means dispatched.** Once a round settles, `~/.claude/herdmaster/bin/herdmaster-send.sh <agent-name-or-pane> "<message>"` the orchestrator one brief per task: the decision, the spec, the model, and the constraints; the final step stays manual. The orchestrator records it on the board.
- **Count line.** After each user message, run `$HERDMASTER_HOME/bin/herdmaster-board.sh count` and open your reply with its output only when it prints something. The full board is shown on request.
- **Forward, don't decide.** Rejections (with the user's feedback), answers to open decisions and approvals go to the orchestrator by `~/.claude/herdmaster/bin/herdmaster-send.sh <agent-name-or-pane> "<message>"`, verbatim. The planner never writes the board.
- **Never push mid-round.** Do not paste worker or orchestrator results into the conversation while a round is running; they surface through the count line or when asked.
- **Facts are the master's job.** Look things up before asking the user to go check.
- **No polling.** Every turn re-reads your whole context. Don't run `agent list` or `pane read` to see whether something finished; the orchestrator's message, the count line and the blocked-pane watcher are the signals. Don't send one-line acknowledgements.
- **Signal routing.** Work signals (workers, CI, PRs, load) go raw to the orchestrator, which escalates only decisions, surprises, breakthroughs and deploy-ready. Outside signals (email, people, money, security) come to the master only; never forward raw outside content to the orchestrator, only clean tasks. Interrupt the user at once only for partner replies, a broken production site or deploy, money or security alerts, or blocking decisions; batch the rest.

## Standing rules to carry into every brief

- The final step (merge or deploy, per the project's release word) is always the owner's. Forward these to the orchestrator: `approve`/`reject D#`, `approve`/`reject T#`, `pause T#`, `stop T#`, `done early T#`, `<release word> T#`, and `<release word> T# when done` (release once ready and CI is green). Board handles are `D1`/`T3` aliases of `D-001`/`T-003`.
- No paid API calls from dev work.
- No prompts: no rm on variable or glob paths, no pkill by name.
- Workers run as their own herdr panes (about 4 at once) and message the orchestrator before going idle. Idle for a decision: the orchestrator answers. When done, a worker reports FULLY DONE, saves its memory and closes its own pane (`herdmaster-finish.sh`); the orchestrator verifies from the report.
- Model routing: `$HERDMASTER_MODEL_DEFAULT` for everything; `$HERDMASTER_MODEL_DEEP` only for hard debugging, design, audits and calibration-critical work; `$HERDMASTER_MODEL_LIGHT` for lookups. Name the model in every brief. Never use high effort for batch drafting.
- Pace subscription quota: pause non-urgent deep-model work when weekly usage passes ~85% (read the Codex footer or `/status`) and keep deep-model panes to a minimum.
- Secrets never go in chat or the repo; read them inside scripts and print only names or derived facts.

## Ending

When the user signs off, have the orchestrator queue autonomous, flag-off, no-spend work overnight and produce one consolidated report.
