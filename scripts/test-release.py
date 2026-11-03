#!/usr/bin/env python3
"""Consumer tests for release inputs, keychain lifecycle, and Homebrew artifacts."""

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


if __name__ == "__main__":
    unittest.main()
