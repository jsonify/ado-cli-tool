# Contributing to ADO Desk

The repository holds two things:

- `ado_cli.py`, the engine: a standard-library Python CLI for the Azure DevOps REST API. Its contract with the app
  (flags, `result` shapes, error codes) is in [docs/ENGINE_REFERENCE.md](docs/ENGINE_REFERENCE.md), which also
  explains how to add a command.
- `macos/`, the SwiftUI app (SwiftPM package `ADODesk`). [macos/README.md](macos/README.md) explains how the app runs
  the engine.

## Build and run

You need macOS 13 or later, Xcode 15+ (or the Swift 5.9+ command-line tools) and `python3` 3.9+.

```sh
cd macos
swift run                     # development: uses ../ado_cli.py from this checkout
Scripts/make_dev_cert.sh      # once: stable signing certificate (see below)
Scripts/build_app.sh --run    # builds macos/build/ADO Desk.app with ado_cli.py bundled, then opens it
```

To work in Xcode, open `macos/Package.swift` and run the `ADODesk` scheme.

| Script (in `macos/`) | What it does |
| --- | --- |
| `Scripts/build_app.sh [--run]` | Builds `build/ADO Desk.app`. `ADODESK_STRICT=1` makes warnings errors (CI does this). `CONFIG=debug` builds a debug binary. |
| `Scripts/make_dev_cert.sh` | Creates a self-signed **ADO Desk Dev** certificate, used automatically by `build_app.sh`. Without it, builds are signed ad-hoc and the app's identity changes on every build, so macOS asks again for access to the token in the Keychain. Override with `ADODESK_SIGN_IDENTITY`. |
| `Scripts/release.sh` | Signs, packages and (optionally) notarizes; see [Releases](#releases). |
| `Scripts/install.sh` | Installs or updates from the latest GitHub release. |

The `.app` contains a copy of `ado_cli.py` taken at build time. After changing the script, re-run
`Scripts/build_app.sh`, or set **Settings → Engine → Script** to the file in your checkout.

## Tests

```sh
cd macos && swift test
```

`Tests/ADODeskTests` covers logic that runs without a window, such as the updater's version comparison, release
parsing and checksums. CI builds and tests with warnings as errors, so builds must be warning-free.

To try the app against real data, set up a sandbox Azure DevOps project and fill it with a test backlog with
`scripts/seed_test_board.py`. [docs/TEST_BOARD.md](docs/TEST_BOARD.md) walks through it and has a test checklist for
each section of the app.

## Commit messages and versions

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org), such as `fix(app): ...`,
`feat(app): ...`, `docs: ...` or `ci: ...`, and a CI check enforces this on pull requests.
[release-please](https://github.com/googleapis/release-please) uses them to keep a release PR open with the next
version and the changelog:

- `fix` bumps the patch version.
- `feat` bumps the minor version.
- `feat!:` or a `BREAKING CHANGE:` footer bumps the major version. It bumps the minor version while below 1.0.

Merging the release PR tags `vX.Y.Z` and updates `CHANGELOG.md` and `version.txt`. CI then attaches a DMG and zip of
the signed app to the GitHub release, which is what the updater and `install.sh` download.

`build_app.sh` takes the version from `ADODESK_VERSION`, else the newest `vX.Y.Z` tag, else `version.txt`; the build
number from the commit count; and adds the short commit hash (with `+` when there are uncommitted changes).
**Settings → Updates** shows all three, for example `0.2.0 (412, 48db438)`.

## Releases

`macos/Scripts/release.sh` builds, signs, packages and (optionally) notarizes the app. It writes
`ADO-Desk-<version>.dmg`, `.zip` and `SHA256SUMS` to `macos/build/release/`. Run `Scripts/release.sh --help` for all
options.

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

## CI

The workflows in `.github/workflows/`:

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
