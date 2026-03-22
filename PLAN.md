# Shlice Plan

## Goal
Build `shlice`, a cross-platform Zig CLI that manages persistent local shell processes globally and routes command execution through them using OSC 133 codes.

## UX
- `shlice start [--id <shell-id>] -- <custom-command...>`
- `shlice exec --id <shell-id> "<command>"`
- `echo "<command>" | shlice exec --id <shell-id>`
- `shlice stop --id <shell-id>`
- `shlice status [--id <shell-id>]`
- `shlice list`
- help flags: `-h`, `--help`, `-?`
- `exec` has `--timeout <seconds>`; default is 5 seconds and applies end-to-end, including waiting for a busy shell
- `exec` streams stdout and stderr to the caller while the command is running
- `exec` behaves like a temporary attachment to the target shell for one command execution
- `start` may auto-generate an id when `--id` is omitted
- `start --id <shell-id>` fails if that id already exists
- `exec` and `stop` require `--id`
- `status` without `--id` shows all known shells

## Shell Model
- shells are global, not tied to the caller's current working directory
- each shell has a unique user-facing id while running; ids may be reused after stop
- shell ids are validated against a simple portable character set: `[A-Za-z0-9_-]+`
- each shell stores launch command, startup working directory, pid or process handle, and public status
- multiple shells may exist and remain ready concurrently
- current working directory is shell metadata and startup context, not the lookup key

## Constraints
- Windows, macOS, and Linux
- no TCP
- one small stand-alone executable per platform, built from Zig
- no installed runtime dependency for end users
- no third-party Zig package dependencies in the first iteration; prefer Zig stdlib plus direct OS APIs
- exact user-visible behavior across platforms where practical, with minimal platform-specific exceptions
- GitHub Actions is the source of truth for build/test because Zig is not installed locally
- deliverable: one repository that builds `shlice` binaries plus optional packaged release artifacts

## State
- state lives in a global app data directory, not in the current project directory
- state uses platform-native good-citizen defaults per OS
- Windows uses `%LocalAppData%`
- macOS uses `~/Library/Application Support`
- Linux uses an XDG location with a sensible fallback
- metadata, lock files, and other control files are organized per shell id
- the shell registry supports listing all known shells and resolving a specific shell by id

## Protocol Sketch
- internal framing is owned by `shlice`, not by the user shell
- first implementation prefers redirected pipes over PTY/ConPTY unless interactive fidelity proves necessary
- shell bootstrap reaches `ready` only after the shell emits the OSC marker indicating it is ready to accept input
- each `exec` writes a uniquely tagged wrapper command that emits begin/end markers plus exit code
- `exec` attaches to a running shell, submits one command, and streams output until framed completion
- stdout carries framing markers and user output; `shlice` parses markers, strips them from visible output, and forwards user-visible data as it arrives
- stderr is captured separately, never carries framing markers, and is forwarded as it arrives during `exec`
- `shlice` detaches when the command completes, times out, or the shell becomes unavailable
- while no `exec` is active, stdout and stderr are still drained to avoid blocking the child process, but their user-visible output is discarded
- public shell status is `stopped`, `busy`, or `ready`
- `busy` covers both startup and active command execution; internal state may still distinguish those cases

## Synchronization
- `start` uses a per-id lock to prevent concurrent launch races for the same shell id
- `start` succeeds only when the shell reaches `ready`
- `start --id <shell-id>` fails only if a live shell with that id already exists
- `exec` is serialized per shell; only one client may drive a given shell protocol at a time
- `exec` waits for exclusive access instead of failing fast when the target shell is already busy
- `exec --timeout <seconds>` is end-to-end and covers lock wait, request write, output collection, and framed completion
- if timeout expires before `exec` completes, `exec` returns a timeout result and releases its lock state cleanly
- different shells may execute concurrently
- stale locks must be recoverable via pid and liveness checks

## Cleanup And Recovery
- `stop` first attempts graceful termination
- if the shell does not exit within a short timeout, `shlice` force-kills it
- shell metadata and lock files are removed immediately once the shell stops
- stopped shells are removed from the registry immediately
- on `start`, `list`, and `status`, `shlice` revalidates recorded processes and prunes dead or orphaned entries
- stale locks must not block future `start`, `exec`, or `stop`
- if the client running `exec` exits unexpectedly, `shlice` detaches that request cleanly and releases per-exec lock state
- `exec` timeout ends the client request cleanly; it does not kill the shell by default
