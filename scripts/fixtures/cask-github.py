#!/usr/bin/env python3
"""Local GitHub service model for the cask publication consumer tests; never uses the network."""

import base64
import hashlib
import json
import os
import pathlib
import re
import sys

state_path = pathlib.Path(os.environ["CASK_FIXTURE_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]


def save():
    state_path.write_text(json.dumps(state))


def fail(message):
    save()
    print(message, file=sys.stderr)
    sys.exit(1)


def options(arguments):
    positional, values, fields = [], {}, {}
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value == "--draft":
            values[value] = True
        elif value.startswith("-"):
            index += 1
            if index == len(arguments):
                fail("missing option value")
            if value in ("-f", "-F"):
                key, content = arguments[index].split("=", 1)
                fields[key] = content
            else:
                values[value] = arguments[index]
        else:
            positional.append(value)
        index += 1
    return positional, values, fields


def operation(name, mutates=False):
    if mutates:
        state["write_attempts"] += 1
        if repository != state["writable_repository"]:
            fail("token cannot write this repository")
    if os.environ.get("CASK_FIXTURE_FAIL") == name:
        fail("GitHub service unavailable during " + name)


def commit(files):
    sha = hashlib.sha1(json.dumps(files, sort_keys=True).encode()).hexdigest()
    repo["commits"][sha] = files
    return sha


def blob(content):
    return {"content": content, "sha": hashlib.sha1(content.encode()).hexdigest()}


if args[:1] == ["api"]:
    positional, flags, fields = options(args[1:])
    if len(positional) != 1 or not positional[0].startswith("repos/"):
        fail("unsupported GitHub endpoint")
    parts = positional[0].split("/", 3)
    repository = "/".join(parts[1:3])
    endpoint = parts[3] if len(parts) == 4 else ""
    if repository not in state["repositories"]:
        fail("repository not found")
    repo = state["repositories"][repository]
    method = flags.get("--method", "POST" if fields else "GET")
    if method == "GET" and not endpoint:
        operation("repository")
        response = {"default_branch": repo["default_branch"]}
    elif method == "GET" and endpoint.startswith("git/ref/heads/"):
        operation("base")
        branch = endpoint.removeprefix("git/ref/heads/")
        if branch not in repo["branches"]:
            fail("reference not found")
        response = {"object": {"sha": repo["branches"][branch]}}
    elif method == "GET" and endpoint.startswith("git/trees/"):
        operation("tree")
        sha = endpoint.removeprefix("git/trees/").split("?", 1)[0]
        if sha not in repo["commits"]:
            fail("commit not found")
        response = {"tree": [{"path": path, "sha": value["sha"]}
                             for path, value in repo["commits"][sha].items()]}
    elif method == "POST" and endpoint == "git/refs":
        operation("create-branch", mutates=True)
        branch = fields["ref"].removeprefix("refs/heads/")
        if branch in repo["branches"]:
            fail("reference already exists")
        if fields["sha"] not in repo["commits"]:
            fail("commit not found")
        repo["branches"][branch] = fields["sha"]
        response = {"ref": fields["ref"]}
    elif method == "PUT" and endpoint.startswith("contents/"):
        operation("put-content", mutates=True)
        branch = fields["branch"]
        path = endpoint.removeprefix("contents/")
        if branch not in repo["branches"]:
            fail("reference not found")
        files = dict(repo["commits"][repo["branches"][branch]])
        if os.environ.get("CASK_FIXTURE_CONCURRENT_EDIT"):
            files[path] = blob("reviewer's concurrent cask edit\n")
            repo["branches"][branch] = commit(files)
        existing = files.get(path)
        if existing is not None and fields.get("sha") != existing["sha"]:
            fail("cask blob SHA conflict")
        if existing is None and "sha" in fields:
            fail("cannot supply a blob SHA for an absent cask")
        files[path] = blob(base64.b64decode(fields["content"], validate=True).decode())
        repo["branches"][branch] = commit(files)
        response = {"content": {"sha": files[path]["sha"]}}
    else:
        fail("unsupported GitHub operation")
    query = flags.get("--jq")
    if query == ".default_branch":
        print(response["default_branch"])
    elif query == ".object.sha":
        print(response["object"]["sha"])
    elif query is not None:
        match = re.fullmatch(r'\.tree\[\] \| select\(\.path == "([^"]+)"\) \| \.sha', query)
        if match is None:
            fail("unsupported fixture JSON projection")
        for entry in response["tree"]:
            if entry["path"] == match[1]:
                print(entry["sha"])
    else:
        print(json.dumps(response))
elif args[:2] == ["pr", "create"]:
    positional, flags, fields = options(args[2:])
    repository = flags["--repo"]
    if repository not in state["repositories"]:
        fail("repository not found")
    repo = state["repositories"][repository]
    operation("create-pr", mutates=True)
    base, head = flags["--base"], flags["--head"]
    if base not in repo["branches"] or head not in repo["branches"]:
        fail("pull request reference not found")
    if repo["branches"][base] == repo["branches"][head]:
        fail("no commits between pull request branches")
    if any(pr["head"] == head for pr in repo["pull_requests"]):
        fail("pull request already exists")
    repo["pull_requests"].append({
        "base": base, "head": head, "draft": flags.get("--draft", False),
        "title": flags["--title"], "body": pathlib.Path(flags["--body-file"]).read_text(),
    })
    print(f"https://github.com/{repository}/pull/{len(repo['pull_requests'])}")
else:
    fail("unsupported fixture command")
save()
