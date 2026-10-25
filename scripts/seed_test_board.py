#!/usr/bin/env python3
r"""Seed an Azure DevOps sandbox project with a test board for ADO Desk.

Builds the area and monthly iteration tree that ado_cli.py expects
(<Project>\Desk\FY##\<Month> <YYYY>), selects the sprints and the area for the
team, then creates a backlog of epics, features, user stories, tasks and bugs
about building ADO Desk itself, spread across past, current and future sprints
in realistic states.

Run it against a SANDBOX project only. It reads the same settings as the engine
(ADO_ORG, ADO_PROJECT, ADO_TOKEN, ADO_TEAM, ADO_ASSIGNEE, from the environment or
a .env file), so point ADO_ENV_FILE at a sandbox .env if your default one is for
real work. It shows the target and asks before changing anything.

    python3 scripts/seed_test_board.py --dry-run     # print the plan, no network
    python3 scripts/seed_test_board.py               # paths, team settings and items
    python3 scripts/seed_test_board.py --skip-paths  # items only
    python3 scripts/seed_test_board.py --cleanup     # move seeded items to the Recycle Bin

Every seeded item is tagged "ado-desk-seed". Seeding refuses to run twice unless
you pass --force; --cleanup removes the previous run's items first.

See docs/TEST_BOARD.md for the manual setup this script cannot do (the process
and the Secondary Assignee field) and for a test checklist.
"""

from __future__ import annotations

import argparse
import calendar
import sys
import urllib.parse
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ado_cli  # noqa: E402  (imported after the path tweak above)
from ado_cli import API_VERSION, COMMENT_API_VERSION, AdoApiError, AdoClient  # noqa: E402

SEED_TAG = "ado-desk-seed"
AREA_ROOT = "Desk"
SUB_AREAS = ("App", "Engine")

# (fiscal year label, year, month). Fiscal years start in September, as in
# ado_cli.py's iteration-pick: August 2026 is FY26, September 2026 is FY27.
SPRINTS = [
    ("FY26", 2026, 8),
    ("FY27", 2026, 9),
    ("FY27", 2026, 10),
    ("FY27", 2026, 11),
    ("FY27", 2026, 12),
    ("FY27", 2027, 1),
]

# The states each Agile work item type walks through to reach a target state.
# Work items are always created in New, so later states take one update each.
STATE_PATHS = {
    "Task": ["New", "Active", "Closed"],
    "default": ["New", "Active", "Resolved", "Closed"],
}


def sprint_name(year: int, month: int) -> str:
    return f"{calendar.month_name[month]} {year}"


def sprint_key(year: int, month: int) -> str:
    return f"{year}-{month:02d}"


@dataclass
class Item:
    type: str
    title: str
    area: str = "App"
    sprint: str | None = None  # "YYYY-MM", or None for the backlog
    state: str = "New"
    points: float | None = None
    priority: int = 2
    tags: tuple[str, ...] = ()
    description: str = ""
    ac: tuple[str, ...] = ()
    hours: float | None = None  # tasks only: original estimate
    assigned: bool = True
    comments: tuple[str, ...] = ()
    children: list[Item] = field(default_factory=list)


def epic(title: str, description: str, *, area: str, state: str, children: list[Item]) -> Item:
    return Item("Epic", title, area=area, state=state, description=description, priority=1, children=children)


def feature(title: str, description: str, *, area: str, state: str, children: list[Item], tags: tuple[str, ...] = ()) -> Item:
    return Item("Feature", title, area=area, state=state, description=description, tags=tags, children=children)


def story(title: str, *, area: str, sprint: str | None, state: str, points: float, tags: tuple[str, ...],
          description: str, ac: tuple[str, ...], tasks: list[Item] = (), priority: int = 2,
          comments: tuple[str, ...] = (), assigned: bool = True) -> Item:
    # Tasks inherit the story's area and sprint.
    for t in tasks:
        t.area, t.sprint = area, sprint
    return Item("User Story", title, area=area, sprint=sprint, state=state, points=points, priority=priority,
                tags=tags, description=description, ac=ac, comments=comments, assigned=assigned, children=list(tasks))


def task(title: str, hours: float, state: str) -> Item:
    return Item("Task", title, state=state, hours=hours)


def bug(title: str, *, area: str, sprint: str | None, state: str, tags: tuple[str, ...], description: str,
        priority: int = 2, comments: tuple[str, ...] = ()) -> Item:
    return Item("Bug", title, area=area, sprint=sprint, state=state, tags=tags, description=description,
                priority=priority, comments=comments)


AUG, SEP, OCT, NOV, DEC, JAN = (sprint_key(y, m) for _, y, m in SPRINTS)

BACKLOG: list[Item] = [
    epic(
        "Engine: a scriptable Azure DevOps CLI",
        "`ado_cli.py` is a single-file, standard-library Python CLI. Every command prints one JSON envelope so the "
        "macOS app (and anyone with `jq`) can drive it.",
        area="Engine",
        state="Active",
        children=[
            feature(
                "Work item commands",
                "create, get, update, delete and comment, with Markdown descriptions and acceptance criteria.",
                area="Engine",
                state="Closed",
                tags=("engine",),
                children=[
                    story(
                        "Create work items with a parent link and acceptance criteria",
                        area="Engine", sprint=AUG, state="Closed", points=5, tags=("engine", "work-items"),
                        description=(
                            "## Goal\n"
                            "Create any work item type from the command line.\n\n"
                            "- `--parent-id` adds a Hierarchy-Reverse link\n"
                            "- `--ac` can be repeated, one criterion each\n"
                            "- Area and iteration fall back to `ADO_AREA_PATH` / `ADO_ITERATION_PATH`\n\n"
                            "```sh\n"
                            "python3 ado_cli.py create --title=\"Add login audit\" --ac=\"Logins are recorded\"\n"
                            "```"
                        ),
                        ac=("A created item is returned with its id and browser URL",
                            "The new item is linked under --parent-id",
                            "Each --ac value becomes one bullet in Acceptance Criteria"),
                        tasks=[task("Build the JSON Patch body", 3, "Closed"),
                               task("Convert Markdown descriptions to HTML", 5, "Closed"),
                               task("Add the parent relation", 2, "Closed")],
                    ),
                    story(
                        "Update only the fields that were passed",
                        area="Engine", sprint=AUG, state="Closed", points=3, tags=("engine", "work-items"),
                        description="Omitted flags are left alone; an empty value (`--title=`) is sent as empty.",
                        ac=("Fields without a flag are not touched",
                            "A comment passed with --add-comment shows in Discussion"),
                        tasks=[task("Map flags to JSON Patch operations", 3, "Closed"),
                               task("Reject an update with no fields", 1, "Closed")],
                    ),
                    story(
                        "Delete moves the item to the Recycle Bin",
                        area="Engine", sprint=AUG, state="Closed", points=2, tags=("engine", "work-items"),
                        description="`delete` never passes `destroy=true`, so a mistake can be restored.",
                        ac=("A deleted item can be restored from the Recycle Bin",),
                        tasks=[task("Call DELETE without destroy", 1, "Closed")],
                    ),
                    story(
                        "Post comments through the comments API",
                        area="Engine", sprint=AUG, state="Closed", points=2, tags=("engine", "work-items"),
                        description="`comment --body` or `--body-file`, sent as-is (ADO treats it as HTML).",
                        ac=("The new comment id is returned", "The comment can be read from a file with --body-file"),
                        tasks=[task("Call the 7.1-preview.3 comments endpoint", 2, "Closed")],
                    ),
                ],
            ),
            feature(
                "Iteration and sprint commands",
                "List the team's sprints, read and set the sprint goal, summarize closed stories, and pick the "
                "monthly iteration for an area path.",
                area="Engine",
                state="Active",
                tags=("engine",),
                children=[
                    story(
                        "List team iterations by timeframe",
                        area="Engine", sprint=SEP, state="Closed", points=3, tags=("engine", "sprints"),
                        description="`iteration-list --timeframe=current|past|future`, scoped to `ADO_TEAM`.",
                        ac=("Only iterations selected for the team are listed",
                            "A missing team is reported as CONFIG_ERROR"),
                        tasks=[task("Call work/teamsettings/iterations", 2, "Closed"),
                               task("Add the --timeframe filter", 1, "Closed")],
                    ),
                    story(
                        "Read and update the sprint goal",
                        area="Engine", sprint=SEP, state="Closed", points=3, tags=("engine", "sprints"),
                        description="Reads `attributes.goalText`; `--goal=` with an empty value clears it.",
                        ac=("iteration-get returns goalText, or null when unset",
                            "iteration-update-goal accepts --goal or --goal-file"),
                        tasks=[task("Read goalText in iteration-get", 2, "Closed"),
                               task("PATCH the goal in iteration-update-goal", 2, "Closed")],
                    ),
                    story(
                        "Summarize closed stories for an iteration",
                        area="Engine", sprint=SEP, state="Closed", points=5, tags=("engine", "sprints", "reports"),
                        description="Story count, total points, counts by assignee and the top tags.",
                        ac=("Only User Stories in exactly that iteration path are counted",
                            "Stories are sorted newest closed first"),
                        tasks=[task("Write the WIQL query", 2, "Closed"),
                               task("Batch-fetch fields 200 ids at a time", 3, "Closed"),
                               task("Aggregate points, assignees and tags", 3, "Closed")],
                    ),
                    story(
                        "Pick the monthly iteration for an area path",
                        area="Engine", sprint=OCT, state="Resolved", points=3, tags=("engine", "sprints"),
                        description=(
                            "Find `...\\FY##\\<Month> <YYYY>` under the given prefix. Fiscal years start in "
                            "September, so September 2026 is FY27."
                        ),
                        ac=("Returns the current month's iteration when one exists",
                            "Falls back to the latest iteration when all are in the past",
                            "Reports NO_ITERATION_MATCH when nothing matches the pattern"),
                        tasks=[task("Walk the iteration tree to depth 4", 2, "Closed"),
                               task("Match FY and month names", 2, "Closed"),
                               task("Verify against the sandbox board", 1, "Active")],
                        comments=("Resolved: verified on the sandbox board. Waiting on a second pair of eyes before closing.",),
                    ),
                ],
            ),
            feature(
                "Exports",
                "Write closed stories to a JSON file and list one person's modifications for a date range.",
                area="Engine",
                state="Active",
                tags=("engine", "reports"),
                children=[
                    story(
                        "Export closed stories to a JSON file",
                        area="Engine", sprint=SEP, state="Closed", points=5, tags=("engine", "reports"),
                        description="Rich text is flattened to plain text; `--to-date` is inclusive.",
                        ac=("Items are written to --output, not returned in result",
                            "The assignee is matched loosely (case and word order ignored)"),
                        tasks=[task("Build the closed-stories WIQL", 2, "Closed"),
                               task("Flatten rich text fields", 3, "Closed"),
                               task("Loose assignee matching", 2, "Closed")],
                    ),
                    story(
                        "Export one person's modifications for a date range",
                        area="Engine", sprint=OCT, state="Active", points=8, tags=("engine", "reports"),
                        description=(
                            "One row per revision. It downloads every revision in the project for the range, so "
                            "long ranges are slow."
                        ),
                        ac=("Every revision by --user in the range is listed",
                            "Each row has id, revision, changedDate, title, state and type"),
                        tasks=[task("Page through the reporting revisions API", 5, "Closed"),
                               task("Filter revisions by user", 3, "Active"),
                               task("Measure a 30-day range on a large project", 2, "New")],
                        comments=("Took 41 s for 30 days on the sandbox. Fine here, but worth a progress indicator in the app.",),
                    ),
                    story(
                        "Handle names with apostrophes such as O'Brien in queries",
                        area="Engine", sprint=NOV, state="New", points=2, tags=("engine", "bug-bash"),
                        description="Test data for escaping: a title with an apostrophe, \"quotes\" and a back\\slash.",
                        ac=("A flag value that starts with a dash still parses as a value",
                            "O'Brien is escaped as O''Brien in WIQL"),
                        tasks=[task("Add a test for _escape_wiql_literal", 1, "New")],
                    ),
                ],
            ),
            feature(
                "Engine hardening",
                "Safer defaults and friendlier failures.",
                area="Engine",
                state="Active",
                tags=("engine", "security"),
                children=[
                    story(
                        "Allow HTTPS URLs only",
                        area="Engine", sprint=SEP, state="Closed", points=1, tags=("engine", "security"),
                        description="Refuse file://, http:// and anything else before a request is sent (CWE-939).",
                        ac=("A non-https organization URL fails with API_ERROR",),
                        tasks=[task("Add the scheme allowlist", 1, "Closed")],
                    ),
                    story(
                        "Retry on HTTP 429 using Retry-After",
                        area="Engine", sprint=NOV, state="New", points=3, tags=("engine", "reliability"),
                        description="Azure DevOps throttles busy clients. Back off instead of failing the command.",
                        ac=("A 429 is retried up to three times",
                            "The wait honours the Retry-After header"),
                        tasks=[task("Read Retry-After and sleep", 2, "New"),
                               task("Cap the total wait at 60 seconds", 1, "New")],
                    ),
                    bug(
                        "Inline comments in .env are read as part of the value",
                        area="Engine", sprint=NOV, state="New", tags=("engine", "config"), priority=3,
                        description=(
                            "Steps: put `ADO_TEAM=Desk Team # sandbox` in .env and run `iteration-list`.\n\n"
                            "Expected: the team is `Desk Team`. Actual: the team includes the comment, and the "
                            "request returns 404."
                        ),
                    ),
                ],
            ),
        ],
    ),
    epic(
        "ADO Desk: the macOS app",
        "A SwiftUI front end that runs `ado_cli.py` for every action and decodes its JSON envelope.",
        area="App",
        state="Active",
        children=[
            feature(
                "Setup and settings",
                "First-launch setup card and the Settings window (Connection, Defaults, Engine, Updates).",
                area="App",
                state="Closed",
                tags=("app", "settings"),
                children=[
                    story(
                        "First-launch setup card",
                        area="App", sprint=SEP, state="Closed", points=3, tags=("app", "settings", "ux"),
                        description="Enter organization, project, team and token, or point at an existing `.env`.",
                        ac=("The card appears until a connection is configured",
                            "Choosing a .env file skips the token field"),
                        tasks=[task("Build the SetupCard view", 3, "Closed"),
                               task("Validate the organization URL", 1, "Closed")],
                    ),
                    story(
                        "Keep the token in the macOS Keychain",
                        area="App", sprint=SEP, state="Closed", points=3, tags=("app", "settings", "security"),
                        description="The PAT never touches UserDefaults or disk; it is passed to the engine as `ADO_TOKEN`.",
                        ac=("The token is stored in and read from the Keychain",
                            "Clearing the field removes the Keychain item"),
                        tasks=[task("Keychain read/write helper", 3, "Closed"),
                               task("Pass ADO_TOKEN to the engine process", 1, "Closed")],
                    ),
                    story(
                        "Verify Engine checks the script and interpreter",
                        area="App", sprint=OCT, state="Closed", points=2, tags=("app", "settings"),
                        description="Run `ado_cli.py --help` with the configured Python and report the result.",
                        ac=("A missing python3 is reported in plain words",
                            "A missing script path is reported in plain words"),
                        tasks=[task("Add the Verify Engine button", 2, "Closed")],
                    ),
                ],
            ),
            feature(
                "Current Sprint view",
                "The team's current iteration: dates, days left, goal, and closed stories.",
                area="App",
                state="Active",
                tags=("app", "sprints"),
                children=[
                    story(
                        "Show sprint dates, days left and the sprint goal",
                        area="App", sprint=OCT, state="Closed", points=5, tags=("app", "sprints", "ux"),
                        description="Header for the home view, from `iteration-list --timeframe=current` and `iteration-get`.",
                        ac=("Days left counts the finish date as a working day",
                            "A sprint without a goal shows a placeholder"),
                        tasks=[task("Decode IterationList and IterationDetail", 2, "Closed"),
                               task("Lay out the sprint header", 3, "Closed"),
                               task("Days-left calculation", 1, "Closed")],
                    ),
                    story(
                        "Copy closed stories as Markdown",
                        area="App", sprint=OCT, state="Resolved", points=2, tags=("app", "sprints", "reports"),
                        description="One bullet per story with its id, title and points, ready for a sprint review.",
                        ac=("The copied Markdown links each story to ADO",),
                        tasks=[task("Format stories as Markdown", 2, "Closed")],
                    ),
                    story(
                        "Edit the sprint goal inline",
                        area="App", sprint=OCT, state="Active", points=3, tags=("app", "sprints", "ux"),
                        description="Click the goal to edit; Return saves through `iteration-update-goal`.",
                        ac=("Escape cancels without saving", "A failed save keeps the edited text"),
                        tasks=[task("Editable goal field", 2, "Closed"),
                               task("Save and error handling", 2, "Active")],
                    ),
                ],
            ),
            feature(
                "Work item editor",
                "Open, edit and comment on work items without leaving the app.",
                area="App",
                state="Active",
                tags=("app", "work-items"),
                children=[
                    story(
                        "Inline editor that highlights changed fields",
                        area="App", sprint=OCT, state="Active", points=8, tags=("app", "work-items", "ux"),
                        priority=1,
                        description="Changed fields stay highlighted until Save (⌘S) or Discard.",
                        ac=("Save sends only the changed fields",
                            "Discard restores every field, acceptance criteria included",
                            "Area and iteration are read-only"),
                        tasks=[task("Track the original and edited values", 3, "Closed"),
                               task("Highlight changed fields", 2, "Closed"),
                               task("Save with ⌘S", 2, "Active"),
                               task("Discard and confirm on close", 2, "New")],
                        comments=("Demoed at stand-up. Discard still misses acceptance criteria, see the linked bug.",),
                    ),
                    story(
                        "Open any item by id from the command palette",
                        area="App", sprint=OCT, state="Closed", points=3, tags=("app", "work-items", "ux"),
                        description="⌘K, type an id or part of a title, Return opens it.",
                        ac=("An unknown id shows STORY_NOT_FOUND in plain words",),
                        tasks=[task("Command palette search", 3, "Closed")],
                    ),
                    story(
                        "Post comments from the editor",
                        area="App", sprint=OCT, state="New", points=3, tags=("app", "work-items"),
                        description="A comment box under the editor that calls `comment`.",
                        ac=("The new comment appears without reopening the item",),
                        tasks=[task("Comment box and send button", 2, "New"),
                               task("Refresh the discussion after posting", 1, "New")],
                    ),
                    bug(
                        "Discard does not reset acceptance criteria",
                        area="App", sprint=OCT, state="Active", tags=("app", "work-items"), priority=1,
                        description=(
                            "Steps: open a story, edit Acceptance Criteria, press Discard.\n\n"
                            "Expected: the original criteria come back. Actual: the edited text stays and the field "
                            "is no longer highlighted."
                        ),
                    ),
                ],
            ),
            feature(
                "New Work Item sheet",
                "Create stories, tasks and bugs with sensible placement (⌘N).",
                area="App",
                state="Active",
                tags=("app", "work-items"),
                children=[
                    story(
                        "Suggest the current sprint for the area path",
                        area="App", sprint=OCT, state="Closed", points=3, tags=("app", "sprints"),
                        description="Calls `iteration-pick` for the area path and offers its result.",
                        ac=("The suggestion updates when the area path changes",
                            "No suggestion is shown when iteration-pick finds no match"),
                        tasks=[task("Call iteration-pick on area change", 2, "Closed"),
                               task("Show the suggestion chip", 1, "Closed")],
                    ),
                    story(
                        "Create another keeps placement and assignment",
                        area="App", sprint=NOV, state="New", points=2, tags=("app", "work-items", "ux"),
                        description="After creating, the sheet stays open with area, iteration and assignee kept.",
                        ac=("Title, description and criteria are cleared", "Placement and assignment are kept"),
                        tasks=[task("Reset only the content fields", 1, "New")],
                    ),
                ],
            ),
        ],
    ),
    epic(
        "Reports and sprint history",
        "Turn the board into something to share: exports, past sprints and trends.",
        area="App",
        state="Active",
        children=[
            feature(
                "Reports section",
                "Exports from the app with absolute output paths and quick access to recent files.",
                area="App",
                state="Active",
                tags=("app", "reports"),
                children=[
                    story(
                        "Export closed stories for a date range",
                        area="App", sprint=OCT, state="Closed", points=3, tags=("app", "reports"),
                        description="Date pickers, assignee, and an absolute `--output` path.",
                        ac=("The export lands in the chosen folder",
                            "The result shows the item count"),
                        tasks=[task("Date range form", 2, "Closed"),
                               task("Run export-closed-stories", 1, "Closed")],
                    ),
                    story(
                        "Export modifications with a progress indicator",
                        area="App", sprint=NOV, state="New", points=5, tags=("app", "reports", "ux"),
                        description="`export-modifications` can take a minute on long ranges; show that it is working.",
                        ac=("A spinner and elapsed time show while it runs", "It can be cancelled"),
                        tasks=[task("Progress UI", 2, "New"),
                               task("Cancel the engine process", 2, "New")],
                    ),
                    story(
                        "Reveal recent exports in Finder",
                        area="App", sprint=NOV, state="New", points=1, tags=("app", "reports"),
                        description="Keep the last ten exports with a Reveal in Finder button.",
                        ac=("Missing files are shown as missing, not removed",),
                        tasks=[task("Recent exports list", 1, "New")],
                    ),
                ],
            ),
            feature(
                "Sprint history",
                "Browse every iteration and compare sprints.",
                area="App",
                state="New",
                tags=("app", "sprints"),
                children=[
                    story(
                        "Group sprints into Current, Upcoming and Past",
                        area="App", sprint=OCT, state="Active", points=3, tags=("app", "sprints"),
                        description="Each sprint opens in the same layout as the home view.",
                        ac=("Past sprints are newest first", "Upcoming sprints are soonest first"),
                        tasks=[task("Group by timeFrame", 1, "Closed"),
                               task("Sprint detail navigation", 2, "Active")],
                    ),
                    story(
                        "Velocity chart across past sprints",
                        area="App", sprint=DEC, state="New", points=8, tags=("app", "sprints", "reports"),
                        description="Closed story points per sprint for the last six sprints.",
                        ac=("Uses iteration-closed-stories for each past sprint",),
                        assigned=False,
                    ),
                    story(
                        "Burndown for the current sprint",
                        area="App", sprint=None, state="New", points=13, tags=("app", "sprints", "reports"),
                        description="Remaining work by day. Needs a new engine command for daily snapshots.",
                        ac=("Shows remaining hours per day of the sprint",),
                        priority=3,
                        assigned=False,
                    ),
                ],
            ),
        ],
    ),
    epic(
        "Distribution and updates",
        "Get ADO Desk onto Macs and keep it current.",
        area="App",
        state="Active",
        children=[
            feature(
                "Release pipeline",
                "Conventional Commits, release-please, and signed DMG and zip builds.",
                area="App",
                state="Closed",
                tags=("release",),
                children=[
                    story(
                        "Version releases with release-please",
                        area="App", sprint=OCT, state="Closed", points=3, tags=("release", "ci"),
                        description="A release PR tracks the next version and changelog from commit messages.",
                        ac=("Merging the release PR tags vX.Y.Z", "CI rejects non-conventional commit subjects"),
                        tasks=[task("Add the release-please workflow", 2, "Closed"),
                               task("Add the commit message check", 1, "Closed")],
                    ),
                    story(
                        "Self-signed builds with SHA-256 checksums",
                        area="App", sprint=OCT, state="Closed", points=3, tags=("release", "security"),
                        description="Sign with the ADO Desk Dev certificate and publish SHA256SUMS with each release.",
                        ac=("install.sh refuses a download whose checksum does not match",),
                        tasks=[task("release.sh --self-signed", 2, "Closed"),
                               task("Checksum verification in install.sh", 1, "Closed")],
                    ),
                ],
            ),
            feature(
                "Self-update",
                "Check GitHub releases and install updates after asking.",
                area="App",
                state="Active",
                tags=("release", "app"),
                children=[
                    story(
                        "Check GitHub releases once a day",
                        area="App", sprint=OCT, state="Closed", points=5, tags=("release", "app"),
                        description="First check a minute after launch, then daily. Can be turned off in Settings.",
                        ac=("No check runs when updates are turned off",
                            "Pre-releases are ignored"),
                        tasks=[task("Release feed parsing", 2, "Closed"),
                               task("Version comparison", 2, "Closed"),
                               task("Daily scheduler", 1, "Closed")],
                    ),
                    story(
                        "Install an update after asking",
                        area="App", sprint=OCT, state="Resolved", points=5, tags=("release", "app"),
                        description="Download, verify the checksum, replace the app and relaunch.",
                        ac=("The user is asked before anything is downloaded",
                            "A checksum mismatch aborts the install"),
                        tasks=[task("Download and verify", 3, "Closed"),
                               task("Replace and relaunch", 2, "Closed")],
                    ),
                    story(
                        "Notarize releases with a Developer ID",
                        area="App", sprint=None, state="New", points=5, tags=("release",),
                        description="Removes the \"damaged\" warning for browser downloads. Needs an Apple Developer account.",
                        ac=("A browser-downloaded DMG opens without xattr",),
                        priority=3,
                        assigned=False,
                    ),
                    story(
                        "Ship through the Mac App Store",
                        area="App", sprint=None, state="Removed", points=8, tags=("release",),
                        description="Dropped: the sandbox would block running python3 and the bundled script.",
                        ac=("Not applicable",),
                        priority=4,
                        assigned=False,
                        comments=("Removing: App Store sandboxing rules out spawning python3.",),
                    ),
                ],
            ),
        ],
    ),
]


def walk(items: list[Item], depth: int = 0):
    for item in items:
        yield item, depth
        yield from walk(item.children, depth + 1)


def state_path(item: Item) -> list[str]:
    """The updates needed after creation to reach item.state (New is the start)."""
    if item.state == "New":
        return []
    if item.state == "Removed":
        return ["Removed"]
    path = STATE_PATHS.get(item.type, STATE_PATHS["default"])
    return path[1 : path.index(item.state) + 1]


class Seeder:
    def __init__(self, client: AdoClient | None, project: str, team: str, assignee: str, dry_run: bool) -> None:
        self.client = client
        self.project = project
        self.team = team
        self.assignee = assignee
        self.dry_run = dry_run
        self.sprints = {sprint_key(y, m): (fy, y, m) for fy, y, m in SPRINTS}

    # --- paths -------------------------------------------------------------

    def area_path(self, sub: str | None = None) -> str:
        return "\\".join(p for p in (self.project, AREA_ROOT, sub) if p)

    def iteration_path(self, key: str | None) -> str:
        if key is None:
            return self.project  # the backlog: no sprint
        fy, y, m = self.sprints[key]
        return "\\".join((self.project, AREA_ROOT, fy, sprint_name(y, m)))

    def _node_url(self, group: str, *segments: str) -> str:
        quoted = "/".join(urllib.parse.quote(s, safe="") for s in segments)
        return f"wit/classificationnodes/{group}/{quoted}".rstrip("/")

    def ensure_node(self, group: str, parents: tuple[str, ...], name: str, attributes: dict | None = None) -> dict:
        """Return the classification node parents/name, creating it if needed."""
        label = "\\".join((*parents, name))
        if self.dry_run:
            print(f"  {group[:-1]} {self.project}\\{label}")
            return {}
        try:
            node = self.client.request("GET", f"{self._node_url(group, *parents, name)}?api-version={API_VERSION}")
            print(f"  {group[:-1]} {self.project}\\{label} (exists)")
            return node
        except AdoApiError as err:
            if err.status != 404:
                raise
        payload: dict[str, Any] = {"name": name}
        if attributes:
            payload["attributes"] = attributes
        node = self.client.request("POST", f"{self._node_url(group, *parents)}?api-version={API_VERSION}", payload=payload)
        print(f"  {group[:-1]} {self.project}\\{label} (created)")
        return node

    def setup_paths(self) -> None:
        print("Areas and iterations")
        self.ensure_node("areas", (), AREA_ROOT)
        for sub in SUB_AREAS:
            self.ensure_node("areas", (AREA_ROOT,), sub)

        self.ensure_node("iterations", (), AREA_ROOT)
        sprint_ids: list[str] = []
        for fy in dict.fromkeys(fy for fy, _, _ in SPRINTS):
            self.ensure_node("iterations", (AREA_ROOT,), fy)
        for fy, y, m in SPRINTS:
            last = calendar.monthrange(y, m)[1]
            node = self.ensure_node(
                "iterations",
                (AREA_ROOT, fy),
                sprint_name(y, m),
                {"startDate": f"{y}-{m:02d}-01T00:00:00Z", "finishDate": f"{y}-{m:02d}-{last:02d}T00:00:00Z"},
            )
            if node.get("identifier"):
                sprint_ids.append(node["identifier"])

        print(f"Team settings for {self.team!r}")
        if self.dry_run:
            print(f"  select {len(SPRINTS)} sprints; set the team area to {self.area_path()} (with sub-areas)")
            return

        selected = self.client.team_request("GET", f"work/teamsettings/iterations?api-version={API_VERSION}", team=self.team)
        selected_ids = {it.get("id") for it in selected.get("value", [])}
        for sprint_id in sprint_ids:
            if sprint_id not in selected_ids:
                self.client.team_request(
                    "POST", f"work/teamsettings/iterations?api-version={API_VERSION}", team=self.team, payload={"id": sprint_id}
                )
        print(f"  {len(sprint_ids)} sprints selected for the team")

        values = self.client.team_request("GET", f"work/teamfieldvalues?api-version={API_VERSION}", team=self.team)
        if values.get("defaultValue") != self.area_path():
            self.client.team_request(
                "PATCH",
                f"work/teamfieldvalues?api-version={API_VERSION}",
                team=self.team,
                payload={"defaultValue": self.area_path(), "values": [{"value": self.area_path(), "includeChildren": True}]},
            )
        print(f"  team area is {self.area_path()} (with sub-areas)")

    # --- items -------------------------------------------------------------

    def seeded_ids(self) -> list[int]:
        wiql = (
            "SELECT [System.Id] FROM WorkItems "
            "WHERE [System.TeamProject] = @project "
            f"AND [System.Tags] CONTAINS '{SEED_TAG}'"
        )
        result = self.client.request("POST", f"wit/wiql?api-version={API_VERSION}", payload={"query": wiql})
        return [w["id"] for w in result.get("workItems", [])]

    def check_secondary_assignee(self) -> None:
        try:
            self.client.request("GET", f"wit/fields/Custom.SecondaryAssignee?api-version={API_VERSION}")
            print("Custom.SecondaryAssignee exists: the app's Secondary assignee field will work.")
        except AdoApiError as err:
            if err.status != 404:
                raise
            print("Note: Custom.SecondaryAssignee is missing, so creating with a Secondary assignee will fail with "
                  "VALIDATION_ERROR. See docs/TEST_BOARD.md, step 2.")

    def create(self, item: Item, parent_id: int | None) -> int:
        tags = "; ".join((SEED_TAG, *item.tags))
        fields: dict[str, Any] = {
            "System.Title": item.title,
            "System.Description": ado_cli.format_description_html(item.description),
            "System.AreaPath": self.area_path(item.area),
            "System.IterationPath": self.iteration_path(item.sprint),
            "System.Tags": tags,
            "Microsoft.VSTS.Common.Priority": item.priority,
        }
        if item.type == "Bug":
            fields["Microsoft.VSTS.TCM.ReproSteps"] = fields["System.Description"]
        if item.ac:
            fields["Microsoft.VSTS.Common.AcceptanceCriteria"] = ado_cli.format_acceptance_criteria(list(item.ac))
        if item.points is not None:
            fields["Microsoft.VSTS.Scheduling.StoryPoints"] = item.points
        if item.hours is not None:
            done = item.state == "Closed"
            fields["Microsoft.VSTS.Scheduling.OriginalEstimate"] = item.hours
            fields["Microsoft.VSTS.Scheduling.RemainingWork"] = 0 if done else item.hours
            fields["Microsoft.VSTS.Scheduling.CompletedWork"] = item.hours if done else 0
        if self.assignee and item.assigned and item.sprint and item.type in ("User Story", "Task", "Bug"):
            fields["System.AssignedTo"] = self.assignee

        ops = [{"op": "add", "path": f"/fields/{name}", "value": value} for name, value in fields.items()]
        if parent_id is not None:
            ops.append({
                "op": "add",
                "path": "/relations/-",
                "value": {"rel": "System.LinkTypes.Hierarchy-Reverse", "url": self._item_api_url(parent_id)},
            })
        work_item_type = urllib.parse.quote(item.type, safe="")
        data = self.client.request(
            "POST", f"wit/workitems/${work_item_type}?api-version={API_VERSION}",
            payload=ops, content_type="application/json-patch+json",
        )
        item_id = int(data["id"])

        # One update per state so the item's history (and export-modifications) looks real.
        for state in state_path(item):
            self.client.request(
                "PATCH", f"wit/workitems/{item_id}?api-version={API_VERSION}",
                payload=[{"op": "add", "path": "/fields/System.State", "value": state}],
                content_type="application/json-patch+json",
            )
        for text in item.comments:
            self.client.request(
                "POST", f"wit/workItems/{item_id}/comments?api-version={COMMENT_API_VERSION}", payload={"text": text}
            )
        return item_id

    def _item_api_url(self, item_id: int) -> str:
        project = urllib.parse.quote(self.project, safe="")
        return f"{self.client.cfg.org}/{project}/_apis/wit/workItems/{item_id}"

    def seed_items(self) -> None:
        print("Work items")
        total = sum(1 for _ in walk(BACKLOG))
        done = 0

        def seed(items: list[Item], parent_id: int | None, depth: int) -> None:
            nonlocal done
            for item in items:
                where = item.sprint and sprint_name(*self.sprints[item.sprint][1:]) or "Backlog"
                line = f"{'  ' * depth}{item.type}: {item.title}  [{item.state}, {where}]"
                if self.dry_run:
                    print(f"  {line}")
                    seed(item.children, None, depth + 1)
                    continue
                item_id = self.create(item, parent_id)
                done += 1
                print(f"  [{done}/{total}] #{item_id} {line}")
                seed(item.children, item_id, depth + 1)

        seed(BACKLOG, None, 0)

    def cleanup(self) -> None:
        ids = self.seeded_ids()
        print(f"Moving {len(ids)} seeded work items to the Recycle Bin")
        for item_id in sorted(ids, reverse=True):
            self.client.request("DELETE", f"wit/workitems/{item_id}?api-version={API_VERSION}")
            print(f"  deleted #{item_id}")


def summarize() -> str:
    counts: dict[str, int] = {}
    for item, _ in walk(BACKLOG):
        counts[item.type] = counts.get(item.type, 0) + 1
    plural = {"User Story": "User Stories"}
    return ", ".join(f"{n} {plural.get(t, t + 's') if n != 1 else t}" for t, n in counts.items())


def confirm(prompt: str) -> bool:
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Seed an Azure DevOps sandbox project with an ADO Desk test board.")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be created; make no requests")
    parser.add_argument("--skip-paths", action="store_true", help="Don't create areas, iterations or team settings")
    parser.add_argument("--skip-items", action="store_true", help="Don't create work items")
    parser.add_argument("--cleanup", action="store_true", help="Move previously seeded items to the Recycle Bin and stop")
    parser.add_argument("--force", action="store_true", help="Seed even if seeded items already exist")
    parser.add_argument("--assignee", help="Who sprint items are assigned to (default: ADO_ASSIGNEE)")
    parser.add_argument("--team", help="Team to configure (default: ADO_TEAM, else '<project> Team')")
    parser.add_argument("--yes", "-y", action="store_true", help="Don't ask for confirmation")
    args = parser.parse_args(argv)

    try:
        cfg = ado_cli.load_config()
    except ValueError as err:
        if not args.dry_run:
            print(f"Configuration error: {err}", file=sys.stderr)
            return 1
        cfg = None

    project = cfg.project if cfg else "<project>"
    team = args.team or (cfg.team if cfg else "") or f"{project} Team"
    assignee = args.assignee if args.assignee is not None else (cfg.assignee if cfg else "")
    client = AdoClient(cfg) if cfg else None
    seeder = Seeder(client, project, team, assignee, args.dry_run)

    print(f"Organization: {cfg.org if cfg else '<org>'}")
    print(f"Project:      {project}")
    print(f"Team:         {team}")
    print(f"Assignee:     {assignee or '(none: sprint items stay unassigned)'}")
    print(f"Backlog:      {summarize()}")
    print(f"Today:        {date.today().isoformat()} (sprints run {sprint_name(*SPRINTS[0][1:])} to {sprint_name(*SPRINTS[-1][1:])})")
    print()

    try:
        if args.cleanup:
            if args.dry_run:
                print("Dry run: would move every item tagged ado-desk-seed to the Recycle Bin.")
                return 0
            if not args.yes and not confirm(f"Move every item tagged {SEED_TAG} in {project} to the Recycle Bin?"):
                print("Cancelled.")
                return 1
            seeder.cleanup()
            return 0

        if not args.dry_run:
            if not args.skip_items:
                existing = seeder.seeded_ids()
                if existing and not args.force:
                    print(f"{len(existing)} items tagged {SEED_TAG} already exist. Run with --cleanup first, "
                          "or --force to add another copy.", file=sys.stderr)
                    return 1
            if not args.yes and not confirm(f"Seed the test board into {project}? Use a sandbox project only."):
                print("Cancelled.")
                return 1

        if not args.skip_paths:
            seeder.setup_paths()
            print()
        if not args.skip_items:
            if not args.dry_run:
                seeder.check_secondary_assignee()
            seeder.seed_items()
    except AdoApiError as err:
        code, message = ado_cli.map_api_error(err)
        print(f"\n{code}: {message}", file=sys.stderr)
        return 1
    except ado_cli.CliError as err:
        print(f"\n{err.code}: {err.message}", file=sys.stderr)
        return 1

    if not args.dry_run:
        print(f"\nDone. Open {cfg.org}/{urllib.parse.quote(project)}/_boards to see the board.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
