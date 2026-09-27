# Install

## 1. Prerequisites

- macOS with Claude Code, `jq` and `python3`.
- herdr: install it from its project page, then confirm `herdr status` works.

## 2. Preview and install

```sh
scripts/install.sh --dry-run
scripts/install.sh [--with-watcher] [--force]
```

What it does, and only this:

1. Copies helper scripts to `$HERDMASTER_HOME/bin` (default `~/.claude/herdmaster`; must live inside `~/.claude`).
2. Copies the `herdmaster` (master window) and `orchestrator` skills to `~/.claude/skills/`. Existing skills are skipped unless `--force`.
3. Copies the `lookup`, `worker` and `deep` subagents to `~/.claude/agents/`. Existing agents are skipped unless `--force`.
4. Renders `com.herdmaster.*` LaunchAgent plists from `launchd/*/*.plist.tmpl` (placeholders `__HOME__` and `__HERDMASTER_HOME__` are substituted) into `~/Library/LaunchAgents` and loads them. `pressure-check`, `cpu-reaper` and the board `viewer` (a small local web server on 127.0.0.1, port 8766 unless `HERDMASTER_VIEWER_PORT` is set at install time, restarted automatically if it stops) by default; the example blocked-pane watcher only with `--with-watcher`.
5. Merges the PreToolUse hook into `~/.claude/settings.json` with `jq`. It backs the file up first (`settings.json.herdmaster-backup-<timestamp>`), appends to existing `hooks.PreToolUse` without removing anything, skips if already present (idempotent), and refuses if the file is not valid JSON.

## 3. Configure (optional environment variables)

| variable | default | meaning |
|---|---|---|
| `HERDMASTER_HOME` | `~/.claude/herdmaster` | helper scripts, state, logs |
| `HERDMASTER_HEAVY_REGEX` | dev servers, test runners, docker run/up, builds | commands the guard denies under pressure |
| `HERDMASTER_HIGH_LOAD` / `HERDMASTER_CRIT_LOAD` | 16 / 24 | load thresholds |
| `HERDMASTER_REAP_NAMES` | `chrome-headless-shell` | exact process names cpu-reaper may kill when orphaned |
| `HERDMASTER_IGNORE_PRESSURE` | unset | emergency override for the guard; do not set it in normal use |
| `HERDMASTER_MODEL_DEFAULT` / `_DEEP` / `_LIGHT` | your choice | model IDs the skills refer to (default = Sonnet, deep = Opus, light = Haiku) |
| `HERDMASTER_PROJECT` | unset | project name; the board lives at `~/.claude/orchestrator/<project>/tasks.json` (`herdmaster-board.sh`) |
| `HERDMASTER_WORKER_LAYOUT` | `tab` | `tab` puts workers in a grid on a workers tab; `main` keeps them on the current tab (`herdmaster-layout.sh`) |
| `HERDMASTER_GRID_PANES` | 6 | panes per workers-tab grid; overflow opens another workers tab |
| `HERDMASTER_MAX_PANES` | 4 | total panes on the current tab when layout is `main`; beyond that workers go to a workers tab |

Per-project keys in `~/.claude/orchestrator/<project>/settings.json` (set with `herdmaster-board.sh settings set <key> <value>`):

| key | values | meaning |
|---|---|---|
| `release` | `merge`, `deploy`, `push`, `ship` | word for the final step |
| `grid_panes`, `max_panes` | positive integer | override the env vars above |
| `worker_layout` | `tab`, `main` | overrides `HERDMASTER_WORKER_LAYOUT` |
| `herdr_workspace` | herdr workspace id | recorded by `new-orchestrator`; lets the viewer follow the focused workspace (toggle "Follow herdr" in its settings cog) |

## 4. Use

In your project's repo, run `/herdmaster`. Workers are briefed from `examples/worker-brief-template.md`.

Optional board viewer: `python3 "$HERDMASTER_HOME/bin/herdmaster-viewer.py" --project <name>` serves a read-only page at `http://127.0.0.1:8765/` (change with `HERDMASTER_VIEWER_PORT`). It binds localhost only, answers GET only, and polls `tasks.json` every 3s.

## Uninstall

```sh
scripts/uninstall.sh --dry-run
scripts/uninstall.sh [--keep-skills]
```

Removes the `com.herdmaster.*` LaunchAgents, the helper scripts, the two skills, the three agents (only if unmodified) and the pressure-guard hook entry (other hooks stay; the file is backed up first). State and logs in `$HERDMASTER_HOME` are kept.
