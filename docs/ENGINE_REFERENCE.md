# `ado_cli.py` engine reference

This is the contract between `ado_cli.py` (the "engine") and ADO Desk, the macOS app in [`../macos`](../macos). Use it when you add an app feature or a new engine command. Function-level details are in the docstrings in [`../ado_cli.py`](../ado_cli.py).

## Invocation

```
python3 ado_cli.py <command> --flag=value [--flag=value ...]
```

- Pass values as `--flag=value`. A value that starts with `-` (for example a Markdown bullet) would otherwise be read as an option. `CLIRunner` already does this.
- Every flag is a string on the command line. Some flags are parsed as numbers: `--id` (except on iteration commands, where it is a GUID string), `--parent-id` and `--priority` are integers, and `--story-points` is a float.
- `--ac` can be repeated. Each value becomes one acceptance criterion.
- The engine reads nothing from stdin. Its only network access is HTTPS to the organization URL.

## Environment

The environment is read once, before any command runs. Exported variables win over `.env` values.

| Variable | Required | Used by |
|---|---|---|
| `ADO_TOKEN` (or `AZURE_DEVOPS_PAT`, `ADO_PAT`) | yes | all commands (Basic auth) |
| `ADO_ORG` (or `AZURE_DEVOPS_ORG`) | yes | all commands. Either a bare name (→ `https://dev.azure.com/<name>`) or an `https://` URL |
| `ADO_PROJECT` (or `AZURE_DEVOPS_PROJECT`) | yes | all commands |
| `ADO_TEAM` | for `iteration-list/get/update-goal` | the default for `--team` |
| `ADO_ASSIGNEE` | for `export-closed-stories` | the default for `--assigned-to` |
| `ADO_AREA_PATH`, `ADO_ITERATION_PATH` | no | defaults for `create` |
| `SSL_CERT_FILE` | no | CA bundle. Ignored without warning if the path doesn't exist |
| `ADO_ENV_FILE` | no | Read only this `.env` file. Otherwise the engine tries `./.env`, then the folder above the script's folder |

The three required variables are needed even for commands that would not otherwise touch them. If one is missing, every command fails with `CONFIG_ERROR`.

## Output envelope

Every handled run prints exactly one JSON object to stdout:

```json
{ "success": true,  "command": "get", "timestamp": "2026-10-24T15:10:55+00:00",
  "organization": "https://dev.azure.com/acme", "project": "Proj", "result": { ... } }

{ "success": false, "command": "get", "timestamp": "...", "organization": "...", "project": "...",
  "error": { "code": "STORY_NOT_FOUND", "message": "..." } }
```

| Exit | stdout | When |
|---|---|---|
| 0 | success envelope | the command succeeded |
| 1 | error envelope | any handled failure (codes below) |
| 2 | *nothing* (usage on stderr) | argparse rejected the arguments: unknown command or flag, a missing required flag, a non-integer `--id`, or a bad `--timeframe` choice. `CLIRunner` reports this as `ENGINE_ERROR` |

### Error codes

| Code | Meaning |
|---|---|
| `CONFIG_ERROR` | A required environment variable is missing, `ADO_ORG` is invalid, or there is no team for an iteration command. `organization` and `project` are `null` when config loading failed |
| `AUTH_ERROR` | HTTP 401 or 403 (bad or expired PAT, or missing scope) |
| `STORY_NOT_FOUND` | HTTP 404 from **any** endpoint, iterations and teams included |
| `VALIDATION_ERROR` | Input rejected by the engine, or HTTP 400 from ADO (for example an unknown field such as `Custom.SecondaryAssignee`) |
| `NO_ITERATION_MATCH` | `iteration-pick` found no matching iteration |
| `API_ERROR` | Any other HTTP status, network errors and timeouts (60 s), non-JSON responses, and unexpected exceptions (for example an unreadable `--body-file`, or a malformed `--on` date) |

## Commands

The "Swift model" column lists the type in [`Models.swift`](../macos/Sources/ADODesk/Models.swift) that decodes `result`.

### Work items

| Command | Flags | `result` | Swift model |
|---|---|---|---|
| `create` | `--title` (required), `--type` (`User Story`), `--description`, `--ac`…, `--area-path`, `--iteration-path`, `--parent-id`, `--assigned-to`, `--secondary-assignee` | `id, title, state, parentId, assignedTo, secondaryAssignee, url` | `WorkItemSummary` |
| `get` | `--id` (required) | `id, title, state, assignedTo, url, fields` | `WorkItemDetail` |
| `update` | `--id` (required), plus at least one of `--title`, `--state`, `--assigned-to`, `--secondary-assignee`, `--priority`, `--story-points`, `--description`, `--ac`…, `--add-comment` | `id, title, state, url, updatedFieldsCount` | `UpdateResult` |
| `delete` | `--id` (required) | `id, deleted, response` | `DeleteResult` |
| `comment` | `--id` (required), `--body` or `--body-file` | `id, commentId` | `CommentResult` |

Notes:
- **Markdown:** `--description` (on create and update) supports headings, `-`/`*` bullets, `1.`–`9.` numbered items, fenced code blocks and inline backticks (in paragraphs and list items). These are converted to HTML. `--ac` items are HTML-escaped and turned into a `<ul>`. `comment --body` and `--add-comment` are sent **as-is** (ADO treats them as HTML).
- **`url` differs between commands.** `create` and `update` return the browser URL (`…/_workitems/edit/<id>`). `get` returns ADO's REST API URL.
- **Identity fields are not always strings.** `assignedTo` and `secondaryAssignee` in `create` and `get` are usually identity objects (`displayName`, `uniqueName`, …), so decode them as `JSONValue`.
- **Defaults on `create`:** if `--area-path` or `--iteration-path` is omitted, the `ADO_AREA_PATH` or `ADO_ITERATION_PATH` default is used. Passing an empty value (`--area-path=`) skips the field.
- **Flags on `update`:**
  - An omitted flag is left unchanged. An empty value (`--title=`) is **sent** as empty.
  - `--ac` replaces all existing criteria.
  - `--add-comment` writes `System.History`, so it appears in Discussion.
- **`delete`** moves the item to the Recycle Bin. It is not a permanent destroy.

### Iterations

| Command | Flags | `result` | Swift model |
|---|---|---|---|
| `iteration-list` | `--team`, `--timeframe` (`current`/`past`/`future`) | `count, iterations[{id, name, path, startDate, finishDate, timeFrame}]` | `IterationList` |
| `iteration-get` | `--id` (GUID, required), `--team` | `id, name, path, startDate, finishDate, timeFrame, goalText, raw` | `IterationDetail` |
| `iteration-update-goal` | `--id` (GUID, required), `--goal` or `--goal-file`, `--team` | `id, name, goalText` | `GoalResult` |
| `iteration-closed-stories` | `--iteration-path` (required), `--state` (`Closed`) | `query, summary{storyCount, totalStoryPoints, byAssignee, topTags[{tag,count}]}, stories[…]` | `ClosedStoriesResult` |
| `iteration-pick` | `--area-path` (required), `--on` (`YYYY-MM-DD`, default today) | `path, name, fiscalYear` | `IterationPick` |

Notes:
- **Team scope:** `iteration-list`, `iteration-get` and `iteration-update-goal` need a team, from `--team` or `ADO_TEAM`. They only see iterations the team has selected. `iteration-closed-stories` and `iteration-pick` are project-wide and ignore the team.
- **`goalText`** is read from the iteration's `attributes.goalText` and is `null` if ADO doesn't return it. `--goal=` with an empty value clears the goal.
- **`iteration-closed-stories`:**
  - It only queries the `User Story` type.
  - `--iteration-path` must match **exactly**, so stories in child iterations are excluded.
  - Each story in `stories` has `id, title, state, closedDate, assignedTo` (display name), `storyPoints` (0 if unset), `tags` (list) and `url`. Stories are sorted by closed date, newest first.
- **`iteration-pick`:**
  - `--area-path` is matched as a **prefix of iteration paths**, which begin with the project name (for example `Proj\Team`). It is not matched against area paths.
  - It expects leaves named `…\FY##\<Month> <YYYY>` and only reads 4 levels of the tree.
  - Fiscal years start in September (Sep 2025 is `FY26`).
  - It returns the first iteration in or after the reference month, or the latest one if all are past.

### Exports

| Command | Flags | `result` | Swift model |
|---|---|---|---|
| `export-closed-stories` | `--from-date` (`2025-01-01`), `--to-date`, `--work-item-type` (`User Story`), `--states` (`Closed,Resolved`), `--assigned-to` (or `ADO_ASSIGNEE`), `--output` | `count, output, fromDate, toDate, workItemType, states, assignee` | `ExportClosedResult` |
| `export-modifications` | `--user` (required), `--from-date` (required), `--to-date` | `user, fromDate, toDate, count, items[{id, revision, changedDate, changedBy, title, state, workItemType, url}]` | `ModificationsResult` |

Notes:
- **`export-closed-stories` writes a file.** The items are only in the file at `output`, not in `result`.
  - The default path is relative (`data/…`) to the engine's working directory, which for the app is `~/Library/Application Support/ADODesk`. Pass an absolute `--output`.
  - File schema: `organization, project, fromDate, fromDateIso, toDate, toDateIso, workItemType, states, assignee, count, items[{id, date (M/D/YYYY), title, state, workItemType, assignedTo, tags, description, acceptanceCriteria}]`. Rich text is flattened to plain text.
  - `--to-date` is inclusive.
  - The assignee is matched loosely on the client: case and word order are ignored, and a name of at least 2 words matches if all its words appear in the display name.
- **`export-modifications` writes nothing.** Items come back in `result`.
  - There is one item per revision, so the same work item can appear several times. `CLIRunner`'s `Modification.id` already combines id, revision and date.
  - It downloads every revision in the project for the range, so long ranges are slow. Show progress and avoid running it automatically.

## Adding a new command

1. Write `cmd_<name>(args, client) -> dict`.
   - Call `client.request(...)` for project-scoped APIs or `client.team_request(...)` for team-scoped ones. Include `api-version` in the path.
   - Raise `CliError("VALIDATION_ERROR", ...)` for bad input. Let `AdoApiError` propagate, because `main()` maps it.
   - Escape any user value placed in WIQL with `_escape_wiql_literal`.
   - Fetch fields for many ids with `_chunked(ids, 200)` and `wit/workitemsbatch`.
2. Add a subparser in `build_parser()`. Use `dest=` with snake_case names.
3. Add an `elif` branch in `main()`.
4. On the app side, add a `Decodable` model in `Models.swift` that matches `result`. Then call `cli.run([...], as: Model.self)` with `--flag=value` arguments.
5. Rebuild the `.app` (`macos/Scripts/build_app.sh`) so the bundled copy of the engine includes the change.
