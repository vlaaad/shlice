#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent
WORKFLOW_NAME = "Zig CI"
POLL_SECONDS = 3
POLL_TIMEOUT_SECONDS = 180


class CommandError(RuntimeError):
    pass


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
        raise CommandError(f"{command}: {message}")
    return result


def print_step(message: str) -> None:
    print(message, flush=True)


def git_env(index_path: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = str(index_path)
    return env


def git_head() -> str:
    return run("git", "rev-parse", "HEAD").stdout.strip()


def is_dirty() -> bool:
    return bool(
        run("git", "status", "--porcelain=v1", "--untracked-files=all").stdout.strip()
    )


def require_prereqs() -> None:
    run("git", "rev-parse", "--show-toplevel")
    run("git", "remote", "get-url", "origin")
    run("gh", "auth", "status")


def repo_name_with_owner() -> str:
    return run(
        "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"
    ).stdout.strip()


def remote_branch_exists(branch: str) -> bool:
    result = run(
        "git",
        "ls-remote",
        "--exit-code",
        "--heads",
        "origin",
        f"refs/heads/{branch}",
        check=False,
    )
    return result.returncode == 0


def build_snapshot_commit(
    head: str,
) -> tuple[str, tempfile.TemporaryDirectory[str] | None]:
    if not is_dirty():
        return head, None

    tempdir = tempfile.TemporaryDirectory(prefix="ci-py-")
    index_path = Path(tempdir.name) / "index"
    env = git_env(index_path)

    run("git", "read-tree", "HEAD", env=env)
    run("git", "add", "-A", "--", ".", env=env)
    tree = run("git", "write-tree", env=env).stdout.strip()
    head_tree = run("git", "rev-parse", "HEAD^{tree}").stdout.strip()

    if tree == head_tree:
        tempdir.cleanup()
        return head, None

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
    return commit, tempdir


def push_snapshot(commit: str, branch: str) -> None:
    run("git", "push", "origin", f"{commit}:refs/heads/{branch}")


def delete_remote_branch(branch: str) -> None:
    run("git", "push", "origin", "--delete", branch)


def find_run_id(branch: str, commit: str, pushed_after: str) -> int:
    deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
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
            runs = json.loads(result.stdout)
            for item in runs:
                if item.get("headSha") != commit:
                    continue
                if item.get("createdAt", "") < pushed_after:
                    continue
                database_id = item.get("databaseId")
                if isinstance(database_id, int):
                    return database_id
        time.sleep(POLL_SECONDS)

    raise CommandError(f"timed out waiting for {WORKFLOW_NAME} run on {branch}")


def run_html_url(repo: str, run_id: int) -> str:
    return run(
        "gh",
        "api",
        f"repos/{repo}/actions/runs/{run_id}",
        "--jq",
        ".html_url",
    ).stdout.strip()


def run_conclusion(repo: str, run_id: int) -> str:
    return run(
        "gh",
        "api",
        f"repos/{repo}/actions/runs/{run_id}",
        "--jq",
        ".conclusion // .status",
    ).stdout.strip()


def main() -> int:
    tempdir: tempfile.TemporaryDirectory[str] | None = None
    branch = ""
    pushed = False

    def handle_signal(signum: int, _frame: object) -> None:
        raise KeyboardInterrupt(f"signal {signum}")

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        require_prereqs()
        repo = repo_name_with_owner()
        head = git_head()
        commit, tempdir = build_snapshot_commit(head)
        branch = f"ci/{commit}"

        if remote_branch_exists(branch):
            raise CommandError(f"remote branch already exists: {branch}")

        print_step(f"snapshot: {commit}")
        print_step(f"branch: {branch}")

        pushed_after = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        print_step("pushing snapshot...")
        push_snapshot(commit, branch)
        pushed = True

        print_step("waiting for workflow run...")
        run_id = find_run_id(branch, commit, pushed_after)
        url = run_html_url(repo, run_id)
        print_step(f"run: {url}")

        watch = subprocess.run(
            ["gh", "run", "watch", str(run_id), "--exit-status"],
            cwd=ROOT,
            check=False,
        )
        conclusion = run_conclusion(repo, run_id)
        print_step(f"result: {conclusion}")
        return watch.returncode
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except CommandError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        if pushed and branch:
            try:
                print_step(f"deleting remote branch {branch}...")
                delete_remote_branch(branch)
            except CommandError as exc:
                print(str(exc), file=sys.stderr)
                print(f"cleanup: git push origin --delete {branch}", file=sys.stderr)
        if tempdir is not None:
            tempdir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
