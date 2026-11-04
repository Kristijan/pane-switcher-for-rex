#!/usr/bin/env python3
"""Consumer tests for release inputs, signing lifecycle, artifacts, and tap publication."""

import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
import zipfile

SUPPORT = pathlib.Path(__file__).with_name("release-support.py")


class ReleaseCommands(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.plist = self.root / "Info.plist"
        self.write_plist()

    def write_plist(self, version="1.0.0"):
        self.plist.write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version,
            "CFBundleIdentifier": "com.kristijan.paneswitch",
            "CFBundleExecutable": "PaneSwitch",
            "LSMinimumSystemVersion": "15.0",
        }))

    def run_command(self, *arguments):
        return subprocess.run([sys.executable, str(SUPPORT), *arguments], text=True, capture_output=True, check=False)

    def validate(self, *arguments):
        return self.run_command("validate", "--plist", str(self.plist), *arguments)

    def test_matching_release_reports_bundle_version(self):
        result = self.validate("--tag", "v1.0.0", "--architectures", "arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.0.0\n")

    def test_invalid_version_stops_release(self):
        for version in ("1.0", "01.0.0", "1.0.0-beta.1", "1.0.0+build", "v1.0.0", "1.0.0\n"):
            with self.subTest(version=version):
                self.write_plist(version)
                result = self.validate()
                self.assertNotEqual(result.returncode, 0)

    def test_tag_must_match_bundle_version(self):
        for tag in ("v1.0.1", "1.0.0", "refs/tags/v1.0.0"):
            with self.subTest(tag=tag):
                result = self.validate("--tag", tag)
                self.assertNotEqual(result.returncode, 0)

    def test_intel_universal_and_missing_architectures_stop_release(self):
        for architectures in ("x86_64", "arm64 x86_64", "", "arm64e"):
            with self.subTest(architectures=architectures):
                result = self.validate("--architectures", architectures)
                self.assertNotEqual(result.returncode, 0)

    def test_cask_contains_actual_archive_digest_and_public_contract(self):
        archive = self.root / "Pane-Switcher-for-Rex-1.0.0-arm64.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("Pane Switcher for Rex.app/Contents/Info.plist", self.plist.read_bytes())
        output = self.root / "Casks" / "pane-switcher-for-rex.rb"
        result = self.run_command("cask", "--version", "1.0.0", "--zip", str(archive), "--output", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        loaded = subprocess.run(
            ["brew", "ruby", "-e",
             'require "cask/cask_loader"; puts JSON.generate(Cask::CaskLoader.load(File.read(ARGV.fetch(0))).to_h)',
             str(output)],
            env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_DEVELOPER": "1"},
            text=True, capture_output=True,
        )
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        cask = json.loads(loaded.stdout)
        self.assertEqual(cask["sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(cask["version"], "1.0.0")
        self.assertEqual(cask["url"], "https://github.com/Kristijan/pane-switcher-for-rex/releases/download/v1.0.0/Pane-Switcher-for-Rex-1.0.0-arm64.zip")
        self.assertEqual(cask["depends_on"]["arch"], [{"type": "arm", "bits": 64}])
        self.assertEqual(cask["depends_on"]["macos"], {">=": ["15"]})
        artifacts = cask["artifacts"]
        app = next(item["app"] for item in artifacts if "app" in item)
        self.assertEqual(app, ["Pane Switcher for Rex.app"])
        uninstall = next(item["uninstall"][0] for item in artifacts if "uninstall" in item)
        self.assertEqual(uninstall["quit"], "com.kristijan.paneswitch")
        self.assertNotIn("launchctl", uninstall, "Ordinary upgrades must preserve the login preference")
        zap = next(item["zap"][0] for item in artifacts if "zap" in item)
        self.assertEqual(zap["launchctl"], "com.kristijan.paneswitch")

    def test_cask_refuses_missing_archive_or_wrong_asset_name(self):
        output = self.root / "pane-switcher-for-rex.rb"
        for name in ("Pane-Switcher-for-Rex-1.0.0-arm64.zip", "wrong.zip"):
            with self.subTest(name=name):
                result = self.run_command("cask", "--version", "1.0.0", "--zip", str(self.root / name), "--output", str(output))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_cask_refuses_non_zip_input(self):
        archive = self.root / "Pane-Switcher-for-Rex-1.0.0-arm64.zip"
        archive.write_text("This is not a release archive.")
        output = self.root / "pane-switcher-for-rex.rb"
        result = self.run_command("cask", "--version", "1.0.0", "--zip", str(archive), "--output", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())


class ReleaseOrchestration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        source = pathlib.Path(__file__).parent
        for name in ("release.sh", "release-support.py"):
            shutil.copy2(source / name, scripts / name)
        resources = self.root / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleIdentifier": "com.kristijan.paneswitch",
            "CFBundleExecutable": "PaneSwitch",
            "LSMinimumSystemVersion": "15.0",
        }))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fixture = source / "fixtures/release-command.py"
        for name in ("security", "codesign", "ditto", "xcrun", "spctl"):
            (self.bin / name).symlink_to(fixture.resolve())
        for name in ("build-app.sh", "smoke-app.sh"):
            (scripts / name).symlink_to(fixture.resolve())
        self.original = ["/Users/fixture/Library/Keychains/login with spaces.keychain-db",
                         '/Library/Keychains/quoted "name" and \\ slash.keychain',
                         "/tmp/$(touch SHOULD_NOT_EXIST); 'literal'.keychain"]
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"original": self.original, "search": self.original, "calls": []}))
        self.temp = self.root / "temporary files"
        self.temp.mkdir()
        self.environment = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "TMPDIR": str(self.temp),
            "RELEASE_FIXTURE_ROOT": str(self.root),
            "RELEASE_FIXTURE_STATE": str(self.state),
            "APPLE_CERTIFICATE_P12_BASE64": "Zml4dHVyZSBjZXJ0aWZpY2F0ZQ==",
            "APPLE_CERTIFICATE_PASSWORD": "fixture password",
            "DEVELOPER_ID_APPLICATION_IDENTITY": "Developer ID Application: Fixture (FIXTURE)",
            "APPLE_TEAM_ID": "FIXTURE",
            "NOTARY_KEY_ID": "fixture",
            "NOTARY_ISSUER_ID": "fixture",
            "NOTARY_PRIVATE_KEY": "fixture private key",
        }

    def release(self, **environment):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/release.sh"), "v1.0.0"],
            env={**self.environment, **environment}, cwd=self.root,
            text=True, capture_output=True, timeout=30,
        )

    def assert_cleaned(self):
        state = json.loads(self.state.read_text())
        self.assertEqual(state["search"], self.original)
        if "created" in state:
            self.assertFalse(pathlib.Path(state["created"]).exists())
        self.assertEqual(list(self.temp.iterdir()), [])
        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())
        return state

    def test_release_signs_with_searchable_identity_and_cleans_up(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.assert_cleaned()
        self.assertTrue(state["signed"])
        updates = [call[5:] for call in state["calls"] if call[:5] ==
                   ["security", "list-keychains", "-d", "user", "-s"]]
        self.assertEqual(updates, [[*self.original, state["created"]], self.original])
        self.assertEqual(len(list((self.root / "dist/1.0.0").iterdir())), 3)

    def test_empty_original_search_list_is_restored(self):
        self.original = []
        self.state.write_text(json.dumps({"original": [], "search": [], "calls": []}))
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_cleaned()

    def test_failures_restore_list_and_preserve_exit_status(self):
        for stage in ("create-keychain", "search-list", "build", "sign"):
            with self.subTest(stage=stage):
                result = self.release(RELEASE_FIXTURE_STOP=stage, RELEASE_FIXTURE_CREATE_MUTATES="1")
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assert_cleaned()

    def test_cancellation_restores_list_and_preserves_signal_status(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            for stage in ("create-keychain", "search-list", "build"):
                with self.subTest(signal=signum, stage=stage):
                    result = self.release(
                        RELEASE_FIXTURE_SIGNAL_STAGE=stage, RELEASE_FIXTURE_SIGNAL=str(signum),
                        RELEASE_FIXTURE_CREATE_MUTATES="1",
                    )
                    self.assertEqual(result.returncode, 128 + signum, result.stderr)
                    self.assert_cleaned()

    def test_capture_failure_or_malformed_snapshot_stops_before_mutation(self):
        for environment, expected in (
            ({"RELEASE_FIXTURE_CAPTURE_FAIL": "1"}, 54),
            ({"RELEASE_FIXTURE_LISTING": '"unterminated'}, 1),
            ({"RELEASE_FIXTURE_LISTING": '"relative.keychain"'}, 1),
        ):
            with self.subTest(environment=environment):
                result = self.release(**environment)
                self.assertEqual(result.returncode, expected, result.stderr)
                state = self.assert_cleaned()
                self.assertNotIn("created", state)
                self.assertTrue(all(call[:2] == ["security", "list-keychains"] and "-s" not in call
                                    for call in state["calls"]))

    def test_restoration_failure_retains_only_recoverable_snapshot(self):
        result = self.release(RELEASE_FIXTURE_STOP="build", RELEASE_FIXTURE_RESTORE_FAIL="1")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("Failed to restore user keychain search list", result.stderr)
        state = json.loads(self.state.read_text())
        self.assertFalse(pathlib.Path(state["created"]).exists())
        files = [path for path in self.temp.rglob("*") if path.is_file()]
        self.assertEqual([path.name for path in files], ["user-keychains.txt"])
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        recovery = subprocess.run(
            [sys.executable, str(self.root / "scripts/release-support.py"),
             "keychains", "--snapshot", str(files[0])],
            env=self.environment, text=True, capture_output=True,
        )
        self.assertEqual(recovery.returncode, 0, recovery.stderr)
        self.assertEqual(json.loads(self.state.read_text())["search"], self.original)

    def test_restoration_failure_fails_otherwise_successful_release(self):
        result = self.release(RELEASE_FIXTURE_RESTORE_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("recovery snapshot retained", result.stderr)
        self.assertFalse(any(path.name in ("certificate.p12", "notary-key.p8", "release.keychain-db")
                             for path in self.temp.rglob("*")))

    def test_restoration_failure_does_not_replace_cancellation_status(self):
        result = self.release(
            RELEASE_FIXTURE_SIGNAL_STAGE="build", RELEASE_FIXTURE_SIGNAL=str(signal.SIGTERM),
            RELEASE_FIXTURE_RESTORE_FAIL="1",
        )
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertIn("recovery snapshot retained", result.stderr)
        self.assertFalse(any(path.name in ("certificate.p12", "notary-key.p8", "release.keychain-db")
                             for path in self.temp.rglob("*")))


class CaskPublication(unittest.TestCase):
    APP_REPOSITORY = "Kristijan/pane-switcher-for-rex"
    TAP_REPOSITORY = "Kristijan/homebrew-pane-switcher-for-rex"
    CASK_PATH = "Casks/pane-switcher-for-rex.rb"
    BRANCH = "cask/v1.0.0"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cask publication ")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        source = pathlib.Path(__file__).parent
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("create-cask-pr.sh", "release-support.py"):
            shutil.copy2(source / name, scripts / name)
        resources = self.root / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleIdentifier": "com.kristijan.paneswitch",
            "CFBundleExecutable": "PaneSwitch",
            "LSMinimumSystemVersion": "15.0",
        }))
        self.artifacts = self.root / "release artifacts"
        self.artifacts.mkdir()
        self.archive = self.artifacts / "Pane-Switcher-for-Rex-1.0.0-arm64.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Pane Switcher for Rex.app/executable", "signed release fixture")
        self.checksum = self.archive.with_suffix(".zip.sha256")
        self.checksum.write_text(hashlib.sha256(self.archive.read_bytes()).hexdigest()
                                 + "  " + self.archive.name + "\n")
        self.manifest = self.artifacts / "pane-switcher-for-rex.rb"
        generated = subprocess.run(
            [sys.executable, str(scripts / "release-support.py"), "cask", "--version", "1.0.0",
             "--zip", str(self.archive), "--output", str(self.manifest)],
            text=True, capture_output=True,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "gh").symlink_to((source / "fixtures/cask-github.py").resolve())
        self.temp = self.root / "temporary files"
        self.temp.mkdir()
        self.state = self.root / "github.json"
        self.environment = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "TMPDIR": str(self.temp),
            "GH_TOKEN": "fixture tap-only token",
            "CASK_FIXTURE_STATE": str(self.state),
        }
        self.seed()

    def seed(self, existing=False, collision=False):
        files = {"README.md": self.blob("Dedicated public Homebrew tap\n")}
        if existing:
            files[self.CASK_PATH] = self.blob("previous published cask\n")
        tap = {
            "default_branch": "trunk", "branches": {"trunk": "base-commit"},
            "commits": {"base-commit": files}, "pull_requests": [],
        }
        if collision:
            reviewed = {**files, self.CASK_PATH: self.blob("already reviewed cask\n")}
            tap["commits"]["reviewed-commit"] = reviewed
            tap["branches"][self.BRANCH] = "reviewed-commit"
            tap["pull_requests"].append({
                "base": "trunk", "head": self.BRANCH, "draft": False,
                "title": "Reviewed work", "body": "Do not replace",
            })
        state = {
            "write_attempts": 0, "writable_repository": self.TAP_REPOSITORY,
            "repositories": {
                self.TAP_REPOSITORY: tap,
                self.APP_REPOSITORY: {
                    "default_branch": "main", "branches": {"main": "app-commit"},
                    "commits": {"app-commit": {"app.swift": self.blob("app source\n")}},
                    "pull_requests": [],
                },
            },
        }
        self.state.write_text(json.dumps(state))
        return state

    @staticmethod
    def blob(content):
        return {"content": content, "sha": hashlib.sha1(content.encode()).hexdigest()}

    def publish(self, tag="v1.0.0", **environment):
        result = subprocess.run(
            ["/bin/bash", str(self.root / "scripts/create-cask-pr.sh"), tag, str(self.artifacts)],
            env={**self.environment, **environment}, cwd=self.root,
            text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(list(self.temp.iterdir()), [], "publication left temporary files behind")
        return result

    def remote(self):
        return json.loads(self.state.read_text())

    def test_initial_publication_creates_only_a_draft_tap_update(self):
        before = self.seed()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.remote()
        self.assertEqual(state["repositories"][self.APP_REPOSITORY],
                         before["repositories"][self.APP_REPOSITORY])
        tap = state["repositories"][self.TAP_REPOSITORY]
        self.assertEqual(tap["branches"]["trunk"], "base-commit")
        files = tap["commits"][tap["branches"][self.BRANCH]]
        self.assertEqual(files[self.CASK_PATH]["content"], self.manifest.read_text())
        self.assertEqual(files["README.md"], before["repositories"][self.TAP_REPOSITORY]
                         ["commits"]["base-commit"]["README.md"])
        self.assertEqual(len(tap["pull_requests"]), 1)
        pr = tap["pull_requests"][0]
        self.assertTrue(pr["draft"])
        self.assertEqual((pr["base"], pr["head"]), ("trunk", self.BRANCH))
        self.assertIn("https://github.com/Kristijan/pane-switcher-for-rex/releases/tag/v1.0.0",
                      pr["body"])
        self.assertNotIn("homebrew-pane-switcher-for-rex/releases", pr["body"])

    def test_existing_cask_update_uses_the_existing_blob_precondition(self):
        before = self.seed(existing=True)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.remote()
        tap = state["repositories"][self.TAP_REPOSITORY]
        self.assertEqual(tap["commits"]["base-commit"],
                         before["repositories"][self.TAP_REPOSITORY]["commits"]["base-commit"])
        files = tap["commits"][tap["branches"][self.BRANCH]]
        self.assertEqual(files[self.CASK_PATH]["content"], self.manifest.read_text())
        self.assertEqual(len(tap["pull_requests"]), 1)
        self.assertEqual(state["repositories"][self.APP_REPOSITORY],
                         before["repositories"][self.APP_REPOSITORY])

    def test_concurrent_cask_edit_is_not_overwritten_or_proposed(self):
        self.seed(existing=True)
        result = self.publish(CASK_FIXTURE_CONCURRENT_EDIT="1")
        self.assertNotEqual(result.returncode, 0)
        state = self.remote()
        tap = state["repositories"][self.TAP_REPOSITORY]
        files = tap["commits"][tap["branches"][self.BRANCH]]
        self.assertEqual(files[self.CASK_PATH]["content"], "reviewer's concurrent cask edit\n")
        self.assertEqual(tap["pull_requests"], [])
        self.assertEqual(state["write_attempts"], 2)

    def test_invalid_release_artifacts_never_attempt_remote_mutation(self):
        original_archive = self.archive.read_bytes()
        original_manifest = self.manifest.read_bytes()
        original_checksum = self.checksum.read_bytes()
        for corruption in ("archive", "manifest", "invalid-zip", "tag"):
            with self.subTest(corruption=corruption):
                before = self.seed(existing=True)
                self.archive.write_bytes(original_archive)
                self.manifest.write_bytes(original_manifest)
                self.checksum.write_bytes(original_checksum)
                tag = "v1.0.0"
                if corruption == "archive":
                    self.archive.write_bytes(original_archive + b"corruption")
                elif corruption == "manifest":
                    self.manifest.write_text("untrusted manifest\n")
                elif corruption == "invalid-zip":
                    self.archive.write_text("not a ZIP")
                    self.checksum.write_text(hashlib.sha256(self.archive.read_bytes()).hexdigest()
                                             + "  " + self.archive.name + "\n")
                else:
                    tag = "v1.0.1"
                result = self.publish(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.remote(), before)

    def test_existing_branch_preserves_reviewed_work_without_creating_another_pr(self):
        before = self.seed(existing=True, collision=True)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        state = self.remote()
        self.assertEqual(state["repositories"], before["repositories"])
        self.assertEqual(state["write_attempts"], 1)

    def test_github_errors_stop_without_falling_through_to_a_pull_request(self):
        for stage, writes in (("repository", 0), ("base", 0), ("tree", 0),
                              ("create-branch", 1), ("put-content", 2)):
            with self.subTest(stage=stage):
                before = self.seed(existing=True)
                result = self.publish(CASK_FIXTURE_FAIL=stage)
                self.assertNotEqual(result.returncode, 0)
                state = self.remote()
                tap = state["repositories"][self.TAP_REPOSITORY]
                self.assertEqual(tap["pull_requests"], [])
                self.assertEqual(tap["commits"],
                                 before["repositories"][self.TAP_REPOSITORY]["commits"])
                self.assertEqual(state["write_attempts"], writes)
                if stage != "put-content":
                    self.assertEqual(state["repositories"], before["repositories"])
                else:
                    self.assertEqual(tap["branches"][self.BRANCH], "base-commit")
                self.assertEqual(state["repositories"][self.APP_REPOSITORY],
                                 before["repositories"][self.APP_REPOSITORY])


if __name__ == "__main__":
    unittest.main()
