#!/usr/bin/env python3
"""Stateful command fixtures for the release orchestration consumer tests."""

import json
import os
import pathlib
import sys
import zipfile

name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = pathlib.Path(os.environ["RELEASE_FIXTURE_STATE"])
state = json.loads(state_path.read_text())
state["calls"].append([name, *args])


def save():
    state_path.write_text(json.dumps(state))


def fail(message, code=1):
    save()
    print(message, file=sys.stderr)
    sys.exit(code)


def stage(value):
    if os.environ.get("RELEASE_FIXTURE_STOP") == value:
        fail("fixture failure at " + value, 42)
    if os.environ.get("RELEASE_FIXTURE_SIGNAL_STAGE") == value:
        os.kill(state["release_pid"], int(os.environ["RELEASE_FIXTURE_SIGNAL"]))
        sys.exit(0)


if name == "security":
    command = args[0]
    if command == "list-keychains":
        if "-s" in args:
            paths = args[args.index("-s") + 1:]
            if paths == state["original"] and os.environ.get("RELEASE_FIXTURE_RESTORE_FAIL"):
                fail("fixture restoration failure", 53)
            state["search"] = paths
            save()
            if paths != state["original"]:
                stage("search-list")
        else:
            state["release_pid"] = os.getppid()
            if os.environ.get("RELEASE_FIXTURE_CAPTURE_FAIL"):
                fail("fixture capture failure", 54)
            listing = "\n".join('    "' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'
                                for path in state["search"])
            print(os.environ.get("RELEASE_FIXTURE_LISTING", listing))
    elif command == "create-keychain":
        path = pathlib.Path(args[-1])
        path.touch()
        state["created"] = str(path)
        # Creation can change the list even before explicit search-list inclusion.
        if os.environ.get("RELEASE_FIXTURE_CREATE_MUTATES"):
            state["search"].append(str(path))
        save()
        stage("create-keychain")
    elif command == "delete-keychain":
        path = args[-1]
        if path != state.get("created"):
            fail("attempted deletion of a foreign keychain")
        pathlib.Path(path).unlink(missing_ok=True)
        state["search"] = [item for item in state["search"] if item != path]
    elif command == "import":
        if pathlib.Path(args[1]).read_bytes() != b"fixture certificate":
            fail("missing fixture certificate")
        state["identity"] = args[args.index("-k") + 1]
    elif command == "find-identity":
        print('  1) FIXTURE "' + os.environ["DEVELOPER_ID_APPLICATION_IDENTITY"] + '"')
    elif command not in ("set-keychain-settings", "unlock-keychain", "set-key-partition-list"):
        fail("unexpected security command")
elif name == "build-app.sh":
    stage("build")
    app = pathlib.Path(os.environ["RELEASE_FIXTURE_ROOT"]) / "fixture.app"
    app.mkdir(exist_ok=True)
    (app / "executable").write_text("fixture executable")
    print(app)
elif name == "codesign":
    if "--sign" in args:
        stage("sign")
        keychain = args[args.index("--keychain") + 1]
        if keychain != state.get("identity") or keychain not in state["search"]:
            fail("The specified item could not be found in the keychain.", 44)
        state["signed"] = True
    elif "--display" in args:
        print("Authority=" + os.environ["DEVELOPER_ID_APPLICATION_IDENTITY"])
        print("TeamIdentifier=" + os.environ["APPLE_TEAM_ID"])
        print("flags=0x10000(runtime)")
    elif not state.get("signed"):
        fail("bundle is not signed")
elif name == "smoke-app.sh":
    if not (pathlib.Path(args[0]) / "executable").is_file():
        fail("missing fixture bundle executable")
elif name == "ditto":
    if "-c" in args:
        with zipfile.ZipFile(args[-1], "w") as archive:
            archive.write(pathlib.Path(args[-2]) / "executable", "Pane Switcher for Rex.app/executable")
    else:
        with zipfile.ZipFile(args[-2]) as archive:
            archive.extractall(args[-1])
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        if pathlib.Path(args[args.index("--key") + 1]).read_text() != "fixture private key":
            fail("missing fixture notary key")
        print(json.dumps({"id": "fixture", "status": "Accepted"}))
    elif args[0] != "stapler":
        fail("unexpected xcrun command")
elif name == "spctl":
    if not state.get("signed"):
        fail("bundle is not signed")
else:
    fail("unexpected fixture command: " + name)
save()
