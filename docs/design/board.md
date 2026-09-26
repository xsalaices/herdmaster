# Board design

Goal: finished worker results reach the planner without interrupting planning.

The planner window receives only blocking design decisions plus a one-line queued-results count. Failed, stuck and finished work goes to the orchestrator only.

Scope: design only. Skill wording changes, the viewer and any native app are separate efforts.

## Board file

| Item | Rule |
|---|---|
| Path | `~/.claude/orchestrator/<project>/tasks.json` |
| Writer | The orchestrator only |
| Writes | Atomic: write a temp file, then `mv` over `tasks.json` |
| Readers | Viewers, read-only |
| Planner input | The planner sends new tasks, user answers, rejections and approvals to the orchestrator by message |
| Replaces | `design-queue.md` and `decisions.md`; `status.md` stays as the running log |

## Schema

Top level: `schema_version` and `entries[]`. Viewers ignore unknown fields.

| Field | Meaning |
|---|---|
| `id` | `T-014` for tasks, `D-007` for decisions |
| `kind` | `task` or `decision` |
| `title` | Short label |
| `status` | See lifecycles below |
| `review` | `auto` or `user` |
| `depends_on` | List of entry ids |
| `note` | Optional one or two lines of context shown under the title |
| `recommend` | Optional, for decisions: the planner's recommended answer and why |
| `attempts[]` | Each: `status`, `feedback`, PR or pane link |
| `created`, `updated` | ISO 8601 timestamps |

```json
{
  "schema_version": 1,
  "entries": [
    {
      "id": "T-014",
      "kind": "task",
      "title": "Add settings page",
      "status": "in review",
      "review": "user",
      "depends_on": ["D-007"],
      "attempts": [
        { "status": "rejected", "feedback": "Spacing too tight", "link": "pr/41" },
        { "status": "finished", "feedback": null, "link": "pr/43" }
      ],
      "created": "2025-01-10T09:00:00Z",
      "updated": "2025-01-10T12:30:00Z"
    },
    {
      "id": "D-007",
      "kind": "decision",
      "title": "Sidebar or top nav",
      "status": "settled",
      "review": "user",
      "depends_on": [],
      "attempts": [],
      "created": "2025-01-09T15:00:00Z",
      "updated": "2025-01-09T16:10:00Z"
    }
  ]
}
```

## Lifecycles

Tasks: `working` -> `finished` -> `in review` -> `approved` -> `deploy-ready`. `blocked` and `failed` are side states.

Decisions: `open` -> `settled` or `superseded`. A superseded decision flags every task that depends on it. Open decisions never expire and never disappear. There are no repeated pings.

## Review mode

| Mode | Applies to |
|---|---|
| `review:user` | UI, website design, design decisions |
| `review:auto` | Routine work and architecture; the orchestrator verifies |

Architecture that changes product behavior, scope or cost is a design decision, so it is `review:user`. Workers never wait on a review.

## Rejection

1. The user tells the planner.
2. The planner forwards it to the orchestrator.
3. The task returns to `working` with the feedback appended to a new attempt.
4. Unapproved work is not merged.
5. The rejected attempt stays in `attempts[]`.

## Deploy-ready

All of: approved, merged, CI green on the head commit, and no superseded decision behind it. Deploy still needs the user's explicit word.

## Count line

Shown at the start of the planner's reply after a user message, only when the board changed since it was last shown. It is never shown mid-round or repeated.

Example: `Board: 2 in review (oldest 3h), 1 deploy-ready, 1 decision open`

The full board is shown on request.

## Layout

| Place | Contents |
|---|---|
| Tab 1, left half | Planner |
| Tab 1, right half | Orchestrator |
| Workers tab | Workers as an even grid |

| Variable | Default | Effect |
|---|---|---|
| `HERDMASTER_GRID_PANES` | 6 | Panes per grid; overflow opens another workers tab |
| `HERDMASTER_WORKER_LAYOUT` | unset | `main` keeps workers on the main tab |
| `HERDMASTER_MAX_PANES` | 4 | Max workers on the main tab when layout is `main` |

## Pane identity

Launched panes get `HERDMASTER_ROLE` (`orchestrator` or `worker`) and `HERDMASTER_MASTER=<planner session name>`. The herdmaster skill refuses to run when `HERDMASTER_ROLE` is set. This is advisory; add a SessionStart hook only if it fails in practice. Pane labels use `herdr pane rename`.

## Viewers

Localhost page first: python3, bound to 127.0.0.1 only, read-only, reads `tasks.json`. A native app wrapping the same board comes later. Building either is out of scope.

## Open questions

- Planner-to-orchestrator message formats for new task, user answer, rejection with feedback, and approval, and what the orchestrator records for each.
- Migration of existing `design-queue.md`, `decisions.md` and `status.md`: replaced, kept as generated views, or left alone.
- Viewer contract details: refresh interval, error handling for a mid-write or missing file, `schema_version` mismatch behavior.
- Orchestrator-unavailable fallback: where a planner message waits so it is never lost.
