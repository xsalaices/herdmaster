# Changelog

## Unreleased

- The master skill is now invoked as `/herdmaster` (the state file and role are still called `master`).
- Model routing: `lookup` (Haiku), `worker` (Sonnet), `deep` (Opus) subagents in `agents/` with install and uninstall support, quota rules in both skills, model line in the worker brief template.

## 0.1.0

- Initial release: master and orchestrator skills, pressure check and PreToolUse guard, cpu-reaper, example blocked-pane watcher, install and uninstall scripts, worker brief template.
