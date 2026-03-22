#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
WORKFLOW_NAME = "Zig CI"
POLL_SECONDS = 3
POLL_TIMEOUT_SECONDS = 180


def run(
    *args: str, env: dict[str, str] | None = None, check: bool = True
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        list(args),
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        command = " ".join(args)
        message = (
            result.stderr.strip()
            or result.stdout.strip()
            or f"exit {result.returncode}"
        )
        raise RuntimeError(f"{command}: {message}")
    return result


def main() -> int:
    tempdir: tempfile.TemporaryDirectory[str] | None = None
    branch = ""
    pushed = False

    def handle_signal(signum: int, _frame: object) -> None:
        raise KeyboardInterrupt(f"signal {signum}")

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        run("git", "rev-parse", "--show-toplevel")
        run("git", "remote", "get-url", "origin")
        run("gh", "auth", "status")
        repo = run(
            "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"
        ).stdout.strip()
        head = run("git", "rev-parse", "HEAD").stdout.strip()
        commit = head
        if run(
            "git", "status", "--porcelain=v1", "--untracked-files=all"
        ).stdout.strip():
            tempdir = tempfile.TemporaryDirectory(prefix="ci-py-")
            index_path = Path(tempdir.name) / "index"
            env = os.environ.copy()
            env["GIT_INDEX_FILE"] = str(index_path)

            run("git", "read-tree", "HEAD", env=env)
            run("git", "add", "-A", "--", ".", env=env)
            tree = run("git", "write-tree", env=env).stdout.strip()
            head_tree = run("git", "rev-parse", "HEAD^{tree}").stdout.strip()

            if tree == head_tree:
                tempdir.cleanup()
                tempdir = None
            else:
                commit = run(
                    "git",
                    "commit-tree",
                    tree,
                    "-p",
                    head,
                    "-m",
                    f"ci snapshot for {head}",
                    env=env,
                ).stdout.strip()

        branch = f"ci/{commit}"

        if (
            run(
                "git",
                "ls-remote",
                "--exit-code",
                "--heads",
                "origin",
                f"refs/heads/{branch}",
                check=False,
            ).returncode
            == 0
        ):
            raise RuntimeError(f"remote branch already exists: {branch}")

        print(f"snapshot: {commit}", flush=True)
        print(f"branch: {branch}", flush=True)

        pushed_after = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        print("pushing snapshot...", flush=True)
        run("git", "push", "origin", f"{commit}:refs/heads/{branch}")
        pushed = True

        print("waiting for workflow run...", flush=True)
        run_id: int | None = None
        deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
        while time.monotonic() < deadline and run_id is None:
            result = run(
                "gh",
                "run",
                "list",
                "--workflow",
                WORKFLOW_NAME,
                "--branch",
                branch,
                "--event",
                "push",
                "--json",
                "databaseId,headSha,createdAt",
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                for item in json.loads(result.stdout):
                    if item.get("headSha") != commit:
                        continue
                    if item.get("createdAt", "") < pushed_after:
                        continue
                    database_id = item.get("databaseId")
                    if isinstance(database_id, int):
                        run_id = database_id
                        break

            if run_id is None:
                time.sleep(POLL_SECONDS)

        if run_id is None:
            raise RuntimeError(f"timed out waiting for {WORKFLOW_NAME} run on {branch}")

        url = run(
            "gh",
            "api",
            f"repos/{repo}/actions/runs/{run_id}",
            "--jq",
            ".html_url",
        ).stdout.strip()
        print(f"run: {url}", flush=True)

        watch = subprocess.run(
            ["gh", "run", "watch", str(run_id), "--exit-status"],
            cwd=ROOT,
            check=False,
        )
        conclusion = run(
            "gh",
            "api",
            f"repos/{repo}/actions/runs/{run_id}",
            "--jq",
            ".conclusion // .status",
        ).stdout.strip()
        print(f"result: {conclusion}", flush=True)
        if watch.returncode == 0:
            try:
                if DIST.exists():
                    shutil.rmtree(DIST, ignore_errors=False)
                DIST.mkdir(exist_ok=True)
            except PermissionError as exc:
                raise RuntimeError(
                    f"could not clear {DIST}; a file is likely still in use. stop any running shlice processes launched from dist/ and retry"
                ) from exc
            print(f"downloading artifacts to {DIST}...", flush=True)
            run("gh", "run", "download", str(run_id), "--dir", str(DIST))
        return watch.returncode
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        if pushed and branch:
            try:
                print(f"deleting remote branch {branch}...", flush=True)
                run("git", "push", "origin", "--delete", branch)
            except RuntimeError as exc:
                print(str(exc), file=sys.stderr)
                print(f"cleanup: git push origin --delete {branch}", file=sys.stderr)
        if tempdir is not None:
            tempdir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
