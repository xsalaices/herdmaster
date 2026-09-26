# Changelog

## Unreleased

- Skills: the orchestrator keeps a `tasks.json` board (replacing `design-queue.md` and `decisions.md`) with review modes, a rejection flow and deploy-ready rules; the planner shows a board count line and refuses to run in a fleet pane.
- README: documents the board, the pane layout and pane identity.
- The master skill is now invoked as `/herdmaster` (the state file and role are still called `master`).
- Model routing: `lookup` (Haiku), `worker` (Sonnet), `deep` (Opus) subagents in `agents/` with install and uninstall support, quota rules in both skills, model line in the worker brief template.

## 0.1.0

- Initial release: master and orchestrator skills, pressure check and PreToolUse guard, cpu-reaper, example blocked-pane watcher, install and uninstall scripts, worker brief template.
