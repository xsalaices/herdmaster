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
2. Copies the `master` and `orchestrator` skills to `~/.claude/skills/`. Existing skills are skipped unless `--force`.
3. Renders `com.herdmaster.*` LaunchAgent plists from `launchd/*/*.plist.tmpl` (placeholders `__HOME__` and `__HERDMASTER_HOME__` are substituted) into `~/Library/LaunchAgents` and loads them. `pressure-check` and `cpu-reaper` by default; the example blocked-pane watcher only with `--with-watcher`.
4. Merges the PreToolUse hook into `~/.claude/settings.json` with `jq`. It backs the file up first (`settings.json.herdmaster-backup-<timestamp>`), appends to existing `hooks.PreToolUse` without removing anything, skips if already present (idempotent), and refuses if the file is not valid JSON.

## 3. Configure (optional environment variables)

| variable | default | meaning |
|---|---|---|
| `HERDMASTER_HOME` | `~/.claude/herdmaster` | helper scripts, state, logs |
| `HERDMASTER_HEAVY_REGEX` | dev servers, test runners, docker run/up, builds | commands the guard denies under pressure |
| `HERDMASTER_HIGH_LOAD` / `HERDMASTER_CRIT_LOAD` | 16 / 24 | load thresholds |
| `HERDMASTER_REAP_NAMES` | `chrome-headless-shell` | exact process names cpu-reaper may kill when orphaned |
| `HERDMASTER_IGNORE_PRESSURE` | unset | emergency override for the guard; do not set it in normal use |
| `HERDMASTER_MODEL_DEFAULT` / `_DEEP` / `_LIGHT` | your choice | model IDs the skills refer to |

## 4. Use

In your project's repo, run `/master`. Workers are briefed from `examples/worker-brief-template.md`.

## Uninstall

```sh
scripts/uninstall.sh --dry-run
scripts/uninstall.sh [--keep-skills]
```

Removes the `com.herdmaster.*` LaunchAgents, the helper scripts, the two skills and the pressure-guard hook entry (other hooks stay; the file is backed up first). State and logs in `$HERDMASTER_HOME` are kept.
