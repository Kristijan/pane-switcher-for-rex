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

The build and test scripts use SwiftPM's default build engine (Swift Build with Swift 6.4) without an explicit engine override or silent fallback. `test.sh` adds the installed CLT Swift Testing framework and nested macro-plugin search path when present, so both core and AppKit interaction tests compile and run under Swift Build. Keep the Command Line Tools or Xcode installation selected by `xcode-select` complete and working; use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per command to select a provisioned Xcode instead.

If Swift Build fails before compilation with `SessionFailedError`, “Could not initialize build system,” and “Unknown error parsing property list,” inspect the selected installation's SDKs. Swift Build's [CLT platform discovery](https://github.com/swiftlang/swift-build/blob/swift-6.4.2-RELEASE/Sources/SWBApplePlatform/PluginDCLT.swift#L44-L66) reads settings from every entry in the CLT `SDKs` directory, so selecting a valid SDK with `--sdk` does not bypass an incomplete neighboring SDK. See also [SwiftPM issue #10561](https://github.com/swiftlang/swift-package-manager/issues/10561).

On the development host, the incomplete, root-owned `MacOSX12.3.sdk` lacked `SDKSettings.plist`. With administrator authorization, only that directory was moved from `/Library/Developer/CommandLineTools/SDKs/` to `/Library/Developer/CommandLineTools/DisabledSDKs/MacOSX12.3.sdk`, preserving its contents outside SDK discovery. Other SDKs were left untouched. If this problem recurs, have an administrator verify and repair the incomplete SDK or quarantine it outside `SDKs` to an unused destination without deleting its contents; then rerun the app build, full test suite, and packaged-app smoke check above with the default engine.

To exercise the UI, quit any installed copy first, then open the development bundle. All copies intentionally share the same bundle ID and preferences. Setup appears on a fresh installation; existing configurations are retained. For UI changes, exercise the real picker and Settings, not only the core tests. In particular, check keyboard focus, first-launch setup, error recovery, cancellation, and light/dark appearance.

The suite does not require a running Rex instance. Live picker tests do require Rex and its local server. macOS privacy permissions used by external test automation are not application requirements.

For startup checks, distinguish no running Rex application from several running copies with none focused. The former should instruct the user to open Rex; the latter should request that they focus the intended copy. Test the no-Rex case in an isolated session rather than terminating a developer's active Rex session.

Remote host-discovery warnings describe the latest lookup, not historical failures. A successful lookup replaces or clears only those warnings, including in an already-open picker and when reopening it; metadata, refresh, and other host warnings remain independent. The footer shows concise guidance, with full lookup details available in its tooltip and debug diagnostics.

The AppKit interaction tests dispatch real local mouse events through the picker, including its host-suggestion child window and nested children. For live UI checks, type `host:`, click a suggestion, and confirm that it inserts a host pill without dismissing the picker; clicks in an unrelated window must still dismiss it.

When exercising picker cancellation, interrupt an in-flight opening lookup with Settings or Setup, then request the picker again before the old lookup finishes. The cancelled invocation must neither present a picker nor clear the replacement lookup's ownership; repeated shortcut presses must not start concurrent replacement lookups.

With the global shortcut enabled, open the picker from another app, enter a query and select a pane, then press the shortcut again. The existing picker must regain focus without changing the query or selected pane, and Escape must return to the app from which that picker session originally opened. Opening Settings must continue to dismiss the picker rather than reuse its session.

### Search behavior

Each whitespace-separated query token must fuzzy-match entirely within one metadata field: pane label, title, command, directory, host label, session label, or window label. Different tokens may match different fields, in any order. Matching is case- and diacritic-insensitive; a host-label-only match is valid. For example, `docker` must not be assembled from `Desktop` in the directory, `Local` in the host label, and `picker` in the session label.

Ranking sums each token's best individual-field score, favoring contiguous and word-boundary matches over scattered characters. Repeating a match in multiple fields does not add points, and a field's position in the metadata list does not penalize its match. Equal scores retain deterministic local/host/session/window/pane ordering. Host/location operators still filter inventory separately; highlighting traces each token independently within each displayed line and excludes filter operators and host arguments.

Normalize fields and cache their character/boundary data when inventory changes, not on every keystroke. Query scoring reuses scratch buffers across fields, panes, and tokens, sized to the longest individual field. Keep the cross-field rejection, same-field fuzzy, multiword cross-field, ranking, filter, and Unicode/highlight regressions when changing search.

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
