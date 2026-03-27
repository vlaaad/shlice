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
WORKFLOW_NAME = "Rust CI"
POLL_SECONDS = 3
POLL_TIMEOUT_SECONDS = 180
WATCH_TIMEOUT_SECONDS = 90
WATCH_STALE_WARN_SECONDS = 180

if os.name == "nt":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


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


def run_json(*args: str) -> object:
    return json.loads(run(*args).stdout)


def current_step_name(job: object) -> str | None:
    if not isinstance(job, dict):
        return None
    for step in job.get("steps", []):
        if isinstance(step, dict) and step.get("status") == "in_progress":
            name = step.get("name")
            if isinstance(name, str):
                return name
    for step in job.get("steps", []):
        if isinstance(step, dict) and step.get("status") == "pending":
            name = step.get("name")
            if isinstance(name, str):
                return name
    return None


def print_run_snapshot(run_info: object, jobs_info: object) -> None:
    if not isinstance(run_info, dict) or not isinstance(jobs_info, dict):
        return

    status = run_info.get("status")
    conclusion = run_info.get("conclusion")
    print(f"run status: {status} {conclusion or ''}".rstrip(), flush=True)

    jobs = jobs_info.get("jobs", [])
    if not isinstance(jobs, list):
        return
    for job in sorted(jobs, key=lambda item: item.get("id", 0) if isinstance(item, dict) else 0):
        if not isinstance(job, dict):
            continue
        name = job.get("name", "<unknown>")
        job_status = job.get("status")
        job_conclusion = job.get("conclusion")
        if job_status == "completed":
            prefix = "✓" if job_conclusion == "success" else "!"
            suffix = f" ({job_conclusion})" if job_conclusion else ""
        else:
            prefix = "*"
            step_name = current_step_name(job)
            suffix = f" - {step_name}" if step_name else ""
        print(f"{prefix} {name}{suffix}", flush=True)


def watch_run(repo: str, run_id: int) -> int:
    last_snapshot: str | None = None
    last_change = time.monotonic()
    warned = False

    while True:
        run_info = run_json("gh", "api", f"repos/{repo}/actions/runs/{run_id}")
        jobs_info = run_json("gh", "api", f"repos/{repo}/actions/runs/{run_id}/jobs")
        snapshot = json.dumps({"run": run_info, "jobs": jobs_info}, sort_keys=True)
        if snapshot != last_snapshot:
            print_run_snapshot(run_info, jobs_info)
            last_snapshot = snapshot
            last_change = time.monotonic()
            warned = False

        if isinstance(run_info, dict) and run_info.get("status") == "completed":
            return 0 if run_info.get("conclusion") == "success" else 1

        idle_seconds = time.monotonic() - last_change
        if idle_seconds >= WATCH_STALE_WARN_SECONDS and not warned:
            active = None
            if isinstance(jobs_info, dict):
                for job in jobs_info.get("jobs", []):
                    active = current_step_name(job)
                    if active is not None:
                        job_name = job.get("name", "<unknown>") if isinstance(job, dict) else "<unknown>"
                        break
                else:
                    job_name = None
            else:
                job_name = None
            if active is not None and job_name is not None:
                print(
                    f"warning: no CI progress for {int(idle_seconds)}s; {job_name} is at {active}",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                print(
                    f"warning: no CI progress for {int(idle_seconds)}s",
                    file=sys.stderr,
                    flush=True,
                )
            warned = True

        if idle_seconds >= WATCH_TIMEOUT_SECONDS:
            try:
                run("gh", "api", f"repos/{repo}/actions/runs/{run_id}/cancel", "-X", "POST")
            except Exception:
                pass
            raise RuntimeError(
                f"workflow run {run_id} made no progress for {WATCH_TIMEOUT_SECONDS}s"
            )

        time.sleep(POLL_SECONDS)


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

        watch = watch_run(repo, run_id)
        conclusion = run(
            "gh",
            "api",
            f"repos/{repo}/actions/runs/{run_id}",
            "--jq",
            ".conclusion // .status",
        ).stdout.strip()
        print(f"result: {conclusion}", flush=True)
        if watch == 0:
            download_dir = DIST
            try:
                if DIST.exists():
                    shutil.rmtree(DIST, ignore_errors=False)
                DIST.mkdir(exist_ok=True)
            except PermissionError as exc:
                download_dir = Path(tempfile.mkdtemp(prefix="ci-artifacts-"))
                print(
                    f"warning: could not clear {DIST}; downloading artifacts to {download_dir} instead",
                    file=sys.stderr,
                    flush=True,
                )
            print(f"downloading artifacts to {download_dir}...", flush=True)
            run("gh", "run", "download", str(run_id), "--dir", str(download_dir))
        return watch
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
