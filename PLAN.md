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

## Implementation Plan

### Build Philosophy
- keep the first executable stdlib-first and small, with `src/main.zig` delegating quickly into focused modules
- land vertical slices that are usable and testable on their own rather than designing the full protocol up front
- prefer file-backed and process-backed seams that can be validated with unit tests before wiring the full CLI UX
- treat GitHub Actions as the authoritative and only build/test environment for this repo because Zig is not installed locally
- design each slice so it is small enough to validate comfortably through `python ci.py` rather than depending on a fast local Zig loop

### Phase 0: Foundation And Scaffolding ✅
- normalize the CLI surface to match the intended commands: `start`, `exec`, `stop`, `status`, `list`, and help aliases
- split code into small modules such as `cli.zig`, `state_dir.zig`, `shell_id.zig`, `registry.zig`, `locks.zig`, `process.zig`, and `protocol.zig`
- add shared error types and output helpers so user-visible behavior is stable before shell orchestration exists
- keep the CI workflow green after every slice, specifically `zig build test-compile`, `zig build test` where runnable, and `zig build -Doptimize=ReleaseSmall`

### Phase 1: Pure Data And Filesystem Layer ✅
- implement shell id validation for `[A-Za-z0-9_-]+` and auto-id generation
- implement platform-specific state-dir discovery with Linux XDG fallback behavior
- define on-disk layout for registry entries, per-shell metadata, and lock files
- implement registry CRUD and shell enumeration without starting real child processes yet
- expose `status` and `list` against file-backed fake entries first so the listing model is testable before process management

### Phase 2: Locking, Liveness, And Recovery ✅
- add per-id start locks and per-shell exec locks with stale-lock detection using pid/process liveness checks
- implement registry revalidation and pruning helpers used by `start`, `status`, and `list`
- model public shell states as `stopped`, `busy`, and `ready`, even if startup and exec busy are still distinct internally
- test lock acquisition, contention, stale recovery, and registry pruning entirely through deterministic filesystem fixtures

### Phase 3: Process Launch And Ready Detection ✅
- implement OS-specific child process launch behind a common interface, initially using redirected stdin/stdout/stderr pipes
- bootstrap supported shells with a small wrapper that emits a ready OSC marker after startup
- make `start` wait until the shell is truly ready, then persist metadata and registry state atomically
- make `start --id` fail only when the target id resolves to a live shell after revalidation
- make `stop` gracefully terminate, then force-kill after a short timeout, and always clean metadata on success

### Phase 4: Single-Request Exec Protocol ✅
- implement framed `exec` submission with a unique request id, begin marker, end marker, and explicit exit code marker
- stream stdout and stderr while stripping framing from user-visible stdout
- keep background drain loops active when no client is attached so the shell never blocks on full pipes
- implement end-to-end timeout handling that includes waiting for a busy shell, request submission, and framed completion
- ensure timeout or client exit releases exec lock state without killing the shell by default

### Phase 5: Concurrency And Multi-Shell Behavior ✅
- verify that different shell ids can start and execute concurrently without shared global bottlenecks
- verify that a second `exec` against the same shell waits for exclusive access rather than failing fast
- ensure `status` reflects `busy` during startup and active execution, and returns to `ready` afterward
- harden cleanup paths for orphaned metadata, dead shells, interrupted clients, and partially written state files

### Phase 6: UX Polish And Release Shape ✅
- tighten help text, error messages, and exit codes to make scripted use predictable
- add `list` and `status` formatting that is stable and easy to parse visually
- verify `ReleaseSmall` builds for all configured targets and keep packaging assumptions aligned with `dist/` artifacts from CI
- only add platform-specific exceptions where direct OS APIs force them, and document those exceptions in the plan or README

## Testing Plan

### Test Pyramid
- keep most coverage in fast unit tests for parsing, validation, state-dir selection, registry encoding, lock logic, timeout math, and protocol parsing
- add integration tests for filesystem state transitions and shell lifecycle behavior using real child processes on supported host targets
- rely entirely on GitHub Actions matrix runs for executable validation, especially for Windows process and path behavior that cannot be validated locally here

### Slice-By-Slice Validation
- after Phase 0, add CLI parsing and help tests, then validate them through `python ci.py`
- after Phase 1, add shell id, auto-id, state-dir, registry, and list/status tests, then validate them through `python ci.py`
- after Phase 2, add lock contention and stale-lock recovery tests that simulate dead pids and abandoned lock files, then validate them through `python ci.py`
- after Phase 3, add `start`/`stop` lifecycle tests for ready detection, duplicate-id rejection, and cleanup behavior, then validate them through `python ci.py`
- after Phase 4, add `exec` framing, stdout/stderr streaming, exit-code capture, timeout, and lock-release tests, then validate them through `python ci.py`
- after Phase 5, add multi-process concurrency tests for concurrent shells and serialized same-shell exec, then validate them through `python ci.py`

### CI Validation Loop
- use `python ci.py` as the main validation path whenever a slice changes behavior that matters cross-platform or in optimized builds
- treat `ci.py` as a snapshot runner: it pushes the current tree, waits for the `Zig CI` workflow, and downloads artifacts into `dist/`
- keep the GitHub workflow enforcing three checks on each relevant slice: `zig build test-compile`, `zig build test` where runnable, and `zig build -Doptimize=ReleaseSmall`
- before declaring a phase done, require the relevant new tests plus a full `ci.py` pass so the slice is proven on Windows, macOS, and Linux targets
- treat local review as source inspection only; no phase assumes local `zig build` or local test execution is available

### Practical Delivery Sequence
- first ship a file-backed registry and validated CLI that can list/status mock state cleanly
- next ship reliable `start`/`stop` with ready detection and cleanup, even before full `exec` streaming is perfect
- then ship one-command-at-a-time `exec` with framing and timeout semantics
- finally harden concurrency, stale recovery, and cross-platform edge cases once the basic vertical flow is working end to end
