# ADO Desk: macOS app for `ado_cli.py`

ADO Desk is a native SwiftUI app. It runs `ado_cli.py` in the background and shows the results in a window. The app does not reimplement any Azure DevOps logic. Each action runs the script as a subprocess, then decodes the JSON envelope the script prints (`success`, `result`, `error`).

## Features

| Sidebar        | What it does | Engine command(s) |
| -------------- | ------------ | ----------------- |
| Current Sprint | Home. The team's current iteration: dates and days left, an editable sprint goal, closed and active story counts, and the closed stories with **Copy as Markdown**. | `iteration-list --timeframe=current`, `iteration-get`, `iteration-update-goal`, `iteration-closed-stories` |
| Work Items     | Recently opened items (type an ID to open one) next to an inline editor. Changed fields are highlighted, and a bar offers **Discard** or **Save** (⌘S). Post comments, open in the browser, delete from the ⋯ menu. | `get`, `update`, `comment`, `delete` |
| Sprints        | Iterations grouped Current / Upcoming / Past, each shown like the home view. | `iteration-list`, plus the above |
| Reports        | Closed-stories and modifications exports, and a list of recent exports with **Reveal in Finder**. | `export-closed-stories`, `export-modifications` |

Also:

- **New Work Item** (⌘N or the + toolbar button) opens a sheet. The Iteration field offers the current sprint and an `iteration-pick` suggestion for the area path, so there's no separate picking step. **Create another** keeps the sheet open with placement and assignment filled in.
- **Command palette** (⌘K): open an item by ID or title, create an item, jump to a section, or show the activity log. Return runs the first match.
- **Engine status** sits at the bottom of the sidebar. Click it (or press ⇧⌘Y) for the activity drawer, which lists every engine call with its command line, duration and raw JSON output.
- ⌘1–⌘4 switch sections.
- The first launch shows a setup card for the organization, project, team and token, or an existing `.env` file.

Recent items and exports are remembered in the app's preferences. The engine has no "list my work items" command, so the Work Items list holds the items you've opened, created or updated in ADO Desk. Area and iteration are read-only in the editor because `update` doesn't change them.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ or the Swift 5.9+ command-line tools
- `python3` 3.9+ (the Xcode Command Line Tools, Homebrew, or python.org). The engine uses only the standard library.

## Run it

```bash
cd macos
swift run                     # development: uses ../ado_cli.py from this checkout
Scripts/make_dev_cert.sh      # once: stable signing certificate (see below)
Scripts/build_app.sh --run    # builds macos/build/ADO Desk.app with ado_cli.py bundled, then opens it
```

To work in Xcode, open `macos/Package.swift` and run the `ADODesk` scheme.

## Build and release

| Script | What it does |
| --- | --- |
| `Scripts/build_app.sh [--run]` | Builds `build/ADO Desk.app`. `ADODESK_STRICT=1` makes warnings errors (CI does this). `ADODESK_VERSION` sets the marketing version, and the build number is the short commit hash. `CONFIG=debug` builds a debug binary. |
| `Scripts/make_dev_cert.sh` | Creates a self-signed **ADO Desk Dev** certificate, used automatically by `build_app.sh`. Without it, builds are signed ad-hoc and the app's identity changes on every build, so macOS asks again for access to the token in the Keychain. Override with `ADODESK_SIGN_IDENTITY`. |
| `Scripts/release.sh` | Signs with a Developer ID (hardened runtime, `Resources/ADODesk.entitlements`), notarizes, staples, and writes `ADO-Desk-<version>.dmg`, `.zip` and `SHA256SUMS` to `build/release/`. Run `Scripts/release.sh --help` for the credentials it needs. `--skip-notarize` signs and packages only. |

CI (`.github/workflows/`):

- **Build** runs on every push to `main` and on pull requests. It checks that `ado_cli.py` compiles and starts, builds the app with warnings as errors on the newest Xcode, and uploads `ADO Desk.app` as an artifact.
- **Release** runs when a `v*` tag is pushed (`git tag v0.2.0 && git push origin v0.2.0`). It runs `release.sh` and attaches the DMG and zip to a draft GitHub release. The repository secrets it needs are listed at the top of `release.yml`.

## Configure

Open **Settings** (⌘,):

- **Connection**: organization, project, team, and a personal access token. The token is stored in the macOS Keychain and given to the engine as `ADO_TOKEN`.
- **Defaults**: assignee, area path, and iteration path (`ADO_ASSIGNEE`, `ADO_AREA_PATH`, `ADO_ITERATION_PATH`).
- **Engine**: the Python interpreter, the script location, an optional `.env` file (`ADO_ENV_FILE`), and an optional CA bundle (`SSL_CERT_FILE`). **Verify Engine** checks that the script can be found and launched.

The app passes a variable to the engine only when its field is filled in. If you already have a `.env` file, you can leave the fields blank and point **Engine → .env file** at it. The script then reads it the same way it does on the command line.

## How the bridge works

- The script location is checked in this order: the **Script** setting, then the copy bundled in `ADO Desk.app/Contents/Resources`, then the repository checkout (when started with `swift run`).
- Arguments are always passed as `--flag=value`. This keeps Markdown values that start with `-` (bullet lists, for example) from being read as options by argparse.
- The engine runs in `~/Library/Application Support/ADODesk`, so relative paths it writes end up there. Exports in the app always pass an absolute `--output` path.
- GUI apps don't inherit your shell's `PATH`. The app adds `/opt/homebrew/bin` and `/usr/local/bin` so it can find `python3`. To use a specific interpreter, set **Engine → Python**.

For each command's flags, `result` shape, error codes and quirks, see [`docs/ENGINE_REFERENCE.md`](../docs/ENGINE_REFERENCE.md).

The `.app` contains a copy of `ado_cli.py` taken at build time. If you change the script, re-run `Scripts/build_app.sh`, or set **Engine → Script** to the file in your checkout so the app always uses the current version.
