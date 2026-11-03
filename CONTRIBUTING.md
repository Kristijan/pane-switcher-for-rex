# Contributing

## Local development

Use an Apple Silicon Mac running macOS 15 or later, with Swift 6-compatible Xcode or Command Line Tools. The app is Swift/AppKit with no third-party Swift package dependencies.

Release-tool tests additionally require Python 3 and Homebrew; they load generated casks through Homebrew's real DSL rather than comparing Ruby source text.

```sh
scripts/test.sh
python3 scripts/test-release.py
scripts/build-app.sh
scripts/smoke-app.sh
```

`build-app.sh` creates `.build/Pane Switcher for Rex.app`, explicitly builds arm64, and uses ad-hoc signing for development. `smoke-app.sh` checks the packaged bundle and executes its early-exit help path without starting AppKit, changing preferences, or connecting to Rex.

To exercise the UI, quit any installed copy first, then open the development bundle. All copies intentionally share the same bundle ID and preferences. Setup appears on a fresh installation; existing configurations are retained. For UI changes, exercise the real picker and Settings, not only the core tests. In particular, check keyboard focus, first-launch setup, error recovery, cancellation, and light/dark appearance.

The suite does not require a running Rex instance. Live picker tests do require Rex and its local server. macOS privacy permissions used by external test automation are not application requirements.

The AppKit interaction tests dispatch real local mouse events through the picker, including its host-suggestion child window and nested children. For live UI checks, type `host:`, click a suggestion, and confirm that it inserts a host pill without dismissing the picker; clicks in an unrelated window must still dismiss it.

When exercising picker cancellation, interrupt an in-flight opening lookup with Settings or Setup, then request the picker again before the old lookup finishes. The cancelled invocation must neither present a picker nor clear the replacement lookup's ownership; repeated shortcut presses must not start concurrent replacement lookups.

### Application data

Settings (`config.json`) and recent-pane history (`recent-panes.json`) live in `~/Library/Application Support/Pane Switcher for Rex/`.

Use isolated temporary storage directories in tests. Homebrew's optional `--zap` cleanup includes this directory.

## Pull requests

Open a PR against `main`. CI runs on every PR, including changes confined to release scripts or workflows:

- **Tests and arm64 app:** release-input/cask tests, the full Swift suite, arm64 app build, bundle/executable smoke checks, and ZIP extraction/cask generation.
- **Workflow and shell syntax:** Bash syntax checks and Actionlint for all GitHub workflows.

PR checks use a read-only token and no Apple signing/notarization secrets. Do not use `pull_request_target` to run contributor code with privileged credentials. Changes to release scripts and workflows require especially careful review.

Keep tests deterministic and independent of personal host names, running Rex sessions, credentials, and user preferences. Cover behavior and failure modes rather than incidental UI wording or implementation details. Do not commit `.build`, credentials, exported certificates, notarization keys, or local environment files.

For concurrent transport tests, hold fixture requests behind explicit release signals rather than fixed sleeps. The queued-deadline test releases its active request only after the queued request expires, so CI scheduling delays cannot accidentally send that request.

An unsent request whose deadline expires reports `RexConnectionError.queueExpired`; it must not disconnect the worker or clear the backend inventory. In-flight timeouts still disconnect because their outcome is unknown. The backend regression holds a real worker request while a client lookup reaches its normal 8-second deadline, then verifies cached panes and worker reuse.

Warm-cache discovery refresh failures retain pending listing/session work and retry without requiring another event. Retries back off from 250 ms to a maximum of 8 seconds, resetting after a successful refresh. Recovery tests must cover request errors, malformed responses, and invalidations arriving while a snapshot is in flight; non-disconnecting failures must preserve cached panes and the connection.

## Releases

Public releases use a separate, protected, tag-based workflow; CI's ad-hoc app is not a production download. See [RELEASING.md](RELEASING.md) for the one-time Apple/GitHub setup and the release → review → publish → Homebrew cask PR sequence.

Update `Resources/Info.plist` for a new stable version. The `vMAJOR.MINOR.PATCH` release tag must exactly match `CFBundleShortVersionString`. No Intel or universal-binary release is supported. The app checks GitHub Releases when Settings opens but never installs updates. Update-check tests use isolated HTTP fixtures, not the live API.
