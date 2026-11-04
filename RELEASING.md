# Releasing

This repository contains the application and hosts its signed release assets. The separate [Homebrew tap](https://github.com/Kristijan/homebrew-pane-switcher-for-rex) contains `Casks/pane-switcher-for-rex.rb`. The release workflow builds an Apple Silicon app, signs it with Developer ID, notarizes it, and creates a **draft GitHub release here** plus a **draft cask-update PR in the tap**. A maintainer reviews and publishes the release before merging the tap PR.

No production release can be created until Apple signing and notarization credentials are configured. Development/PR builds are ad-hoc signed and are not public release artifacts.

## How Homebrew distribution works

A cask is a small Ruby manifest describing a prebuilt app's version, download URL, SHA-256, platform requirements, and installation/uninstallation behavior. Homebrew downloads the GitHub release ZIP from `Kristijan/pane-switcher-for-rex`; it does not compile Swift on the user's Mac. `scripts/release-support.py` generates the cask only from a real, finalized archive. The canonical committed cask lives in `Kristijan/homebrew-pane-switcher-for-rex`, not this repository. There is no placeholder checksum or `:no_check` cask.

Homebrew infers `https://github.com/Kristijan/homebrew-pane-switcher-for-rex` from the tap name `kristijan/pane-switcher-for-rex`. The tap needs only its cask; it does not contain Swift sources, app bundles, release ZIPs, or Apple credentials.

```sh
brew tap kristijan/pane-switcher-for-rex
brew install --cask kristijan/pane-switcher-for-rex/pane-switcher-for-rex
```

The fully qualified install command can also add the tap automatically and, on current Homebrew versions, trusts only this cask rather than the whole tap. The two-component name identifies the tap, not the cask. Future merged tap updates let users run `brew update` and `brew upgrade --cask kristijan/pane-switcher-for-rex/pane-switcher-for-rex`. Direct-download users replace the app manually.

References: [Taps](https://docs.brew.sh/Taps), [Creating and maintaining a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#casks), [Cask cookbook](https://docs.brew.sh/Cask-Cookbook), [Tap trust](https://docs.brew.sh/Tap-Trust), [official acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy#notability).

## One-time tap setup

1. Create **`Kristijan/homebrew-pane-switcher-for-rex`** as a **public** GitHub repository. Initialize it with a README so it has a default branch and initial commit; the release automation cannot create a branch in an empty repository. Use the repository's actual default branch, not an assumed branch name.
2. Seed `Casks/pane-switcher-for-rex.rb` with the cask from the already-public **v1.0.1** release. Download the ZIP, `.zip.sha256`, and `.rb` assets from [that release](https://github.com/Kristijan/pane-switcher-for-rex/releases/tag/v1.0.1). Verify the ZIP with `shasum -a 256 -c Pane-Switcher-for-Rex-1.0.1-arm64.zip.sha256`, regenerate the manifest with `scripts/release-support.py cask`, and compare it with the downloaded `.rb` before committing it to the tap. Keep its app-repository download URL and real checksum. No new app build, release tag, or ZIP upload is necessary.
3. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) owned by **Kristijan**. Under **Repository access**, choose **Only select repositories → homebrew-pane-switcher-for-rex**. Grant repository **Contents: Read and write** and **Pull requests: Read and write** only. Choose an expiration, store the token in 1Password, and arrange renewal before expiry. Do not grant app-repository writes, administration, or workflow-file permissions.
4. In the **application repository**, open **Settings → Environments → production-release → Environment secrets** and add **`HOMEBREW_TAP_TOKEN`**. Paste the token directly into GitHub, not into chat or a tracked file. Keep all existing Apple secrets in this application environment; the tap needs none.
5. Merge the reviewed automation/README cutover before creating the next release tag. The `cask` job uses the protected `production-release` environment and exposes the tap token only to the PR-creation step. The normal `GITHUB_TOKEN` remains read-only in that job; it cannot write to another repository.
6. After the seed cask is committed to the public tap, verify the installation commands above. For a full install test on a clean Mac, launch the signed app and exercise setup and local/remote pane selection. A manifest syntax check alone does not establish a working public download.

This is a clean cutover: no app-version bump, old-tap fallback, or user migration is required. The minimal tap has no CI workflow; review every cask update manually. If tap CI is added later, its checks belong to that repository, not the app repository's Swift CI. PAT-created PRs do not need the special workflow approval associated with `GITHUB_TOKEN`-created PRs, although ordinary repository policies still apply.

References: [Creating a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository), [refs require an initialized repository](https://docs.github.com/en/rest/git/refs#create-a-reference), [fine-grained tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [token permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens), [GITHUB_TOKEN scope and workflow events](https://docs.github.com/en/actions/concepts/security/github_token).

## One-time Apple setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/).
2. Create a **Developer ID Application** certificate with its private key. In Keychain Access, export the certificate **and private key** as a password-protected `.p12`. A development certificate, Developer ID Installer certificate, or ad-hoc identity is not a substitute.
3. Obtain a **team App Store Connect API key** for notarization, its key ID, issuer ID, and private `.p8` file. Retain the private key securely; do not commit it. Use a team key with issuer ID for this workflow rather than relying on differing individual-key support across tool versions.
4. Record the exact signing identity name, such as `Developer ID Application: Your Name (TEAMID)`, and the matching team ID.

The release script captures the original user keychain search list before creating a temporary keychain, then includes that keychain alongside all original entries. This makes the signing keychain available for certificate-chain lookup as well as explicit identity selection with `codesign --keychain`. It verifies identity/team membership and restores the original list on exit, including handled `INT`/`TERM` cancellation, before deleting its own temporary keychain and credential files. Run releases in an isolated runner/user session: restoring the snapshot would overwrite concurrent search-list edits. The script does not change the default keychain or certificate trust settings.

It signs with hardened runtime and a secure timestamp, requires Apple's notarization status to be **Accepted**, staples the app, and only then generates the distributed ZIP. No sandbox, Apple Events, JIT, or library-validation exception entitlement is enabled.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [notarization requirements](https://developer.apple.com/documentation/security/resolving-common-notarization-issues), [API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api), [GitHub Apple signing setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## One-time GitHub setup

In [repository settings](https://github.com/Kristijan/pane-switcher-for-rex/settings), configure:

1. **Environments → New environment → `production-release`.** Add a required human reviewer and restrict deployment to release tags matching `v*`, not arbitrary branches. Prevent self-review where practical. Signing secrets belong only in this environment.
2. Add these environment secrets:

   | Secret | Value |
   | --- | --- |
   | `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded exported `.p12`, including its private key |
   | `APPLE_CERTIFICATE_PASSWORD` | Nonempty password used when exporting the `.p12` |
   | `DEVELOPER_ID_APPLICATION_IDENTITY` | Full Developer ID Application certificate name |
   | `APPLE_TEAM_ID` | Matching Apple developer team ID |
   | `NOTARY_KEY_ID` | Team App Store Connect API key ID |
   | `NOTARY_ISSUER_ID` | Team API key issuer UUID |
   | `NOTARY_PRIVATE_KEY` | Full `.p8` PEM contents, including BEGIN/END lines |
   | `HOMEBREW_TAP_TOKEN` | Fine-grained PAT with Contents and Pull requests write access to `Kristijan/homebrew-pane-switcher-for-rex` only; see tap setup above |

3. **Actions → General → Workflow permissions:** keep the default token read-only. The draft-release job requests Contents write only in this application repository. The cross-repository cask job uses `HOMEBREW_TAP_TOKEN` instead of increasing `GITHUB_TOKEN` permissions.
4. Protect this repository's `main` with review and both required CI checks: **Tests and arm64 app** and **Workflow and shell syntax**. Review changes to `.github/workflows/` and `scripts/` as privileged release code. Cask-only PRs are opened in the separate tap.
5. Restrict creation, movement, and deletion of `v*` tags to release maintainers. Do not move an already published version tag.

Do not put signing secrets into PR jobs or run contributor code with them via `pull_request_target`. GitHub's release environment is the approval gate; public PR CI never needs those credentials. Actions are pinned to commit SHAs. CI/release use the official `macos-15` Apple Silicon runner and also assert the actual architecture at runtime.

References: [GitHub environment protection](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments), [workflow permissions](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository), [token-generated events](https://docs.github.com/en/actions/concepts/security/github_token), [runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Prepare and release a version

1. Open a version PR against `main`. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the stable version, and increment `CFBundleVersion` for a new build. Initial release: **1.0.0**, build **1**. The About page reads the bundle version automatically.
2. Run local checks and require successful PR CI:

   ```sh
   scripts/test.sh
   python3 scripts/test-release.py
   scripts/build-app.sh
   scripts/smoke-app.sh
   ```

3. Merge the reviewed release commit. Create and push its matching tag, for example:

   ```sh
   git tag -a v1.0.0 -m "Pane Switcher for Rex 1.0.0"
   git push origin v1.0.0
   ```

   Create the tag from the intended merged commit, not an unrelated local branch. The workflow rejects version/tag mismatches and non-arm64 output.

4. Approve the `production-release` environment deployment. The workflow tests the code, builds and signs the app, notarizes/staples it, checks the final extracted archive, and creates these draft assets:

   - `Pane-Switcher-for-Rex-1.0.0-arm64.zip`
   - `Pane-Switcher-for-Rex-1.0.0-arm64.zip.sha256`
   - `pane-switcher-for-rex.rb`

5. Inspect the Actions result and draft release. Download the actual ZIP and verify its checksum. Test the signed app on an Apple Silicon Mac, including first launch, setup, local/remote pane activation, About, and quitting. The workflow uses GitHub's automatically generated release notes, including merged pull requests and contributor attribution. Review/edit these notes before publication; generation does not publish the release.
6. **Publish the reviewed GitHub draft release.** Draft assets cannot be downloaded publicly by Homebrew.
7. Review the generated **draft cask PR in `Kristijan/homebrew-pane-switcher-for-rex`**. Check the version, release URL, and actual ZIP checksum, then mark it ready and merge it **only after the matching release is public**. Subsequent releases update the existing cask. If the tap has CI, require its checks to pass; the minimal tap does not run this application's CI.
8. Verify a real Homebrew install/upgrade and a direct download. Installation is not available until both the release assets in the app repository and the cask in the tap are public.

A manual retry may use an existing tag, selected as both the workflow ref and input:

```sh
gh workflow run release.yml --ref v1.0.0 -f tag=v1.0.0
```

Selecting `main` for that dispatch is intentionally rejected. The workflow never creates an arbitrary tag for you. See [GitHub release CLI](https://cli.github.com/manual/gh_release_create).

## Failures and safe retries

- Missing/invalid Apple credentials fail explicitly; there is no unsigned production fallback.
- A search-list restoration failure is reported and fails an otherwise successful command; an existing release failure/cancellation keeps its original exit status. Temporary signing/notarization credentials are still removed. Only the protected `user-keychains.txt` snapshot is retained at the printed recovery path. In the same user session, inspect that snapshot and restore it with:

  ```sh
  python3 scripts/release-support.py keychains --snapshot "/printed/recovery/path/user-keychains.txt"
  security list-keychains -d user
  ```

  After confirming the original list is restored, remove that snapshot and its empty containing directory. Do not `eval` the snapshot or split its paths on whitespace. Uncatchable termination (for example `SIGKILL` or host loss) cannot run shell cleanup; inspect the runner and remove only the release-owned temporary keychain/private directory if they survive.
- A retry at an existing tag runs the scripts pinned by that tag, not fixes subsequently merged to `main`. For a failed, unpublished release, a maintainer must deliberately choose whether to move the tag after reviewing all draft artifacts, or use a new version/tag. Never move an already published release tag; retrying it does not pick up this correction.
- The release script produces exactly three distribution files under `dist/MAJOR.MINOR.PATCH/`; it does not publish them by itself and refuses to overwrite an existing version directory. This is separate from SwiftPM's `.build/release` symlink. CI uploads only the explicitly named ZIP, checksum, and cask.
- Existing GitHub releases in the app repository or `cask/vX.Y.Z` branches in the tap are not overwritten automatically. Inspect drafts, branches, PRs, and the failed job before retrying or performing deliberate cleanup.
- If draft creation succeeded but cask creation failed, retain the reviewed assets and rerun only the failed portion after correcting tap access. Confirm that the tap is initialized and `HOMEBREW_TAP_TOKEN` is present, unexpired, and has Contents/Pull requests write permissions for the tap. Approve the cask job's environment deployment if requested. Do not rerun packaging or replace a published ZIP to fix a tap credential problem.
- Never replace an already-public ZIP under the same version. A changed binary means a new version, new checksum, and reviewed cask update.
- The ZIP contains only the app bundle, not repository files, signing keys, or local planning notes. Login registration is a `zap` action, not an ordinary uninstall action: Homebrew also runs ordinary uninstall actions during upgrades/reinstalls, which must preserve that preference. Disable Launch at login before uninstalling, or use `brew uninstall --cask --zap` to remove its registration together with app-owned settings/history.

Production signing/notarization and GitHub-hosted release execution must be verified with real credentials before the first public release. A green development build alone does not prove Gatekeeper/notarization acceptance.
