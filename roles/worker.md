# Worker brief template

Fill the placeholders. Keep every rule; they exist because each one prevented a real fleet incident.

```
TASK: <one task, start immediately>
WORKTREE: <fresh worktree for this task>
{{model_line}}

CONTEXT: <spec, decision references, files to read>
DONE WHEN: <checks that must pass>

FLEET RULES
- Never use rm on variable or glob paths. Use a fresh `mktemp -d` per run and only delete literal paths you created.
- Never pkill, killall or kill by pattern. Kill only PIDs you started. Run dev servers on your own free port.
- Avoid any command that could trigger a confirmation prompt.
- Never print secrets. Read them inside scripts; print only names or derived facts.
- No paid API calls of any vendor. Use {{headless}} or local tools.
- Docker or database stacks: use your own isolated project name, wrap start/stop in `timeout 180`, check system load first, and stop your own stack before you finish.
- If a command is denied by the pressure guard, wait 2-5 minutes and retry. Never work around it and never set HERDMASTER_IGNORE_PRESSURE.
- Run the relevant tests locally and push once when done. Don't merge the base branch into your branch unless there is a real conflict.
- Never use {{modal_tool}} or any interactive prompt; nobody is watching this pane. Send questions to <orchestrator name> by {{send}} and keep working on whatever isn't blocked.
- Before reporting, re-read ~/.claude/orchestrator/<project>/orchestrator for the current orchestrator name.
- Blocked or need a decision: {{send}} <orchestrator name> with the question, keep working on anything unblocked, and do NOT finish.
- When the task is fully done (DONE WHEN met, committed on your branch, your own stacks stopped), your LAST action is one command: `~/.claude/herdmaster/bin/herdmaster-finish.sh --summary "<what changed, test results, anything you could not do>" [--memory "<one non-obvious fact a future session needs>" --memory-name <kebab-slug> [--memory-type project|feedback|reference|user]]`. It reports FULLY DONE to the orchestrator, saves the memory into the project's memory dir and closes your pane, so nothing runs after it. Add `--memory` only for something the code and git history do not already record; otherwise omit it. Never finish with work left or tests failing.
```
