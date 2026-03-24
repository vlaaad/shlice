# Shlice Refactor Notes

## Objective
Refactor `shlice` away from Unix domain socket listen on the control path. The target transport is:

- FIFOs on macOS/Linux
- named pipes on Windows

The refactor must preserve the current CLI and user-visible behavior:

- `shlice start [--id <shell-id>] -- <custom-command...>`
- `shlice exec --id <shell-id> "<command>"`
- `shlice stop [<shell-id>]`
- `shlice status [--id <shell-id>]`
- `shlice list`

The OSC 133 REPL wrapper in `osc-repl.clj` stays as-is unless a transport change absolutely requires a tiny compatibility tweak.

## Current Shape

The existing code already separates concerns enough to reuse:

- [`src/app.zig`](src/app.zig) owns CLI dispatch and the start/exec/stop flows.
- [`src/broker.zig`](src/broker.zig) owns the long-lived shell broker and command execution loop.
- [`src/ipc.zig`](src/ipc.zig) currently wraps Unix sockets and frame encoding/decoding.
- [`src/state_dir.zig`](src/state_dir.zig) owns app-data layout and per-shell file paths.
- [`src/integration_test.zig`](src/integration_test.zig) already covers the expected behavior for start, exec serialization, timeout recovery, and stop.

Important current behavior:

- `start` blocks until the shell emits the OSC ready marker.
- `exec` is serialized per shell and streams stdout/stderr while the command runs.
- `stop` attempts graceful shutdown first.
- Public status is still `stopped`, `busy`, or `ready`.

## Target Design

### Unix-like systems

- Replace the broker control socket with a per-shell FIFO control channel.
- Each `exec` request creates a private reply channel so stdout, stderr, and completion can flow back without polling.
- Use a small per-shell lock file to serialize request submission so FIFO writes stay protocol-safe.
- Keep the existing length-prefixed frame format; only the transport changes.

### Windows

- Use named pipes for the same logical request/response protocol.
- Avoid introducing a polling backend just to keep parity with Unix-like systems.
- Keep the current Windows-specific process control and startup logic, but replace the transport layer with a live blocking pipe model.

## Refactor Constraints

- No TCP.
- No Unix socket listen on the control path.
- No polling loop for request handoff or completion.
- Preserve command ordering and `exec` serialization.
- Preserve `exec --timeout` as an end-to-end timeout that includes lock wait, request setup, output collection, and completion.
- Remove dead shell state and stale locks robustly so restarts do not get stuck.

## Implementation Notes

- Treat transport as a separate layer from broker protocol logic.
- Reuse the existing frame format in `src/ipc.zig`; rename or split it if necessary, but avoid changing the wire payload unless forced.
- Keep shell readiness and command completion framed explicitly, not inferred from file timestamps.
- Prefer a single protocol shape across platforms, with only the transport backend varying.
- Keep `shlice` responsible for cleanup of temp endpoints and per-shell state.

## Verification

- Update or add integration tests for:
  - `start` success and startup failure
  - `exec` output on stdout and stderr
  - `exec` serialization under contention
  - timeout recovery
  - `stop` cleanup
- Run `python ci.py` after changes.
- If the CI helper is blocked locally, still run the local Zig test suite before considering the refactor done.

## Non-Goals

- Do not redesign the OSC 133 shell protocol.
- Do not add TCP or a remote daemon.
- Do not replace the persistent-shell model with a foreground-only REPL launcher.
- Do not introduce polling as a substitute for blocking IPC.
