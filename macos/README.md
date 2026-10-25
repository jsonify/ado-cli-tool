# ADO Desk: the macOS app

This folder is the SwiftUI app. For what it does and how to install it, see the [main README](../README.md); for
building, testing and releasing, see [CONTRIBUTING.md](../CONTRIBUTING.md).

The app does not reimplement any Azure DevOps logic. Each action runs `ado_cli.py` as a subprocess, then decodes the
JSON envelope the script prints (`success`, `result`, `error`).

| Section | Engine command(s) |
| --- | --- |
| Current Sprint | `iteration-list --timeframe=current`, `iteration-get`, `iteration-update-goal`, `iteration-closed-stories` |
| Work Items | `get`, `update`, `comment`, `delete` |
| New Work Item | `create`, `iteration-pick` |
| Sprints | `iteration-list`, plus the Current Sprint commands |
| Reports | `export-closed-stories`, `export-modifications` |

Recent items and exports are remembered in the app's preferences. The engine has no "list my work items" command, so
the Work Items list holds the items you've opened, created or updated in ADO Desk. Area and iteration are read-only in
the editor because `update` doesn't change them.

## How the bridge works

- The script location is checked in this order: the **Script** setting, then the copy bundled in `ADO Desk.app/Contents/Resources`, then the repository checkout (when started with `swift run`).
- Settings are passed to the engine as environment variables (`ADO_ORG`, `ADO_PROJECT`, `ADO_TEAM`, `ADO_TOKEN`, `ADO_ASSIGNEE`, `ADO_AREA_PATH`, `ADO_ITERATION_PATH`, `ADO_ENV_FILE`, `SSL_CERT_FILE`), and only when their field is filled in, so the engine's own `.env` fallback still applies. The token comes from the Keychain.
- Arguments are always passed as `--flag=value`. This keeps Markdown values that start with `-` (bullet lists, for example) from being read as options by argparse.
- The engine runs in `~/Library/Application Support/ADODesk`, so relative paths it writes end up there. Exports in the app always pass an absolute `--output` path.
- GUI apps don't inherit your shell's `PATH`. The app adds `/opt/homebrew/bin` and `/usr/local/bin` so it can find `python3`. To use a specific interpreter, set **Engine → Python**.

For each command's flags, `result` shape, error codes and quirks, see [`docs/ENGINE_REFERENCE.md`](../docs/ENGINE_REFERENCE.md).
