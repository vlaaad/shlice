# Shlice Plan

## Goal
Build `shlice`, a cross-platform Zig CLI that manages one local shell session per exact working directory and slices command execution through that session without using TCP.

## UX
- `shlice start -- <custom-command...>`
- `shlice eval "<code>"`
- `echo "<code>" | shlice eval`
- `shlice stop`
- `shlice status`
- help flags: `-h`, `--help`, `-?`
- `eval` has `--timeout <seconds>`; default is 5 seconds and applies end-to-end, including waiting for a busy session
- commands always target the shell session associated with the exact current working directory

## Constraints
- Windows, macOS, and Linux
- no TCP
- one small stand-alone executable per platform, built from Zig
- no installed runtime dependency for end users
- no third-party Zig package dependencies in the first iteration; prefer Zig stdlib plus direct OS APIs
- exact user-visible behavior across platforms where practical, with minimal platform-specific exceptions
- GitHub Actions is the source of truth for build/test because Zig is not installed locally
- deliverable: one repository that builds `shlice` binaries plus optional packaged release artifacts

## Architecture
Start a detached shell process and manage it through a lightweight local session registry.

- `shlice` stores session state in `<cwd>/.shlice/`
- one detached shell session exists per exact working directory
- `start` bootstraps `.shlice/` and writes `.shlice/.gitignore` automatically
- `start` launches the target shell as a child process with redirected `stdin` / `stdout` / `stderr`
- built-in launchers cover common shells; custom launchers run exactly as provided after `--`
- `shlice` stores session metadata locally: pid, cwd, command, started_at, transport paths, lock state, and status
- `eval` acquires exclusive session access, writes a command payload to the shell input, then waits for explicit framed completion markers
- output is captured in local files so later commands can reconnect without a broker process
- `stop` and cleanup operate from stored metadata and liveness checks

## Launcher Detection
- `shlice start` auto-selects a default shell by platform
- Windows default: `pwsh` when available, otherwise `powershell`, otherwise `cmd`
- macOS and Linux default: `$SHELL` when set and executable, otherwise `bash`, otherwise `sh`
- `shlice start bash` runs `bash`
- `shlice start pwsh` runs `pwsh`
- `shlice start cmd` runs `cmd.exe`
- `shlice start -- <custom-command...>` runs the custom command exactly as provided
- built-in launchers may inject shell-specific bootstrap code to enable framing and prompt detection

## Protocol Sketch
- state dir: `<cwd>/.shlice/`
- `.shlice/.gitignore` contents: `*`
- internal framing is owned by `shlice`, not by the user shell
- first implementation prefers redirected pipes over PTY/ConPTY unless interactive fidelity proves necessary
- each eval writes a uniquely tagged wrapper command that emits begin/end markers plus exit code
- stdout carries framing markers and user output; `shlice` parses markers and strips them from visible output
- stderr is captured separately and never carries framing markers
- while no eval is active, stdout and stderr are still drained to avoid blocking the child process, but their user-visible output is discarded
- public session status is `stopped`, `busy`, or `ready`
- `busy` covers both startup and active evaluation; internal state may still distinguish those cases

## Synchronization
- `start` uses a session-level lock to prevent concurrent launch races in the same working directory
- `start` succeeds only when the session reaches `ready`
- `eval` is serialized per session; only one client may drive the shell protocol at a time
- `eval` waits for exclusive access instead of failing fast when the session is already busy
- `eval --timeout <seconds>` is end-to-end and covers lock wait, request write, output collection, and framed completion
- if timeout expires before eval completes, `eval` returns a timeout result and releases its lock state cleanly
- stale locks must be recoverable via pid and liveness checks

## Implementation Plan
- start with a stdlib-first Zig binary in `src/main.zig`
- keep modules small, preferably single file
- target `ReleaseSmall` builds by default for CI release verification
- use GitHub Actions to run `zig build test` and `zig build -Doptimize=ReleaseSmall` on Windows, macOS, and Linux
