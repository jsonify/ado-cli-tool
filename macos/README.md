# ADO Desk: macOS app for `ado_cli.py`

ADO Desk is a native SwiftUI app. It runs `ado_cli.py` in the background and shows the results in a window. The app does not reimplement any Azure DevOps logic. Each action runs the script as a subprocess, then decodes the JSON envelope the script prints (`success`, `result`, `error`).

## Features

| Sidebar        | Engine command(s)                                   |
| -------------- | --------------------------------------------------- |
| Work Item      | `get`, `update`, `comment`, `delete`                |
| Create         | `create` (and `iteration-pick` for the iteration)   |
| Iterations     | `iteration-list`, `iteration-get`, `iteration-update-goal`, `iteration-closed-stories` |
| Sprint Report  | `iteration-closed-stories`, with a "Copy as Markdown" summary |
| Pick Iteration | `iteration-pick`                                    |
| Exports        | `export-closed-stories`, `export-modifications`     |
| Activity       | Every engine call, with its command line and raw JSON output |

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ or the Swift 5.9+ command-line tools
- `python3` 3.9+ (the Xcode Command Line Tools, Homebrew, or python.org). The engine uses only the standard library.

## Run it

```bash
cd macos
swift run                # development: uses ../ado_cli.py from this checkout
./build-app.sh           # builds macos/build/ADO Desk.app with ado_cli.py bundled
open "build/ADO Desk.app"
```

To work in Xcode, open `macos/Package.swift` and run the `ADODesk` scheme.

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

The `.app` contains a copy of `ado_cli.py` taken at build time. If you change the script, re-run `./build-app.sh`, or set **Engine → Script** to the file in your checkout so the app always uses the current version.
