Status: draft, not implemented

# Design draft: herdmaster as a herdr plugin

Sources: herdr docs v0.9.1 (`plugins.mdx`, `marketplace.mdx`, index at https://herdr.dev/llms.txt), herdr's CONTRIBUTING.md, `herdr plugin --help` on herdr 0.9.0. Sections are cited by heading name.

## 1. Scope

A plugin packages the parts of herdmaster that are plain commands: board read, worker-grid rebalance, a board pane. The planner and orchestrator remain Claude Code sessions launched by the skills; a plugin cannot supervise them (see section 3).

## 2. Shape of the plugin

Draft manifest: `plugin/herdr-plugin.toml`. Fields follow the "Manifest" section.

| Piece | Draft | Notes |
|---|---|---|
| Manifest | `id`, `name`, `version`, `min_herdr_version` (required), `description`, `platforms` | `min_herdr_version = 0.9.0` is the version this was checked against; herdr refuses install or link on an older binary ("Manifest"). |
| Actions | `rebalance`, `board`, context `workspace` | Invoked by `herdr plugin action invoke herdmaster.<id>` or a key bound in "Keybindings" (`type = "plugin_action"`). Only the `workspace` context appears in the docs; other context names are unverified. |
| Panes | `board`, placement `split` | Terminal pane that prints `herdmaster-board.sh show`. "Panes" lists placements `overlay`, `popup`, `split`, `tab`, `zoomed`. |
| Event hooks | none in the draft | "Manifest" documents only `worktree.created` as an example event; the full event list is not in the docs. Add hooks only after confirming names (source or `herdr` release notes). Candidate: relabel the workspace when a worktree is created. |
| Startup hooks, build commands, link handlers | none | Not needed: no build step, no daemon (startup hooks are one-shot per "Startup hooks"). |

Open issues in the draft:

- `command` is an argv array with no shell expansion ("Manifest"). The docs do not state the working directory, so `bin/...` relative paths assume cwd is the plugin root. Unverified. If wrong, switch to `["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/bin/herdmaster-board.sh\" show"]`, since `HERDR_PLUGIN_ROOT` is documented in "Commands and environment".
- The scripts live in this repo's `bin/`, not under `plugin/`. `herdr plugin install owner/repo/subdir` installs only the subdirectory, so either the plugin dir must contain the scripts (copy or symlink at release time) or the plugin lives at the repo root. Decide before publishing.
- The scripts need `HERDMASTER_PROJECT`. The plugin can read it from `HERDR_PLUGIN_CONFIG_DIR` ("Storage": plugins own their file formats); a small wrapper would source it.
- Scripts depend on `bash`, `jq`, `python3`. The manifest is limited to linux and macos; Windows is not supported.

## 3. What it can and cannot do

Can:

- Run commands on demand (actions) and on herdr events (event hooks), as the user, with the herdr socket and `HERDR_BIN_PATH` in env, so it can call the same `herdr pane`, `herdr workspace` commands the scripts already use ("Commands and environment").
- Open a terminal pane in a chosen placement ("Panes").
- Bind actions to keys and to Control+click on URLs ("Keybindings", "Link handlers").

Cannot:

- Native non-terminal plugin UI: "Limitations" states runtime action registration and native non-terminal plugin UI are not part of plugin v1. The web board viewer (`bin/herdmaster-viewer.py`) therefore stays a separate launchd service; a plugin pane can only print text or run a TUI.
- Run supervised daemons: startup hooks are one-shot.
- Store data via herdr: no plugin storage API in v1 ("Storage"); the board stays in `~/.claude/orchestrator/<project>/`.
- Sandbox: plugins run with full user access ("Trust and security"). Anything the scripts touch is already in scope, but this is why the README must state what the plugin does.
- Popups: no pane id, no lifecycle events, `ui_busy` while a modal is active ("Panes"), so prefer `split` or `overlay`.

## 4. Install and uninstall

Development: `herdr plugin link <path-to-plugin>` (no build run; `unlink` leaves files alone). Users: `herdr plugin install <owner>/<repo>[/<subdir>] [--ref REF] [--yes]` ("Install and link"), which previews the manifest and aborts if it changes after the preview. `herdr plugin uninstall <id-or-source>` removes the checkout and registration. Config dir: `herdr plugin config-dir herdmaster`.

The plugin does not replace `docs/install.md`: the skills, agents, hooks and launchd services remain installed by the existing scripts, and the plugin must not write outside `~/.claude` or `com.herdmaster.*` (CONTRIBUTING). Uninstalling the plugin leaves those alone.

## 5. Validation

`herdr plugin --help` (0.9.0) lists install, uninstall, link, unlink, enable, disable, list, config-dir, action, log, pane. There is no validate or dry-run subcommand; validation happens only as a side effect of `link` or `install`, which this task does not run. Substitute: parse the manifest with `tomllib` and check it against the "Manifest" rules (required fields, id character sets, unique ids per type, argv arrays, placement values). The draft passes that check. Before release, run `herdr plugin link` in a scratch herdr and `herdr plugin action list --plugin herdmaster`.

## 6. Marketplace

Per "Marketplace" (`marketplace.mdx`): no review and no application. Requirements:

1. Public GitHub repo, not a fork, not archived.
2. GitHub topic `herdr-plugin`.
3. Valid `herdr-plugin.toml` on the default branch (root or a subdirectory); the index records path, `id`, `name`, `version`, `platforms`, `min_herdr_version` and the commit. The index refreshes about every 30 minutes.

The card shows description, stars, language and last push, so the repo needs a real description and README. Nothing has been submitted.

## 7. Repository path

herdr's CONTRIBUTING says unsolicited pull requests are closed automatically, so nothing here goes to the herdr repo. The plugin ships from a separate repo (or this one, if the manifest sits at its root or `plugin/` with the scripts inside it), discovered through the topic above.

## 8. Next steps

1. Decide repo layout (section 2, second open issue).
2. Confirm working directory and context names against a scratch herdr via `link`.
3. Confirm the event list, then add hooks.
4. Add `HERDMASTER_PROJECT` config handling.
