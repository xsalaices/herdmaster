Status: draft, not implemented

# Design draft: running herdmaster with any terminal agent

Status: draft for review. Scope: design only, no code in this document is final.

Goal: planner, orchestrator and workers can be any terminal coding agent that herdr can host (Codex CLI, Antigravity CLI, opencode, Pi, Copilot CLI, ...), while the current Claude Code path keeps working byte-for-byte.

Legend: **[V]** verified against a primary source (docs, `--help`, issue tracker) on the date of writing. **[S]** secondary source only (blog, cheat sheet). **[I]** inference or proposal, not verified.

---

## 1. Recommendation in one paragraph

Do not build a messaging system per agent. Use three things herdr and the filesystem already give us: (1) herdr's agent API (`agent start/prompt/wait/read/send-keys/rename/list`) for launching, nudging and observing panes; (2) a file inbox plus a report file per task as the durable message channel, so no message ever lives only in keystrokes; (3) a small watcher process that turns herdr state changes into inbox entries for the orchestrator. Put everything provider-specific behind one adapter file per agent (launch argv, model tiers, env to strip, resume flag, guard mechanism). Generate the Claude skills and the neutral role prompts from one shared source. Keep SendMessage for Claude-to-Claude pairs in phase 1 so nothing changes for current users. Prove it with Claude planner + Claude orchestrator + Codex workers before making the planner or orchestrator non-Claude.

---

## 2. What herdr already gives an orchestrator

Installed CLI checked: herdr 0.9.0 (`herdr --version`); current stable docs are 0.9.1 (https://herdr.dev/llms.txt).

### 2.1 Detection and integrations [V]

Source: `agents.mdx`, `integrations.mdx` (v0.9.1), `herdr agent start --help`, `herdr integration --help`.

- `herdr agent start --kind` accepts (0.9.0): pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, qwen, maki, muse. 0.9.1 docs add letta.
- Two kinds of integration:
  - **Lifecycle authority** (hooks/plugin author idle/working/blocked; screen detection is skipped): Pi, OMP, Kimi, OpenCode, Kilo, MastraCode.
  - **Session identity only** (state still comes from screen manifests): Claude Code, Codex, Copilot CLI, Devin, Droid, Qoder, Qwen, Letta, Cursor, Hermes, Antigravity CLI, Grok.
- "Detected but less thoroughly tested: Gemini CLI and Cline." There is no Gemini CLI integration.
- aider is not in the kind list and has no integration: herdr sees it as a plain process.
- Any agent (or wrapper) can report its own state: `herdr pane report-agent <pane> --source custom:x --agent x --state idle|working|blocked`, and `pane release-agent` on exit. Panes inherit `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH`.
- Session references reported by integrations are exposed on the agent record: `herdr agent list` returns `agent_session.{agent,kind,source,value}` per agent (field names checked locally, values not recorded). Herdr uses them to resume panes after a server restart (Claude, Codex, Copilot, Pi, OpenCode, Antigravity, and others).

### 2.2 Agent API vs what SendMessage/ListAgents do today [V unless marked]

Sources: `agent-automation.mdx`, `socket-api.mdx`, `herdr --skill`, `herdr agent <cmd> --help`.

| Need (today via Claude Code) | herdr primitive | Caveats |
|---|---|---|
| Send a task to a worker (SendMessage) | `agent prompt <name> <text> [--wait] [--timeout]`: text + Enter as one ordered submission, bracketed-paste aware | Rejects only `blocked` agents (`agent_blocked`). Accepts input while the agent is `working` (queues into the same conversation, #4052 closed as by-design) and while `unknown` (#4641 open: can type into a trust dialog and accept it). Submission can report success without the Enter landing (#2422 open). |
| Know a worker is idle / done / blocked (`notify_when_idle`) | `agent wait <name> [--until ...] [--timeout]`; `agent prompt --wait`; socket `events.subscribe` with `pane.agent_status_changed` per pane | `idle` and `done` both mean ready; `done` = not yet seen. Waits track state, not turns. No default timeout. `--until idle` alone can hang after focus flips done to idle (#4473 open): always use the default set or `--until idle --until done`. A hung but alive agent never wakes a wait (#4280 closed: use `--timeout`). |
| Read a worker's final output | `agent read <name> --source recent-unwrapped --lines N` | Alternate-screen agents (Claude Code, OpenCode) only yield history when idle; herdr's own docs recommend asking the agent to write the answer to a file when the read is incomplete. |
| Answer a prompt | `agent send-keys <name> enter|esc|1|ctrl+c` | Validates keys first. #3313 open: `enter` may not submit stuck composer text. |
| Name a session (ListAgents names) | `agent rename <target> <name>`, or the name given to `agent start` | Names: `[a-z][a-z0-9_-]{0,31}`, unique among live agents, cleared when the agent exits. |
| Launch | `agent start <name> --kind K --pane P -- <args>` (pane must be at a shell prompt) | Codex can stay `launch_pending` and time out while ready (#3385 open); Pi similar (#3853 open). Needs a fallback to `pane run` + `agent rename`. |

### 2.3 Events: useful, not trustworthy as the only signal [V]

- `events.subscribe` streams do not replay history, target panes must be listed explicitly; a fleet-wide watch was declined as a feature request (#4027 closed).
- #3124 (open): an ACKed subscription can silently stop receiving events while the connection stays open.
- #4178 (closed, fix on preview channel only as of 2026-09-21): bursts over ~500 events dropped silently, no sequence numbers.
- State misclassification is common and agent-specific: Codex trust prompt and `/model` picker reported idle (#4343, #4647), Codex reported blocked while working (#4322), Antigravity idle while generating (#3530), OpenCode `working` while a permission prompt is pending so waits never wake (#4557), Pi dialogs reported working (#4143), Claude AskUserQuestion reported idle in some layouts (#4573, #4668, #2868).

Conclusion **[I]**: herdr state is a hint for *when to look*. The durable truth for "finished" must be a file the worker writes. Poll `herdr agent list` as the source of truth; treat events as an optional accelerator.

### 2.4 Plugins [V]

herdr plugins (`plugins.mdx`) are manifest-declared commands with event hooks (`[[events]] on = "..."`) and full CLI access. They could host the watcher later, but plugin event hooks ride the same event bus as 2.3, so they inherit its gaps. Not needed for the first phases.

---

## 3. Agent survey

"Initial prompt" means start the interactive TUI with a first message, which is what herdmaster panes need (the pane stays alive for follow-ups).

### 3.1 Codex CLI (openai/codex, Apache-2.0)

- Launch: `codex [PROMPT]` starts the TUI with a first prompt; `codex exec` is non-interactive (`--json`, `--output-last-message`) [V: learn.chatgpt.com/docs/developer-commands].
- Model: `-m/--model` [V]. Profiles: `-p/--profile` [V].
- No prompts: `-a/--ask-for-approval never` with `-s workspace-write`, or `--dangerously-bypass-approvals-and-sandbox` (`--yolo`) [V].
- Instructions: AGENTS.md chain from `~/.codex` then repo root to cwd, `AGENTS.override.md`, 32 KiB default cap (`project_doc_max_bytes`) [S/V]. Config keys `developer_instructions` ("Additional developer instructions injected into the session") and `model_instructions_file` exist [V: config reference]; settable per launch with `-c key=value` [V]. Skills: `~/.agents/skills` and repo `.agents/skills`, invoked as `$name` [V: learn.chatgpt.com/docs/build-skills].
- Resume: `codex resume <SESSION_ID>` / `--last` [V]; herdr's Codex integration reports the session id [V].
- Hooks: `SessionStart`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, and more; configured in `~/.codex/hooks.json` or `config.toml`. PreToolUse receives `tool_name: "Bash"` and `tool_input.command`, and denies with the same `hookSpecificOutput.permissionDecision: "deny"` shape Claude Code uses [V: learn.chatgpt.com/docs/hooks]. So `hooks/pressure-guard.sh` is plausibly reusable unchanged [I, test with a fixture]. Gotcha: "Codex requires you to review and trust the exact hook definition" before a non-managed hook runs, and re-review after changes [V] — a one-time interactive step the owner must do, never a worker.
- herdr: screen-manifest state, session integration. Bugs above (#3385, #4343, #4647, #4322).
- Paid-API gotcha: if `OPENAI_API_KEY` is set Codex uses it instead of the ChatGPT login [S]. `forced_login_method = "chatgpt"` in config.toml is reportedly ignored while `-c forced_login_method=chatgpt` works (openai/codex#46914, open) [V]. Adapter must unset `OPENAI_API_KEY` and `CODEX_API_KEY` and pass the `-c` override.
- Open question [I]: each fresh worktree is a new folder; whether Codex shows its "trust this folder" screen per worktree under `--yolo`, and whether a `-c projects."<path>".trust_level=...` override suppresses it, is unverified. #4641 shows that screen can be auto-accepted by a stray prompt.

### 3.2 Gemini CLI (google-gemini/gemini-cli, Apache-2.0) — exclude

- Flags exist and are clean: `-i/--prompt-interactive`, `-p`, `-m`, `--approval-mode default|auto_edit|yolo|plan` (`--yolo` deprecated), `--resume latest|<n>`; hooks `BeforeTool`/`AfterAgent` etc. with deny as `{"decision":"deny","reason":...}` + exit 2 [V: repo docs].
- But Google stopped serving Gemini CLI for free tier, Google AI Pro/Ultra and Code Assist for individuals on 2026-06-18; only paid API keys / enterprise licenses keep working [V: developers.googleblog.com transition post]. Under the no-paid-API rule Gemini CLI is out. Its successor is Antigravity CLI.

### 3.3 Antigravity CLI (`agy`, proprietary)

- Google's replacement; reads GEMINI.md/AGENTS.md; hooks and plugins continue [V: Google blog]. Settings at `~/.gemini/antigravity-cli/settings.json`; `--dangerously-skip-permissions` and `--sandbox` exist [V: antigravity.google/docs/cli/using].
- `-i/--prompt-interactive`, `-p/--print`, `--model`, `--conversation <id>`, `--continue`, rules in `GEMINI.md`, `AGENTS.md`, `.agents/rules/*.md`, global `~/.gemini/GEMINI.md`; `GEMINI_API_KEY` path is API billing [S only: computingforgeeks cheat sheet].
- herdr: kind `agy`, session integration resumes with `agy --conversation <id>` [V]. State is unreliable: idle while generating (#3530), trust and permission prompts reported idle (#3419, #3871). Hook deny semantics not verified.

### 3.4 opencode (anomalyco/opencode, MIT)

- Launch: `opencode --prompt <text> --model provider/model --agent <a>`; `opencode run` for non-interactive; `--continue`, `--session <id>`; `--auto` "Auto-approve permissions that are not explicitly denied" [V: opencode.ai/docs/cli]. A v2 exists and the docs banner says v1 pages are older [V].
- Permissions: `"permission": "allow"` in `opencode.json`, or per-tool patterns [V].
- Instructions: AGENTS.md up the tree, `~/.config/opencode/AGENTS.md`, falls back to `CLAUDE.md` and `~/.claude/CLAUDE.md`; `instructions` array in config [V]. Skills from `~/.claude/skills`, `~/.agents/skills` and project equivalents, loaded via a `skill` tool [V].
- Guard: plugins can throw in `tool.execute.before` to block a tool [V]; `session.idle` event exists [V].
- herdr: lifecycle authority via plugin; #4557 (blocked overwritten by working, waits never wake), #4511 (idle while subagent runs), v1/v2 plugin churn (#3652).
- Paid-API gotcha: provider-agnostic. Anthropic prohibited Claude Pro/Max subscription auth in third-party harnesses in 2026 and has changed enforcement several times [S: multiple news reports]. Treat Claude-via-opencode as unsupported. Allowed paths: a subscription login the vendor permits for third-party tools, or local models.

### 3.5 Pi (earendil-works/pi, MIT; formerly badlogic/pi-mono)

- Launch: `pi "<message>"` interactive with first prompt, `-p/--print`, `--mode json|rpc` [V: docs/cli.md].
- Model: `--model provider/id[:thinking]`, `--provider`, `--thinking` [V].
- Permissions: Pi "does not ask for approval before every tool call" [V: docs/security.md]: no approval prompts to skip, so fewer `blocked` states, and no safety net either. `--approve` trusts project-local config [V].
- Instructions: `--system-prompt <text|path>`, `--append-system-prompt <text|path>` (repeatable), AGENTS.md / CLAUDE.md context files, skills in `~/.agents/skills` [V].
- Resume: `--session <id>`, `--continue`, and `--session-id <id>` which *creates* a session with a caller-chosen ID [V]. Callers choosing the ID up front removes the "discover the session id" step.
- Guard: extensions get a `tool_call` event that "can mutate input or block execution"; a failing handler blocks the tool [V: docs/extensions.md].
- herdr: lifecycle authority via extension; #3853 (`launch_pending`), #4143 (dialogs reported working), #4463.
- Paid-API gotcha: `/login` handles OAuth subscriptions or API keys; env API keys are honored [V]. Same third-party-harness caution as opencode.

### 3.6 GitHub Copilot CLI (github/copilot-cli, proprietary) — the extra one

Chosen because it is subscription-based (no API keys) and herdr has a session integration for it.

- `-i "<prompt>"` interactive with first prompt, `-p` non-interactive, `--model`, `--allow-all-tools`, `--allow-all`/`--yolo`, `--resume`/`--continue` [S: docs.github.com search summaries]. herdr resumes with `copilot --resume=<id>` [V].
- Hooks: `preToolUse` with `toolName`/`toolArgs` input, deny via `{"permissionDecision":"deny","permissionDecisionReason":...}`; also `agentStop`, `sessionEnd`; config in `~/.copilot/hooks/` or `.github/hooks/*.json` [V: docs.github.com hooks reference]. Input shape differs from Claude (`toolArgs`, not `tool_input.command`), so the guard needs a small shim.
- herdr: screen manifest; #4329 (flips working/done with background agents).

### 3.7 aider (Aider-AI/aider, Apache-2.0) — poor fit

`--message` is one-shot and exits; `--yes-always`; `--read` for instruction files; `--restore-chat-history`; no hooks; auth is API keys only [V: aider.chat options]. Only local models satisfy the no-paid-API rule, and herdr does not detect it (no kind), so it would need a `report-agent` wrapper. Defer.

### 3.8 Summary table

| Agent | First prompt | Model | No-prompt mode | Instructions | Resume | Tool guard | herdr state | Paid-API risk |
|---|---|---|---|---|---|---|---|---|
| Claude Code | positional | `--model` | `--dangerously-skip-permissions` | CLAUDE.md, skills, `--append-system-prompt` | `--resume <id>` | PreToolUse (in use) | screen | strip `ANTHROPIC_API_KEY` (done today) |
| Codex | positional | `-m` | `--yolo` or `-a never -s workspace-write` | AGENTS.md, `-c developer_instructions` | `codex resume <id>` | PreToolUse, Claude-shaped | screen | strip `OPENAI_API_KEY`/`CODEX_API_KEY`, `-c forced_login_method=chatgpt` |
| Antigravity | `-i` [S] | `--model` [S] | `--dangerously-skip-permissions` | GEMINI.md/AGENTS.md | `--conversation <id>` | hooks, deny unverified | screen, unreliable | strip `GEMINI_API_KEY` [S] |
| opencode | `--prompt` | `--model p/m` | `--auto` / `permission: allow` | AGENTS.md, `instructions` | `--session <id>` | plugin throw | plugin | provider-dependent |
| Pi | positional | `--model` | none needed | `--append-system-prompt` | `--session-id` | extension `tool_call` | extension | provider-dependent |
| Copilot | `-i` [S] | `--model` [S] | `--allow-all` [S] | AGENTS.md etc. | `--resume=<id>` | preToolUse, own shape | screen | low (subscription) |
| Gemini CLI | excluded: consumer tiers retired 2026-06-18 | | | | | | | |
| aider | excluded for now: no detection, API keys | | | | | | | |

---

## 4. herdmaster today: neutral vs Claude-specific

### 4.1 Already provider-neutral (logic)

- `bin/herdmaster-board.sh`: jq board writer, settings, archive, legacy import. Only the state path is Claude-flavoured.
- `bin/herdmaster-viewer.py`: read-only viewer. Path only.
- `bin/herdmaster-layout.sh`: pure herdr pane/tab calls; takes an arbitrary command. Path only.
- `bin/herdmaster-labels.sh`: herdr metadata only.
- `hooks/pressure-check.sh`, `launchd/cpu-reaper/*`, `launchd/blocked-pane-watcher/*`: system and `herdr agent list` only; comments and default `HERDMASTER_HOME` mention Claude.
- `tests/*.test.sh`: fake herdr, no agent calls.

### 4.2 Claude-specific touchpoints (complete list from grep)

| File | Touchpoint |
|---|---|
| `skills/herdmaster/SKILL.md` | Claude skill format and `/herdmaster` entry; `ListAgents` for own name (l.21) and orchestrator liveness (l.22); orchestrator launch `env -u ANTHROPIC_API_KEY claude --model ... --dangerously-skip-permissions '/orchestrator <project>'` (l.23); "project CLAUDE.md" (l.25); `SendMessage` for briefs and forwarding (l.33, l.35); quota from the pane footer (l.47); requirement text "Claude Code" (l.19) |
| `skills/orchestrator/SKILL.md` | `ListAgents` (l.23); `SendMessage` + `notify_when_idle` one-shot subscriptions (l.24); `--resume <session-id>` (l.35, l.77); SendMessage to master (l.50); AskUserQuestion (l.53); launch shape with `--disallowedTools AskUserQuestion`, `--model`, `--dangerously-skip-permissions`, `--resume` (l.91-92); subagents in `~/.claude/agents/` and pane-footer quota (l.98); "project CLAUDE.md" (l.23) |
| `examples/worker-brief-template.md` | `claude -p` as the sanctioned headless tool (l.18); AskUserQuestion + SendMessage (l.22); report by SendMessage (l.24); `~/.claude/orchestrator/...` (l.23); `MODEL: haiku/sonnet/opus` (l.5) |
| `hooks/pressure-guard.sh` | Claude PreToolUse stdin (`tool_input.command`) and `hookSpecificOutput` output (l.2, l.27) |
| `agents/{lookup,worker,deep}.md` | Claude subagent format with `model: haiku/sonnet/opus` |
| `scripts/install.sh` | requires `claude` on PATH (l.28-32); installs skills to `~/.claude/skills`, agents to `~/.claude/agents`; merges PreToolUse hook into `~/.claude/settings.json` (l.88-107); forces `HERDMASTER_HOME` inside `~/.claude` (l.24) |
| `scripts/uninstall.sh` | mirror of the above (l.17-54) |
| State paths | `~/.claude/orchestrator/<project>` hard-coded in `bin/herdmaster-board.sh` (l.20, l.254), `bin/herdmaster-layout.sh` (l.22, l.45), `bin/herdmaster-viewer.py` (l.334), all tests; `$HOME/.claude/herdmaster` default in every hook and launchd script |
| `README.md`, `docs/install.md`, `docs/design/board.md`, `CHANGELOG.md` | "for Claude Code", Sonnet/Opus/Haiku routing, `/herdmaster`, `~/.claude` paths |
| `CONTRIBUTING.md` | "Never add anything that touches files outside `~/.claude`" (l.5): blocks installing into `~/.codex`, `~/.agents`, `~/.config/opencode` |

### 4.3 Things found while reading (not fixed, flagged)

- Launch-flag inconsistency: the orchestrator skill says every fleet pane "the orchestrator included" gets `--disallowedTools AskUserQuestion`, but the master skill's orchestrator launch (l.23) omits it. A zero-behavior-change refactor must pick one; recommend fixing it deliberately in a separate commit.
- Quoting: `herdmaster-layout.sh` runs `pane run "$pane" "HERDMASTER_ROLE=... $*"`, which re-joins the command words with spaces and loses the caller's quoting (a multi-word brief or `'/orchestrator <project>'` becomes several words in the pane shell). It may work today only because of how `claude` treats extra positional words [I, unverified]. The adapter should build the command with `printf '%q '` per argument; the existing test (`new-orchestrator claude hi`) does not cover multi-word arguments.

---

## 5. Architecture

### 5.1 Pieces

```
roles/                         one source of truth for role behavior (neutral markdown)
  planner.md  orchestrator.md  worker.md  transport-claude.md  transport-inbox.md
skills/*/SKILL.md              GENERATED for Claude = frontmatter + role + transport-claude
adapters/<agent>.sh            per-agent launch facts (sourced, no side effects)
bin/herdmaster-agent.sh        launch | resume | model | env | doctor, via adapters
bin/herdmaster-msg.sh          send | read | ack  (file inbox + doorbell)
bin/herdmaster-watch.sh        fleet watcher: herdr state -> orchestrator inbox
bin/herdmaster                 entry point for non-Claude planners: `herdmaster start --agent X`
guards/pressure-decide.sh      shared "is this command heavy under pressure?" logic
guards/shims/                  PATH shims for agents without usable hooks
```

### 5.2 Adapter interface [I]

One bash file per agent defining functions; `herdmaster-agent.sh` sources the selected one. Declarative enough to test with dry-run snapshots, no framework.

```
hm_kind                          # herdr --kind value, or "" if herdr cannot detect it
hm_argv ROLE TIER PROMPT_FILE [RESUME_ID]   # prints the argv, one arg per line
hm_env_unset                     # env vars to strip (API keys)
hm_model TIER                    # settings.models.<agent>.<tier>, else adapter default
hm_session_id PANE               # usually: herdr agent get PANE | jq .agent_session.value
hm_guard                         # hook | shim | none
hm_caps                          # e.g. "system_prompt=flag resume=id hooks=claude-shape"
```

Claude adapter output must reproduce today's strings exactly:

- worker: `env -u ANTHROPIC_API_KEY claude --disallowedTools AskUserQuestion --model "$M" --dangerously-skip-permissions [--resume ID] "<brief>"`
- orchestrator: the string in `skills/herdmaster/SKILL.md` l.23, unchanged in phase 1.

Codex adapter sketch: `env -u OPENAI_API_KEY -u CODEX_API_KEY codex -c forced_login_method=chatgpt -c developer_instructions=<role text> -m "$M" --yolo "<bootstrap prompt>"`; resume: `codex resume <id>`.

`herdmaster-agent.sh launch` always goes through `herdmaster-layout.sh`, so layout, labels and `HERDMASTER_ROLE` stay in one place. It tries `herdr agent start <name> --kind K` only when the pane is a fresh shell and falls back to `pane run` + poll `agent get` + `agent rename` on `timeout`/`launch_pending` (#3385, #3853).

### 5.3 Role prompts: one source of truth [I]

- Move the behavioral text of both skills into `roles/*.md`. Transport-specific sentences ("SendMessage the orchestrator", "notify_when_idle") move into `transport-claude.md`; the neutral equivalents ("run `herdmaster-msg send orchestrator ...`") go in `transport-inbox.md`.
- `scripts/build-skills.sh` concatenates frontmatter + role + transport into `skills/*/SKILL.md`. Commit the generated files; a test fails if they drift from the sources. Phase 1 acceptance: generated SKILL.md files are byte-identical to today's.
- Delivery to non-Claude agents, in order of preference:
  1. A system-prompt flag where it exists (Pi `--append-system-prompt <path>`, Codex `-c developer_instructions=...`).
  2. Otherwise a short bootstrap first prompt: "You are the herdmaster <role> for project P. Read <path>/roles/<role>.md and follow it. Re-read it after any context compaction."
- Do not rely on skill auto-discovery (`~/.agents/skills` works for Codex, opencode and Pi, but invocation differs per agent and it would install outside `~/.claude`).

### 5.4 Transport

**Inbox (durable).** `<state>/<project>/inbox/<role-or-task>.jsonl`, append-only lines `{id, ts, from, to, task, kind, body}`. `herdmaster-msg send` appends under a lock (`mkdir` lock; macOS has no `flock` CLI), `read` prints unread entries, `ack` records the last id read. Message bodies never travel as keystrokes.

**Doorbell (best effort).** After appending, `send` rings the recipient with a fixed short string ("herdmaster: new message, run herdmaster-msg read") via `herdr agent prompt`, but only if `herdr agent get` says `idle`, `done` or `working` right before. Never on `blocked` or `unknown` (#4641). Accept the small check-then-send race; the message is on disk either way. The planner is never rung (see 5.6).

**Reports (truth for "done").** Workers write `<state>/<project>/reports/T-003.md` ending with one status line: `STATUS: FULLY DONE | NEEDS DECISION | BLOCKED | FAILED`, then `herdmaster-msg send orchestrator --task T-003 report`. This also settles the board design's open question "where a planner message waits so it is never lost": in the inbox.

**Claude pairs.** In phase 1 Claude panes keep SendMessage/ListAgents exactly as today. From phase 2 a Claude orchestrator also reads the inbox (needed for non-Claude workers). Whether Claude should drop SendMessage entirely for one code path is an owner decision (section 8).

### 5.5 How the orchestrator learns a worker finished

`herdmaster-watch.sh` runs as a plain process in a small pane next to the orchestrator (visible, dies with the session, no launchd per project). Loop every 15 s [I]:

1. `herdr agent list` (polling is the truth; optional `events.subscribe` only to wake early).
2. For each worker pane on the board: on a transition to `idle`/`done` with a report file present, send `worker-finished T#` to the orchestrator inbox. Without a report, send one nudge prompt to the worker ("write your report file"), then after one more idle cycle send `worker-idle-no-report T#`.
3. On `blocked`, send `worker-blocked T#` plus the last 40 lines of `agent read`.
4. On `working` for longer than a threshold with an unchanged screen, send `worker-stalled T#`.
5. On pane or agent gone, send `worker-exited T#` with the session id from the last `agent_session.value`.

The orchestrator never sits in `agent wait`; it reacts to inbox messages (rung by the doorbell), which works for any agent. For a Claude orchestrator this replaces the one-shot `notify_when_idle` re-arming for non-Claude workers only.

### 5.6 Planner (master) conversation with a non-Claude planner

- The owner runs `herdmaster start [--agent codex]` from a shell in the project. It checks dependencies, writes the master file (herdr agent name and pane id instead of a Claude session name), labels the pane, launches the orchestrator pane and watcher through the adapter, then `exec`s the planner agent in the current pane with the planner role.
- Planner to orchestrator: `herdmaster-msg send orchestrator` for briefs, answers and owner commands.
- Orchestrator to planner (blocking decisions only): written to the planner inbox. The planner is **not** rung by typing into its pane, because the owner may be typing there (a doorbell would merge with their half-typed text). Instead: a workspace metadata token (`inbox=1`, like the existing labels script), `herdr notification`, and the planner role runs `herdmaster-msg read planner` at the start of every reply, right next to the existing `herdmaster-board.sh count` step.
- Identity guard: same `HERDMASTER_ROLE` check, done by `herdmaster start` instead of the skill.

### 5.7 Owner commands

Unchanged grammar (`approve|reject D#|T#`, `pause`, `stop`, `done early`, `<release word> T# [when done]`). The planner forwards them verbatim with `herdmaster-msg send orchestrator --kind command "<text>"`; `send` validates the grammar with one regex and rejects typos before they reach the orchestrator. Owners may also run `herdmaster cmd approve D3` from any shell, which writes the same inbox entry. Only the orchestrator writes the board, as today.

### 5.8 Model routing across providers

- Keep the three tiers as the neutral vocabulary: `light`, `default`, `deep`.
- `settings.json`: `agent` (default `claude`), optional `agent_orchestrator`, `agent_worker`, `agent_planner`; `models.<agent>.{light,default,deep}`. Precedence as for layout keys: settings, then env (`HERDMASTER_MODEL_*` stays the Claude default for backward compatibility), then adapter default.
- Brief template: `MODEL:` becomes `TIER:` plus optional `AGENT:`; the orchestrator resolves the concrete model through `herdmaster-agent.sh model`.
- In-session subagents (`~/.claude/agents/*.md`) stay Claude-only. Other agents get the tier only at launch.
- Quota pacing: Claude keeps pane-footer reading. For others, an optional `hm_usage` adapter function; absent means "unknown", and the orchestrator applies the conservative rule (keep deep-tier panes to a minimum) without a percentage.

### 5.9 Guard rails without PreToolUse

Split `pressure-guard.sh` into `guards/pressure-decide.sh <command>` (exit 0 allow, exit 75 deny with the message) and thin front ends:

| Front end | Agents | Mechanism |
|---|---|---|
| Claude-shape hook | Claude (today), Codex (same stdin/stdout shape [V], needs one-time hook trust) | existing script, unchanged |
| Other hook shapes | Copilot (`toolArgs`), Antigravity (unverified), opencode (JS plugin), Pi (TS extension) | 10-30 line adapters calling `pressure-decide.sh` |
| PATH shims (floor for everyone) | any agent, including ones with no hooks | worker panes get `PATH=$HERDMASTER_HOME/shims:$PATH`; shims for `npm`, `npx`, `docker`, `cargo`, `gradle`, `xcodebuild`, `vitest`, `playwright`, `next` call `pressure-decide.sh`, then `exec` the next binary on PATH |
| Admission control | all | orchestrator does not launch new workers while `pressure.json` is high (new rule in the neutral role) |

Ceiling of the shim: bypassed by absolute paths, `command -p`, or agent sandboxes that rebuild PATH; upgrade path is the native hook per adapter. The no-modal rule (`--disallowedTools AskUserQuestion`) has no general equivalent: for others it is the permission mode plus the role text, with the watcher's `blocked` detection as the backstop.

### 5.10 State location

Keep `~/.claude/orchestrator/<project>` and `~/.claude/herdmaster` as defaults (zero change) but read them from one place: new `HERDMASTER_STATE` (default `~/.claude/orchestrator`) used by board, layout, viewer, msg and watch. Installing for a non-Claude-only user creates `~/.claude` if missing, which is odd but harmless; moving to `~/.herdmaster` is an owner decision (section 8).

### 5.11 Failure modes

| Failure | Detection | Handling |
|---|---|---|
| Doorbell typed into a dialog | state checked just before, only idle/done/working | body is on disk; worst case a short fixed string lands in a composer. Residual race documented |
| Worker idle, no report (crash, context exhausted, just stopped) | watcher | one nudge, then `worker-idle-no-report` to orchestrator, which reads the pane and resumes or relaunches |
| State misreported (#3530, #4557, #4322) | report file vs state disagree; stall threshold | report file wins; stalled `working` triggers a pane read, not an action |
| Wait never wakes (#4473, #4280) | n/a | no unbounded waits anywhere; polling loop with timeouts |
| Events stall or drop (#3124, #4178) | n/a | events never the only signal |
| `agent start` never registers (#3385, #3853) | start timeout | fall back to `pane run` + `agent rename` |
| Prompt not submitted (#2422) | no `working` within 5 s | one `send-keys enter`, then pane read and escalate; never blind re-send |
| Paid API used by accident | `doctor` checks env and login state | adapter strips known key vars; Codex `-c forced_login_method=chatgpt`; `doctor` refuses to launch when a key var is set and the agent has no login |
| Agent name collision or >32 chars | `agent rename` error | names `hm-<project8>-<role|t#>`, truncated, deterministic |
| Orchestrator down | inbox grows, doorbell has no target | messages wait on disk; planner's start-of-turn check reports "orchestrator not live" |
| Concurrent inbox writers | lock | `mkdir` lock with stale-lock timeout |
| Role drift after compaction | behavior | role text says to re-read the role file; the file path is in the bootstrap prompt |
| Worktree trust prompts (Codex, Antigravity) | `blocked`, or misreported idle | owner pre-trusts; doorbell never rings on unknown/blocked; watcher escalates |

### 5.12 What stays Claude-only (document it honestly)

A "Support matrix" section in the README, stating plainly:

- `/herdmaster` and `/orchestrator` slash entry points, SendMessage/ListAgents live messaging, and `notify_when_idle` are Claude Code features. Other agents use `herdmaster start` and the file inbox, which is slower (polling interval) and depends on herdr's state detection for that agent.
- Pinned-model subagents (`agents/*.md`) and pane-footer quota pacing are Claude-only.
- The PreToolUse pressure guard is exact only for Claude and Codex; for other agents it is the PATH shim (bypassable) unless that adapter ships a native hook.
- The "no modal prompt" rule is enforced by flag only for Claude.
- Per agent, list the herdr issues that affect it and "tested with herdr X / agent Y" versions.
- Gemini CLI is not supported (consumer tiers retired); aider is not supported (no herdr detection, API-key only).

---

## 6. Phased plan

### Phase 1: adapter interface + Claude adapter, zero behavior change

Add:
- `adapters/claude.sh`, `bin/herdmaster-agent.sh` (`argv`, `model`, `env`, `launch --dry-run`)
- `roles/{planner,orchestrator,worker}.md`, `roles/transport-claude.md`, `scripts/build-skills.sh`
- `HERDMASTER_STATE` read in one small shared snippet (or duplicated one-liner) in board, layout, viewer
- `tests/agent.test.sh`: Claude argv snapshots for worker, worker + resume, orchestrator; argument with spaces and quotes round-trips through `printf '%q'`
- `tests/skills.test.sh`: regenerated SKILL.md files equal the committed ones

Change:
- `bin/herdmaster-layout.sh`: accept an already-quoted command from `herdmaster-agent.sh` (keep the old form working)
- skills: only if byte-identical after generation; otherwise the generator reproduces them exactly
- `scripts/install.sh`/`uninstall.sh`: install `adapters/` and `herdmaster-agent.sh`

Effort: 2-3 days. Risks: accidental wording drift in skills (mitigated by the byte-equality test); the quoting fix changes behavior if the current joined form was relied on (keep old path, add new).

### Phase 2: one second agent, as workers only (Claude planner and orchestrator stay)

Choice: **Codex CLI**. Reasons: subscription login with an explicit way to force it; PreToolUse hook with Claude's exact stdin/stdout shape, so the pressure guard is reused rather than rewritten; `developer_instructions` for role injection; AGENTS.md native; herdr session integration and a first-class `--kind codex`; Apache-2.0 and the largest user base of the candidates. Runner-up: Pi (no approval prompts, caller-chosen session ids, system-prompt flag, lifecycle-authority integration) — pick Pi instead if the owner does not have a ChatGPT plan.

Add:
- `adapters/codex.sh`
- `bin/herdmaster-msg.sh`, `bin/herdmaster-watch.sh`
- `roles/transport-inbox.md`; worker brief template gains the report-file and `herdmaster-msg` lines for non-Claude workers
- `bin/herdmaster-agent.sh doctor` (binary present, login state, key vars unset, hook trusted)
- settings keys `agent_worker`, `models.<agent>.*` in `herdmaster-board.sh settings`
- tests: codex argv snapshot; env stripping; `herdmaster-msg` send/read/ack with concurrent appends; doorbell skipped on blocked/unknown (fake herdr); watcher transition table (idle+report, idle-no-report, blocked, exited) with fake `agent list` sequences; pressure-guard fed a Codex-shaped fixture

Change: orchestrator role (read inbox on doorbell; launch workers via `herdmaster-agent.sh`); `install.sh` (optional Codex hook install into `~/.codex/hooks.json`, backed up, opt-in flag, prints the manual trust step).

Effort: 4-6 days plus one supervised live run by the owner. Risks: #3385 start registration and #4343/#4641 trust prompts in fresh worktrees; hook trust being interactive; Codex state misreports (#4322, #4647) causing false `blocked` escalations; installing outside `~/.claude` conflicts with CONTRIBUTING.

### Phase 3: the rest

1. Non-Claude orchestrator (inbox-only transport, watcher already exists): 3-4 days.
2. Non-Claude planner via `herdmaster start`, inbox token + notification, start-of-reply inbox check: 2-3 days.
3. Adapters: Pi (1-2 days, extension guard), opencode (2 days, plugin guard, v1/v2 split), Copilot (1-2 days, hook shim), Antigravity (2 days, flags only from secondary sources, state unreliable): each with argv snapshot tests and a doctor check.
4. PATH shims + admission control: 1 day.
5. README support matrix, install docs, CHANGELOG.

Risks: herdr state quality differs a lot per agent, so the per-agent "tested with" table will age; third-party-harness subscription policies change (Anthropic changed enforcement several times in 2026); Antigravity data needs primary-source verification first.

---

## 7. Test strategy (all phases)

No test may launch a real agent or call any API. Everything runs against the existing fake-`herdr` pattern (`HERDMASTER_HERDR`) and fake agent binaries that print their argv. Live verification is a manual checklist the owner runs.

---

## 8. Decisions for the owner

1. **Second agent for phase 2.** Recommend Codex; Pi if no ChatGPT plan.
2. **Keep SendMessage for Claude pairs, or move Claude to the inbox too.** Recommend keep in phases 1-2 (zero change, faster signals), revisit after phase 3 when the inbox is proven.
3. **State directory.** Recommend keep `~/.claude/orchestrator` with a `HERDMASTER_STATE` override; move to `~/.herdmaster` only with a one-time migration if non-Claude users object.
4. **CONTRIBUTING "only touch ~/.claude" rule.** Recommend relaxing it to "only touch `~/.claude`, `com.herdmaster.*` LaunchAgents, and opt-in, backed-up hook entries in a supported agent's own config directory".
5. **Role delivery.** Recommend system-prompt flag where available, bootstrap first prompt otherwise; no skill auto-discovery.
6. **Guard floor.** Recommend PATH shims for all non-Claude workers plus native hooks where the shape is known (Codex first).
7. **Unify the orchestrator launch flags** (the `--disallowedTools AskUserQuestion` mismatch). Recommend adding it to the master's orchestrator launch in a separate, labelled commit, not in the zero-change refactor.
8. **Mixed fleets.** Recommend supporting per-role agents (`agent_worker` etc.) from phase 2; a single `agent` key alone would force the riskiest step (non-Claude orchestrator) first.

---

## Sources

- herdr docs index: https://herdr.dev/llms.txt; pages under https://raw.githubusercontent.com/herdrdev/herdr/v0.9.1/docs/next/website/src/content/docs/ (`agents.mdx`, `integrations.mdx`, `agent-automation.mdx`, `socket-api.mdx`, `plugins.mdx`, `session-state.mdx`); local `herdr --skill`, `herdr agent|pane|integration --help` (0.9.0)
- herdr issues: #2422, #2868, #3124, #3313, #3385, #3419, #3530, #3652, #3853, #3871, #4027, #4052, #4143, #4178, #4280, #4322, #4329, #4343, #4463, #4473, #4511, #4557, #4573, #4641, #4647, #4668 (github.com/herdrdev/herdr/issues)
- Codex: https://learn.chatgpt.com/docs/developer-commands?surface=cli, https://learn.chatgpt.com/docs/hooks, https://learn.chatgpt.com/docs/config-file/config-reference, https://learn.chatgpt.com/docs/build-skills, https://github.com/openai/codex/issues/46914, AGENTS.md discovery: https://fossies.org/linux/codex-rust/docs/agents_md.md
- Gemini CLI: https://raw.githubusercontent.com/google-gemini/gemini-cli/main/docs/cli/cli-reference.md, https://raw.githubusercontent.com/google-gemini/gemini-cli/main/docs/hooks/reference.md, https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/
- Antigravity CLI: https://antigravity.google/docs/cli/using/ (primary, partial), https://computingforgeeks.com/antigravity-cli-cheat-sheet/ (secondary)
- opencode: https://opencode.ai/docs/cli/, /permissions/, /plugins/, /rules/, /skills/
- Pi: https://github.com/earendil-works/pi (packages/coding-agent/docs: cli.md, security.md, providers.md, skills.md, extensions.md)
- Copilot CLI: https://docs.github.com/en/copilot/reference/hooks-reference, https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools, https://github.com/github/copilot-cli/issues/3874
- aider: https://aider.chat/docs/config/options.html
- Anthropic third-party subscription policy (secondary, changing): https://alternativeto.net/news/2026/2/anthropic-officially-bans-using-subscription-authentication-for-third-party-claude-use, https://news.ycombinator.com/item?id=46549823
