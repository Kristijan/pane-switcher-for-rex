#!/usr/bin/env python3
"""Consumer tests for release input failures and generated Homebrew artifacts."""

import hashlib
import json
import os
import pathlib
import plistlib
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


if __name__ == "__main__":
    unittest.main()
