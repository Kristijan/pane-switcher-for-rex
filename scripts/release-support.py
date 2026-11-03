#!/usr/bin/env python3
"""Validate releases, manage temporary keychain search lists, and generate casks."""

import argparse
import hashlib
import pathlib
import plistlib
import re
import shlex
import subprocess
import sys
import zipfile

REPOSITORY = "Kristijan/pane-switcher-for-rex"
APP_NAME = "Pane Switcher for Rex.app"
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", re.ASCII)


def validate_version(version, tag=None):
    if not VERSION.fullmatch(version):
        raise ValueError("version must be stable MAJOR.MINOR.PATCH without leading zeroes")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"tag {tag!r} must match bundle version v{version}")
    return version


def validate_architectures(architectures):
    if architectures.split() != ["arm64"]:
        raise ValueError(f"expected arm64-only binary, found {architectures!r}")


def validate_bundle(plist_path, tag, architectures):
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    version = validate_version(info.get("CFBundleShortVersionString", ""), tag)
    expected = {
        "CFBundleIdentifier": "com.kristijan.paneswitch",
        "CFBundleExecutable": "PaneSwitch",
        "LSMinimumSystemVersion": "15.0",
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"{key} must be {value!r}, found {info.get(key)!r}")
    if architectures is not None:
        validate_architectures(architectures)
    return version


def generate_cask(version, archive, output):
    validate_version(version)
    filename = f"Pane-Switcher-for-Rex-{version}-arm64.zip"
    if archive.name != filename:
        raise ValueError(f"release archive must be named {filename}")
    if not archive.is_file() or archive.stat().st_size == 0:
        raise ValueError("release archive must be an existing, nonempty ZIP")
    if not zipfile.is_zipfile(archive):
        raise ValueError("release archive must be a valid ZIP")
    # Stream the finalized (notarized and stapled) ZIP rather than accepting a supplied digest.
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    sha256 = digest.hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(f'''cask "pane-switcher-for-rex" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/{REPOSITORY}/releases/download/v#{{version}}/Pane-Switcher-for-Rex-#{{version}}-arm64.zip"
  name "Pane Switcher for Rex"
  desc "Native pane picker for Rex"
  homepage "https://github.com/{REPOSITORY}"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "{APP_NAME}"

  uninstall quit: "com.kristijan.paneswitch"

  zap launchctl: "com.kristijan.paneswitch",
      trash: [
        "~/Library/Application Support/Pane Switcher for Rex",
        "~/Library/Preferences/com.kristijan.paneswitch.plist",
        "~/Library/Saved Application State/com.kristijan.paneswitch.savedState",
      ]
end
''', encoding="utf-8")
    return sha256


def keychain_list(snapshot, append=None, check=False):
    # security prints quoted paths. Parse quoting without evaluating shell syntax or
    # splitting paths containing spaces; subprocess passes each path as one argument.
    paths = shlex.split(snapshot.read_text(encoding="utf-8"), comments=False, posix=True)
    if any(not path.startswith("/") or "\0" in path for path in paths):
        raise ValueError("keychain snapshot must contain absolute paths")
    if check:
        return
    if append is not None:
        paths.append(str(append))
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *paths], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate bundle identity, version, and optional architecture")
    validate.add_argument("--plist", type=pathlib.Path, required=True)
    validate.add_argument("--tag")
    validate.add_argument("--architectures")
    cask = commands.add_parser("cask", help="generate a concrete Homebrew cask from a finalized ZIP")
    cask.add_argument("--version", required=True)
    cask.add_argument("--zip", dest="archive", type=pathlib.Path, required=True)
    cask.add_argument("--output", type=pathlib.Path, required=True)
    keychains = commands.add_parser("keychains", help="check or restore a user keychain search-list snapshot")
    keychains.add_argument("--snapshot", type=pathlib.Path, required=True)
    action = keychains.add_mutually_exclusive_group()
    action.add_argument("--append", type=pathlib.Path)
    action.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            print(validate_bundle(args.plist, args.tag, args.architectures))
        elif args.command == "keychains":
            keychain_list(args.snapshot, args.append, args.check)
        else:
            print(generate_cask(args.version, args.archive, args.output))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"release: {error}\n")
    except subprocess.CalledProcessError as error:
        parser.exit(error.returncode, f"release: keychain search-list update failed ({error.returncode})\n")


if __name__ == "__main__":
    main()
