# A sandbox Azure DevOps board for testing ADO Desk

This guide sets up a free Azure DevOps project that matches what `ado_cli.py` expects, then fills it with a realistic
backlog: epics, features, user stories, tasks and bugs about building ADO Desk itself. After that, every section of
the app has real data to show, and the checklist at the end tells you what each one should display.

Use a separate organization or project for this. The seed script creates about 120 work items and changes the team's
settings.

- [1. Create an inherited Agile process](#1-create-an-inherited-agile-process)
- [2. Add the Secondary Assignee field](#2-add-the-secondary-assignee-field)
- [3. Create the project](#3-create-the-project)
- [4. Create a personal access token](#4-create-a-personal-access-token)
- [5. Write a sandbox .env file](#5-write-a-sandbox-env-file)
- [6. Seed the board](#6-seed-the-board)
- [7. Finish in the web UI](#7-finish-in-the-web-ui)
- [8. Point ADO Desk at the sandbox](#8-point-ado-desk-at-the-sandbox)
- [What's on the board](#whats-on-the-board)
- [Test checklist](#test-checklist)
- [Reset or move the board forward](#reset-or-move-the-board-forward)

## What the engine assumes

These assumptions are built into `ado_cli.py`, and the setup below follows them:

| Assumption | Why it matters |
| --- | --- |
| The **Agile** process | `create` defaults to `User Story`, the closed-story commands look for `Closed` and `Resolved`, and `update --story-points` writes `Microsoft.VSTS.Scheduling.StoryPoints`. The Basic and Scrum processes have different types and states. |
| A `Custom.SecondaryAssignee` field | `create` and `update --secondary-assignee` write it. Without it, ADO returns 400 and the app shows `VALIDATION_ERROR`. |
| Monthly sprints at `<prefix>\FY##\<Month> <YYYY>` | `iteration-pick` (the New Work Item sheet's sprint suggestion) only recognizes this layout, with fiscal years starting in September. |
| A team | The Current Sprint and Sprints sections only see iterations selected for the team in `ADO_TEAM`. |

## 1. Create an inherited Agile process

You can't change the built-in processes, so make a copy you can add a field to.

1. In Azure DevOps, open **Organization settings** (bottom left) → **Boards** → **Process**.
2. Next to **Agile**, select **…** → **Create inherited process**.
3. Name it `Agile - ADO Desk` and select **Create process**.

## 2. Add the Secondary Assignee field

1. In **Process**, open `Agile - ADO Desk` → **User Story**.
2. Select **New field**.
3. Name it exactly `Secondary Assignee` and set **Type** to **Identity**. Azure DevOps derives the reference name
   `Custom.SecondaryAssignee` from the name, which is what the engine writes.
4. On the **Layout** tab choose where it shows (the **Details** group is fine), then select **Add field**.
5. Optional: open **Task** and **Bug**, select **New field** → **Use an existing field**, and pick
   `Secondary Assignee`, so you can test the field on those types too.

## 3. Create the project

1. Go back to your organization's home page and select **New project**.
2. Name: `ADO Desk Sandbox`. The space is on purpose: it checks that the engine encodes project and team names in
   URLs.
3. Visibility: **Private**.
4. Under **Advanced**, set **Work item process** to `Agile - ADO Desk`.
5. Select **Create**.

Azure DevOps creates a default team named `ADO Desk Sandbox Team`. Use that one.

If you already created the project with plain Agile, go to **Organization settings** → **Process** → **Agile** →
**Projects**, and choose **Change process** for the project to move it to `Agile - ADO Desk`.

## 4. Create a personal access token

1. Select **User settings** (the person icon, top right) → **Personal access tokens** → **New Token**.
2. Name: `ADO Desk sandbox`. Organization: your sandbox organization. Pick an expiry date.
3. Scopes: **Custom defined**, then:
   - **Work Items: Read, write, & manage**: work items, comments, deleting, areas, iterations and team sprint
     settings.
   - **Project and Team: Read**
4. Select **Create** and copy the token. Azure DevOps won't show it again.

Some tokens with these scopes are still refused when the seed script sets the team's area (HTTP 401). The script then
says so, carries on with the work items, and you set the area by hand (see [step 7](#7-finish-in-the-web-ui)). If it
stops with `AUTH_ERROR` anywhere else, do the team steps by hand and run it again with `--skip-paths`.

## 5. Write a sandbox .env file

Keep it outside the repository, so it can't be committed and won't replace the `.env` you use for real work:

```sh
# ~/.ado-desk-sandbox.env
ADO_ORG=<your sandbox organization name>
ADO_PROJECT=ADO Desk Sandbox
ADO_TEAM=ADO Desk Sandbox Team
ADO_TOKEN=<the token from step 4>
# Your Azure DevOps sign-in email. The seed script assigns sprint work to it, and
# export-closed-stories filters on it.
ADO_ASSIGNEE=<you@example.com>
# Gives the New Work Item sheet a sprint suggestion (see the checklist).
ADO_AREA_PATH=ADO Desk Sandbox\Desk
```

Check the connection before seeding:

```sh
ADO_ENV_FILE=~/.ado-desk-sandbox.env python3 ado_cli.py iteration-list
```

A `success: true` envelope means the organization, project, team and token are right. At this point the list only
holds the project's default iterations.

## 6. Seed the board

[`scripts/seed_test_board.py`](../scripts/seed_test_board.py) uses the same settings as the engine. Preview the plan
first; the preview makes no requests:

```sh
export ADO_ENV_FILE=~/.ado-desk-sandbox.env
python3 scripts/seed_test_board.py --dry-run
python3 scripts/seed_test_board.py
```

It shows the organization, project and team, asks you to confirm, and then:

1. Creates the areas `ADO Desk Sandbox\Desk`, `…\Desk\App` and `…\Desk\Engine`.
2. Creates monthly sprints under `ADO Desk Sandbox\Desk`: `FY26\August 2026`, then `FY27\September 2026` to
   `FY27\January 2027`, each covering its whole month.
3. Selects those sprints for the team, and sets the team's area to `ADO Desk Sandbox\Desk` with sub-areas.
4. Says whether `Custom.SecondaryAssignee` exists.
5. Creates the work items, each tagged `ado-desk-seed`. Each item gets one update per state change, so its history,
   and `export-modifications`, look like work that happened over time.

It takes a few minutes. Options: `--skip-paths` (items only), `--skip-items` (areas, sprints and team only),
`--assignee=<email>`, `--team=<name>`, `--yes` (no prompt).

## 7. Finish in the web UI

The script can't do these:

1. **Check the team settings** in **Project settings** → **Team configuration**:
   - **Iterations**: the six sprints are listed. If not, select **+ Select iteration(s)** and add them.
   - **Areas**: `ADO Desk Sandbox\Desk` is the default, with sub-areas included. If not, select
     **+ Select area(s)**, add it with **Include sub areas** checked, then choose **…** → **Set as default** on its
     row.
   - **General** → **Working with bugs**: choose **Bugs are managed with requirements**, so the two seeded bugs appear
     on the backlog beside the stories.
2. **Set a sprint goal** for October 2026 in **Boards** → **Sprints**, or leave it empty and set it from ADO Desk.
3. **Optional: add a second person.** The first five users with Basic access are free. Invite another Microsoft
   account in **Organization settings** → **Users**, add them to the project, and reassign a few stories to them. This
   gives the closed-stories summary more than one assignee and lets you test `export-modifications --user` for
   someone else.

## 8. Point ADO Desk at the sandbox

In the setup card or **Settings** (⌘,), either select **Engine** → `.env` file and choose `~/.ado-desk-sandbox.env`,
or fill in the fields:

| Pane | Field | Value |
| --- | --- | --- |
| Connection | Organization | your sandbox organization |
| Connection | Project | `ADO Desk Sandbox` |
| Connection | Team | `ADO Desk Sandbox Team` |
| Connection | Token | the token from step 4 |
| Defaults | Assignee | your sign-in email |
| Defaults | Area path | `ADO Desk Sandbox\Desk` |

A blank field falls back to the `.env` file, so you can mix the two.

## What's on the board

Four epics, 12 features, 36 user stories, 64 tasks and 2 bugs:

| Epic | Area | Features |
| --- | --- | --- |
| Engine: a scriptable Azure DevOps CLI | `Desk\Engine` | Work item commands · Iteration and sprint commands · Exports · Engine hardening |
| ADO Desk: the macOS app | `Desk\App` | Setup and settings · Current Sprint view · Work item editor · New Work Item sheet |
| Reports and sprint history | `Desk\App` | Reports section · Sprint history |
| Distribution and updates | `Desk\App` | Release pipeline · Self-update |

Stories by sprint (with today being late October 2026):

| Sprint | Time frame | Stories | Closed story points |
| --- | --- | --- | --- |
| `FY26\August 2026` | past | 4 Closed | 12 |
| `FY27\September 2026` | past | 7 Closed | 23 |
| `FY27\October 2026` | **current** | 8 Closed, 3 Resolved, 4 Active, 1 New | 27 |
| `FY27\November 2026` | future | 5 New | 0 |
| `FY27\December 2026` | future | 1 New (unassigned) | 0 |
| `FY27\January 2027` | future | empty | 0 |
| No sprint (project root) | | 2 New, 1 Removed | |

Epics and features have no sprint. Tasks share their story's sprint and state, with remaining work set, so the
October sprint's taskboard and capacity view have data. Stories carry topic tags (`engine`, `app`, `reports`,
`sprints`, `release`, `security`, `ux` and others) for the closed-stories summary's top tags.

Some items are there to catch edge cases:

- **Handle names with apostrophes such as O'Brien in queries**: an apostrophe, double quotes and a backslash in the
  title and description.
- **Create work items with a parent link and acceptance criteria**: a Markdown description with a heading, bullets
  and a fenced code block.
- **Discard does not reset acceptance criteria** and **Inline comments in .env are read as part of the value**:
  bugs, which `iteration-closed-stories` should leave out because it only counts user stories.
- **Ship through the Mac App Store**: a `Removed` story.
- Four items have comments, to check Discussion in the editor.

## Test checklist

Find work item ids in **Boards** → **Backlogs**, or with the `ado-desk-seed` tag in **Boards** → **Queries**.

### Setup and settings

- [ ] **Settings → Engine → Verify Engine** succeeds.
- [ ] A wrong token shows `AUTH_ERROR`. A misspelled project shows `STORY_NOT_FOUND` (the engine maps every 404 to
      it).
- [ ] An empty Team field with no `ADO_TEAM` makes the Current Sprint section report `CONFIG_ERROR`.

### Current Sprint

- [ ] Shows **October 2026**, 1 to 31 October, with the right number of days left.
- [ ] Shows **8 closed stories** and **27 points**. Resolved stories don't count, because the closed-stories query
      only matches `Closed`.
- [ ] Setting, changing and clearing the sprint goal works, and the goal is still there after a refresh.
- [ ] **Copy as Markdown** puts all eight stories on the clipboard.

### Sprints

- [ ] **Current**: October 2026. **Upcoming**: November 2026 to January 2027. **Past**: August and September 2026.
- [ ] September shows 7 closed stories and 23 points. January 2027 shows an empty state, not an error.

### Work Items

- [ ] Open a story by id with ⌘K, and by part of its title once it's in the recent list.
- [ ] Change the title and story points: both are highlighted until **Save** (⌘S). Reopen the item to check the
      change was saved.
- [ ] Change acceptance criteria, then **Discard**: everything goes back.
- [ ] Move a story from Active to Resolved to Closed. It then counts on Current Sprint.
- [ ] Post a comment, then open the item in the browser and check Discussion.
- [ ] Delete a task, then restore it from **Boards** → **Work items** → **Recycle bin**.
- [ ] Open the O'Brien story: the apostrophe, quotes and backslash show correctly.
- [ ] Open an id that doesn't exist (99999): you get a clear `STORY_NOT_FOUND`.

### New Work Item

- [ ] With area path `ADO Desk Sandbox\Desk`, the sheet suggests **October 2026** (`FY27`).
- [ ] With area path `ADO Desk Sandbox\Desk\App`, there's **no suggestion**. `iteration-pick` matches the area path
      against *iteration* paths, and there are no iterations under `Desk\App`. This is a known engine quirk, not a
      broken board.
- [ ] Create a task with **Parent** set to a seeded story id: it shows under that story on the board.
- [ ] Create a story with **Secondary** set to your email. If step 2 was skipped, this fails with
      `VALIDATION_ERROR`.
- [ ] **Create another** keeps area, iteration and assignee.

### Reports

- [ ] **Export closed stories** from 2026-08-01 for your email: **22 items**, the 19 Closed and 3 Resolved stories
      assigned to you, newest first. Every completion date is the day you ran the seed script, so ranges that end
      before that day export nothing. An engine from before jsonify/ado-desk#17 exports only the 19 Closed stories,
      because it filtered on Closed Date, which Resolved items don't have.
- [ ] **Export modifications** for your email, from the seed day: several rows per item, one for each revision.
- [ ] **Reveal in Finder** opens the exported file.

### Activity drawer

- [ ] ⇧⌘Y lists every engine call above, with its command line, duration and raw JSON.

### Known gaps

- The app's Work Items list only holds items you've opened, created or updated in ADO Desk, because the engine has no
  "list my work items" command. It starts empty even though the board is full.
- The seeded descriptions put inline code (`` `--ac` ``) in bullet lists. With an engine from before
  jsonify/ado-desk#17, those show as literal backticks instead of code.

## Reset or move the board forward

- **Start over**: `python3 scripts/seed_test_board.py --cleanup` moves every `ado-desk-seed` item to the Recycle Bin.
  Then seed again. Areas, sprints and team settings are kept and reused.
- **Keep the board current**: the sprints are fixed months. Once October 2026 is over, the "current" sprint becomes
  November, where everything is New. Edit `SPRINTS` and the sprint keys in `scripts/seed_test_board.py` to move the
  window, then clean up and seed again.
