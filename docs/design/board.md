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
| Readers | Viewers; they never write `tasks.json` |
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
| `options` | Optional, for decisions: `[{"key": "A", "text": "...", "recommended": true}]`; keys are unique single letters A-Z, at most one recommended. `recommend` stays the reason. Boards without `options` keep working and render the note only |
| `group` | Optional, for decisions: the ticket this question belongs to, one line of at most 60 characters (e.g. the feature name). Ungrouped questions show under a ticket named `Other` |
| `answer` | Optional, for settled decisions: the answer, one line, set with `status <id> settled "<answer>"` |
| `release_when_done` | Optional task boolean; when true the orchestrator takes the task to the project's release step once it is done |
| `review_pack` | Optional task object shown under the title while the task is `in review` (the string field `review` is the review mode, so the pack lives beside it): `summary` (plain English, what changed and why), `diff` (path or commit range, plain text), `tests` (result, plain text), `preview_url` (http/https), `screenshots[]` (absolute image paths), `links[]` (`{label, url}`, http/https). Set with `set-review`; every part is optional |
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

Set options with `herdmaster-board.sh add decision "Sidebar or top nav" --note "..." --recommend "why" --option "A|Sidebar" --option "B|Top nav" --recommend-key B`. `herdmaster-board.sh set-options D-007 --option "A|Sidebar" --option "B|Top nav" [--recommend-key B]` replaces the options of an existing decision; `show` prints them under the entry.

Tickets: a ticket is a group of related questions, one collapsible block in the viewer's Tickets column. The stored kind stays `decision`; the UI says "ticket" for the group and "question" for each decision in it. `herdmaster-board.sh add decision "..." --group "Navigation redesign"` files a question under a ticket, `set-group <id> "<name>"` moves an existing one, and `show` prints `ticket: <name>` on the entry. Groups have no entry of their own: a ticket exists while a non-superseded question names it. Boards without `group` keep working; all their questions land under `Other`.

Review pack: `herdmaster-board.sh set-review <task id> [--summary S] [--diff D] [--tests T] [--preview URL] [--screenshot PATH]... [--link "label|url"]...` merges into the task's `review_pack`. Scalar flags replace their field (an empty value removes it); `--screenshot` and `--link` are repeatable and replace the whole list when given. URLs must be http or https, screenshot paths absolute, and only tasks take a pack. `show` prints one `review:` line under the task. The viewer renders the pack directly under the title of an `in review` task: summary, a Preview link, extra links, screenshot thumbnails that open the full image in a new tab, then diff and tests as plain text. Missing parts are left out. Any http(s) URL in a note or summary becomes a link built with DOM nodes and `textContent` (never `innerHTML`), `rel="noopener noreferrer"`, `target="_blank"`; other schemes stay plain text.

The viewer serves screenshots through the read-only `GET /file?path=<absolute path>` route, which re-validates every request: the path must be absolute and contain no `..`, NUL byte or non-normalised segment (400); the realpath, with symlinks followed, must sit under `/private/tmp/claude-501` or `~/.claude/orchestrator/<project>/review/` (403); no path component below the root may start with `.` or be named `secrets`, compared NFKC and case-folded (403); the extension must be png, jpg, jpeg, gif, webp, txt, md, log, diff or patch (415); it must be a regular file, not a directory (400), opened with `O_NOFOLLOW` and at most 10 MB (413); a missing file is 404; other methods are 405. Responses carry a fixed `Content-Type` (text types are `text/plain`), `X-Content-Type-Options: nosniff` and a `default-src 'none'; sandbox` CSP; only images are `Content-Disposition: inline`, text is `attachment`. A `Sec-Fetch-Site` header other than `same-origin` or `none` is refused (403). Every route rejects a `Host` header other than `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding), every response carries `X-Content-Type-Options: nosniff`, the page carries a CSP that allows only its own inline script and style, same-origin images and fetches, and requests time out after 5 seconds of silence.

The viewer header reads "N of M answered" (settled over open plus settled; superseded questions are left out). A ticket opens by default when it holds an open question and is collapsed otherwise. Each question row shows its title and the recommended answer (the recommended option, else `recommend`) and expands to the options and note; a settled question shows its `answer`, or "Settled" when none was recorded. A task whose `depends_on` names an open decision shows "waiting on D7" (the short handle of `D-007`).

**Token delivery:** each start of the viewer prints a one-time URL, `http://127.0.0.1:<port>/#t=<token>` (`secrets.token_urlsafe(32)`), to stdout. The token lives only in the URL fragment, which browsers never send to the server and a rebound origin reading the response body never sees; no GET route (including `/`) ever puts the token in a response body. On load, the page's first script reads `location.hash`, moves the token into `sessionStorage`, and calls `history.replaceState` to strip the fragment from the visible URL immediately; every later `POST /answer` reads the token back out of `sessionStorage`. There is no token file; an operator who wants the URL again just restarts the viewer and reads the new one from its stdout.

Answering from the page: an open question with `options` shows one button per option, except options whose normalized text contains merge, deploy or push anywhere (see UX-only check below), which stay chat-only like open-ended questions. Clicking an option captures that option's currently-displayed text; a click asks `Confirm: "<text>"?` and only Yes sends `POST /answer` with body `{"project","id","key","text"}`, `text` being the text shown in the confirm prompt. The server checks, in order: Host (403), a present Origin must be exactly `http://127.0.0.1:<port>` or `http://localhost:<port>` (403; defense in depth alongside Host), exactly one Content-Length of at most 4096 bytes (400, 413), `Content-Type: application/json` (415), the `X-Herdmaster-Token` header against a per-start token compared in constant time (403), the body read capped at 4096 bytes (413), JSON with exactly those four string fields (400), then that the project exists (and matches `--project` if set), the id is an open decision, the key is one of its options, the submitted `text` equals that option's CURRENT text in `tasks.json` exactly (400 with a "refresh and try again" message otherwise -- this closes the TOCTOU where `set-options` changes an option's text while a confirm row is open), and that option's text does not contain merge, deploy or push anywhere after the same UX-only normalization the page's button-hiding uses (400). Only then does it append `{"project","id","key","text","at"}` as one line to `<project>/answers.jsonl` (mode 0600); it never touches `tasks.json`. No route sends CORS headers.

**UX-only word check, not a security boundary:** the page's button-hiding, the endpoint's rejection above, and `settle`'s own check (below) all look for `merge`, `deploy` and `push` after NFKC normalization, casefolding, stripping common invisible/filler characters (whitespace, control and format characters, zero-width combining marks, and specific filler codepoints like U+3164, U+FFA0, U+2800), and searching for the words anywhere in what remains, not only as a prefix. This defeats simple bypasses (emoji or markdown prefixes, numbered/bulleted prefixes, zero-width characters spliced into the word, full-width forms, mathematical bold/italic letters) but not a determined one (Cyrillic look-alikes, for instance, survive it). Because a character-level blocklist can never be made sound, **no settled decision or answers.jsonl line, however it was checked, authorizes merge, deploy or push by itself** -- the orchestrator always independently decides that from context before running one of those actions, per roles/orchestrator.md. `herdmaster-board.sh consume-answers <project>` (see below) settles or refuses each line of `answers.jsonl`; the orchestrator never hand-rolls per-line jq/settle calls, and never interpolates a line's text into a shell command it evaluates.

`herdmaster-board.sh consume-answers <project>` atomically renames the live `answers.jsonl` to a timestamped `.processing` file (so a `POST /answer` that lands mid-run appends to a fresh `answers.jsonl` instead of racing the read), then for each line calls `herdmaster-board.sh settle <id> --answer <key> --answer-text <text> --answer-at <at>` internally (values always passed via `--arg`/`--argjson`, never shell-interpolated), which refuses if the option's current text is not exactly `<text>` (the options changed after the click), the decision's `updated` timestamp is newer than `<at>` (the decision changed after the answer was recorded, e.g. it was reopened), or the text fails the UX-only word check above; otherwise it sets the answer to that text and appends `Answer: <text>` to the note. Every line, settled or refused, is appended to `answers.done.jsonl` -- a refused or stale line is never reconsidered from a live file -- and `consume-answers` prints a one-line settled/refused summary with refusal reasons.

## Lifecycles

Tasks: `working` -> `finished` -> `in review` -> `approved` -> `deploy-ready`. `approved` may go on to `done`. `blocked`, `failed`, `paused` and `cancelled` are side states; `done` and `cancelled` are terminal.

A decision is a real design question only (what to build, how it behaves, options with a recommendation); merge, push, review and yes/no approvals are task states, answered with `approve T#` or `merge T#`.

Decisions: `open` -> `settled` or `superseded`. A superseded decision flags every task that depends on it. Open decisions never expire and never disappear. There are no repeated pings.

## Settings

Per project: `~/.claude/orchestrator/<project>/settings.json`, edited with `herdmaster-board.sh settings get|set <key> <value>`.

| Key | Values | Default |
|---|---|---|
| `release` | `merge`, `deploy`, `push`, `ship`: the word for the final step | `deploy` |
| `grid_panes` | positive integer | env, then 6 |
| `worker_layout` | `tab` or `main` | env, then `tab` |
| `max_panes` | positive integer | env, then 4 |
| `herdr_workspace` | herdr workspace id, e.g. `w11` | unset |
| `agent` | an adapter name from `adapters/`, e.g. `claude` | `claude` |
| `agent_planner`, `agent_orchestrator`, `agent_worker` | an adapter name, for that role only | `agent` |

Precedence for the layout keys: settings file, then the `HERDMASTER_*` environment variable, then the built-in default. `herdmaster-layout.sh` reads the file.

`agent` and `agent_<role>` pick the terminal agent for fleet panes. `herdmaster-layout.sh new-worker|new-orchestrator ... --tier <tier> [--resume <id>] [prompt]` asks `herdmaster-agent.sh` to build the launch command from `adapters/<agent>.sh`; a launch given as an explicit command is run as before. Only the `claude` adapter exists so far (see docs/design/providers.md).

`herdr_workspace` maps a herdr workspace to the project. `herdmaster-layout.sh new-orchestrator` records it from `herdr pane current`, and the viewer's `GET /focus.json` uses it to report which project owns the focused workspace, so the page can follow herdr. Unmapped or unreachable herdr gives `null`.

## Archive

`herdmaster-board.sh archive` keeps the newest 200 `done` and `cancelled` tasks (by `updated`) on the board and moves the rest to `tasks-archive.json` beside it.

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

Localhost page first: python3, bound to 127.0.0.1 only, reads `tasks.json` and never writes it. A native app wrapping the same board comes later. Building either is out of scope.

## Legacy import

`herdmaster-board.sh import-legacy` merges `design-queue.md` and `decisions.md` from the project's orchestrator directory into the board, once. Queue entries (`## <title> (<date>, blocking: yes|no)` with `Question:`, `Options:`, `Context:`) become open decisions: note is Question plus Context, `recommend` is the option marked recommended, `blocking` is kept as a field. Each `- ` line in `decisions.md` becomes a settled decision (title is its first clause, note is the line without its date). Entries whose title is already on the board are skipped; new ids continue the `D-###` sequence. It writes `.legacy-imported` next to `tasks.json`, prints the counts, and never touches the old files.

## Open questions

- Planner-to-orchestrator message formats for new task, user answer, rejection with feedback, and approval, and what the orchestrator records for each.
- Migration of `status.md`: replaced, kept as a generated view, or left alone (queue and decisions are covered by the legacy import).
- Viewer contract details: refresh interval, error handling for a mid-write or missing file, `schema_version` mismatch behavior.
- Orchestrator-unavailable fallback: where a planner message waits so it is never lost.
