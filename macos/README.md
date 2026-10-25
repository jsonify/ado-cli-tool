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

## Install

Run this in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/jsonify/ado-cli-tool/main/macos/Scripts/install.sh | bash
```

It downloads the latest release, checks it against the release's checksums, installs it in **Applications** and
opens it. Run the same command again to update, or use **ADO Desk → Check for Updates…**: ADO Desk also checks a
minute after it opens and then once a day, and asks before installing (turn that off in **Settings → Updates**).
An update replaces the app only when its checksum matches and it is signed with the same certificate as the copy
you're running; your settings and the token in the Keychain stay.

Releases without a Developer ID are signed with ADO Desk's own certificate. Every release has the same certificate,
so macOS keeps letting ADO Desk read your token after an update. macOS only checks apps downloaded in a browser, and
calls a browser-downloaded copy of such a release "damaged". If you downloaded the DMG or zip from the
[Releases](https://github.com/jsonify/ado-cli-tool/releases) page instead, drag ADO Desk into **Applications** and run
this once before opening it:

```sh
xattr -dr com.apple.quarantine "/Applications/ADO Desk.app"
```

To build it yourself, see [Run it](#run-it).

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
| `Scripts/build_app.sh [--run]` | Builds `build/ADO Desk.app`. `ADODESK_STRICT=1` makes warnings errors (CI does this). `CONFIG=debug` builds a debug binary. |
| `Scripts/make_dev_cert.sh` | Creates a self-signed **ADO Desk Dev** certificate, used automatically by `build_app.sh`. Without it, builds are signed ad-hoc and the app's identity changes on every build, so macOS asks again for access to the token in the Keychain. Override with `ADODESK_SIGN_IDENTITY`. |
| `Scripts/release.sh` | Signs, packages and (optionally) notarizes; see [Releases](#releases). |
| `Scripts/install.sh` | Installs or updates from the latest GitHub release; see [Install](#install). |

Tests: `swift test` (in `macos/`) runs `Tests/ADODeskTests`, which cover logic that runs without a window, such as the
updater's version comparison, release parsing and checksums.

### Versions and commit messages

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org), such as `fix(app): ...`,
`feat(app): ...`, `docs: ...` or `ci: ...`, and a CI check enforces this on pull requests.
[release-please](https://github.com/googleapis/release-please) uses them to keep a release PR open with the next
version and the changelog:

- `fix` bumps the patch version.
- `feat` bumps the minor version.
- `feat!:` or a `BREAKING CHANGE:` footer bumps the major version. It bumps the minor version while below 1.0.

Merging the release PR tags `vX.Y.Z` and updates `CHANGELOG.md` and `version.txt` (at the repository root). CI then
attaches a DMG and zip of the signed app to the GitHub release, which is what the updater and `install.sh` download.

`build_app.sh` takes the version from `ADODESK_VERSION`, else the newest `vX.Y.Z` tag, else `version.txt`; the build
number from the commit count; and adds the short commit hash (with `+` when there are uncommitted changes).
**Settings → Updates** shows all three, for example `0.2.0 (412, 48db438)`.

### Releases

`Scripts/release.sh` builds, signs, packages and (optionally) notarizes the app. It writes
`ADO-Desk-<version>.dmg`, `.zip` and `SHA256SUMS` to `build/release/`. Run `Scripts/release.sh --help` for all options.

- **With an Apple Developer ID.** Signing uses your Developer ID Application certificate with the hardened runtime
  (`Resources/ADODesk.entitlements`), then notarizes and staples the app. Credentials come from your keychain or
  environment, never from the repo:

  ```sh
  xcrun notarytool store-credentials adodesk-notary --apple-id you@example.com --team-id TEAMID   # once
  ADODESK_NOTARY_PROFILE=adodesk-notary Scripts/release.sh --version 0.2.0
  ```

  If you have several Developer ID identities, pick one with `ADODESK_DEVELOPER_ID`. `--skip-notarize` signs and
  packages only.

- **Without a developer account.** Run `Scripts/release.sh --self-signed` to sign the app with the "ADO Desk Dev"
  certificate instead. macOS calls a browser download of such an app "damaged", so people install with
  `Scripts/install.sh` or the in-app updater, which don't mark the download as quarantined. The DMG stays unsigned,
  because macOS refuses to open a disk image signed with a certificate Apple didn't issue. CI does this automatically
  when the Developer ID secrets are not set. To set it up for CI, export the **ADO Desk Dev** certificate that
  `Scripts/make_dev_cert.sh` created from Keychain Access as a `.p12`. It is the one that expires 10 years out and lists
  **Code Signing** under Extended Key Usage; the release build refuses a certificate that isn't for code signing. Add
  the `.p12` as the repository secret `SELF_SIGNED_P12_BASE64` (base64-encoded, `base64 -i cert.p12 | pbcopy`) and its
  password as `SELF_SIGNED_P12_PASSWORD`, then delete the `.p12` file. Keep the certificate itself: the updater only
  installs releases signed with the same certificate as the running copy, and a new one would also make macOS ask
  everyone again for access to their token.

CI (`.github/workflows/`):

- **Build** runs on every push to `main` and on pull requests. It checks that `ado_cli.py` compiles and starts, runs
  `swift test` and builds the app with warnings as errors on the newest Xcode, and uploads `ADO Desk.app` as an
  artifact.
- **Commit messages** checks that every commit in a pull request is a Conventional Commit.
- **Release Please** runs on every push to `main` and keeps the release PR up to date. Merging it creates the release
  and runs **Release**. It needs **Settings → Actions → General → Allow GitHub Actions to create and approve pull
  requests**.
- **Release** builds and signs the release (Developer ID and notarized, or self-signed when those secrets aren't set)
  and attaches the DMG, zip and `SHA256SUMS` to the GitHub release. It also runs when a `v*` tag is pushed by hand
  (that makes a draft release), and from **Actions → Release → Run workflow** to rebuild a tag whose build failed. The
  secrets it needs are listed at the top of `release.yml`.

## Configure

Open **Settings** (⌘,):

- **Connection**: organization, project, team, and a personal access token. The token is stored in the macOS Keychain and given to the engine as `ADO_TOKEN`.
- **Defaults**: assignee, area path, and iteration path (`ADO_ASSIGNEE`, `ADO_AREA_PATH`, `ADO_ITERATION_PATH`).
- **Engine**: the Python interpreter, the script location, an optional `.env` file (`ADO_ENV_FILE`), and an optional CA bundle (`SSL_CERT_FILE`). **Verify Engine** checks that the script can be found and launched.
- **Updates**: the running version, **Check for updates automatically** (on by default), and **Check Now**.

The app passes a variable to the engine only when its field is filled in. If you already have a `.env` file, you can leave the fields blank and point **Engine → .env file** at it. The script then reads it the same way it does on the command line.

## How the bridge works

- The script location is checked in this order: the **Script** setting, then the copy bundled in `ADO Desk.app/Contents/Resources`, then the repository checkout (when started with `swift run`).
- Arguments are always passed as `--flag=value`. This keeps Markdown values that start with `-` (bullet lists, for example) from being read as options by argparse.
- The engine runs in `~/Library/Application Support/ADODesk`, so relative paths it writes end up there. Exports in the app always pass an absolute `--output` path.
- GUI apps don't inherit your shell's `PATH`. The app adds `/opt/homebrew/bin` and `/usr/local/bin` so it can find `python3`. To use a specific interpreter, set **Engine → Python**.

For each command's flags, `result` shape, error codes and quirks, see [`docs/ENGINE_REFERENCE.md`](../docs/ENGINE_REFERENCE.md).

The `.app` contains a copy of `ado_cli.py` taken at build time. If you change the script, re-run `Scripts/build_app.sh`, or set **Engine → Script** to the file in your checkout so the app always uses the current version.
