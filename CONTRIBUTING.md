# Contributing

- Keep everything generic: no project names, personal paths, accounts or ids. Use `<project>`, `$HOME` and `$HERDMASTER_HOME`.
- Shell scripts must pass `shellcheck` and support `--dry-run` where they change the system.
- Never add anything that touches files outside `~/.claude` or `com.herdmaster.*` LaunchAgents.
- Before opening a PR, grep your diff for paths, emails, tokens and pane ids.
- Small commits, one change each.
