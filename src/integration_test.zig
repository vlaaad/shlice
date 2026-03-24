const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");

const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

test "start osc repl, exec twice, stop" {
    const allocator = std.testing.allocator;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shlice_exe = try findShliceExe(allocator);
    defer allocator.free(shlice_exe);

    const clj_exe = try process.resolveExecutable(allocator, "clj");
    defer allocator.free(clj_exe);
    const clojure_exe = process.resolveExecutable(allocator, "clojure") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (clojure_exe) |path| allocator.free(path);

    const workspace_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const osc_repl = "osc-repl.clj";

    const sandbox = try createSandbox(allocator, workspace_root);
    defer sandbox.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    try configureEnv(&env, sandbox.root, sandbox.home);

    const shell_id = "osc-repl-test";

    var stop_needed = false;
    defer if (stop_needed) {
        if (runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "stop", shell_id })) |stop_result| {
            defer stop_result.deinit(allocator);
        } else |_| {}
    };

    const start_result = try startRepl(allocator, &env, workspace_root, shlice_exe, shell_id, osc_repl, clj_exe, clojure_exe);
    defer start_result.deinit(allocator);
    try expectExitCode(start_result.term, 0, start_result.stdout, start_result.stderr);
    const start_stdout = try normalizeNewlinesOwned(allocator, start_result.stdout);
    defer allocator.free(start_stdout);
    const start_stderr = try normalizeNewlinesOwned(allocator, start_result.stderr);
    defer allocator.free(start_stderr);
    try std.testing.expectEqualStrings("started osc-repl-test\n", start_stdout);
    try std.testing.expectEqualStrings("", start_stderr);
    stop_needed = true;

    const first_exec = try runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "exec", "--id", shell_id, "(+ 1 2)" });
    defer first_exec.deinit(allocator);
    try expectExitCode(first_exec.term, 0, first_exec.stdout, first_exec.stderr);
    const first_stdout = try normalizeNewlinesOwned(allocator, first_exec.stdout);
    defer allocator.free(first_stdout);
    const first_stderr = try normalizeNewlinesOwned(allocator, first_exec.stderr);
    defer allocator.free(first_stderr);
    try std.testing.expectEqualStrings("3\n", first_stdout);
    try std.testing.expectEqualStrings("", first_stderr);

    const second_exec = try runCommand(allocator, &env, workspace_root, &.{
        shlice_exe,
        "exec",
        "--id",
        shell_id,
        "(do (binding [*out* *err*] (println \"warn\")) :done)",
    });
    defer second_exec.deinit(allocator);
    try expectExitCode(second_exec.term, 0, second_exec.stdout, second_exec.stderr);
    const second_stdout = try normalizeNewlinesOwned(allocator, second_exec.stdout);
    defer allocator.free(second_stdout);
    const second_stderr = try normalizeNewlinesOwned(allocator, second_exec.stderr);
    defer allocator.free(second_stderr);
    try std.testing.expectEqualStrings(":done\n", second_stdout);
    try std.testing.expectEqualStrings("warn\n", second_stderr);

    const stop_result = try runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "stop", shell_id });
    defer stop_result.deinit(allocator);
    try expectExitCode(stop_result.term, 0, stop_result.stdout, stop_result.stderr);
    const stop_stdout = try normalizeNewlinesOwned(allocator, stop_result.stdout);
    defer allocator.free(stop_stdout);
    const stop_stderr = try normalizeNewlinesOwned(allocator, stop_result.stderr);
    defer allocator.free(stop_stderr);
    try std.testing.expectEqualStrings("stopped osc-repl-test\n", stop_stdout);
    try std.testing.expectEqualStrings("", stop_stderr);
    stop_needed = false;
}

test "exec incomplete command times out and shell recovers" {
    const allocator = std.testing.allocator;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shlice_exe = try findShliceExe(allocator);
    defer allocator.free(shlice_exe);

    const clj_exe = try process.resolveExecutable(allocator, "clj");
    defer allocator.free(clj_exe);
    const clojure_exe = process.resolveExecutable(allocator, "clojure") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (clojure_exe) |path| allocator.free(path);

    const workspace_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const osc_repl = "osc-repl.clj";

    const sandbox = try createSandbox(allocator, workspace_root);
    defer sandbox.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    try configureEnv(&env, sandbox.root, sandbox.home);

    const shell_id = "osc-repl-timeout-test";

    var stop_needed = false;
    defer if (stop_needed) {
        if (runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "stop", shell_id })) |stop_result| {
            defer stop_result.deinit(allocator);
        } else |_| {}
    };

    const start_result = try startRepl(allocator, &env, workspace_root, shlice_exe, shell_id, osc_repl, clj_exe, clojure_exe);
    defer start_result.deinit(allocator);
    try expectExitCode(start_result.term, 0, start_result.stdout, start_result.stderr);
    stop_needed = true;

    const incomplete_exec = try runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "exec", "--id", shell_id, "(+ 1" });
    defer incomplete_exec.deinit(allocator);
    try expectExitCode(incomplete_exec.term, 1, incomplete_exec.stdout, incomplete_exec.stderr);
    const incomplete_stdout = try normalizeNewlinesOwned(allocator, incomplete_exec.stdout);
    defer allocator.free(incomplete_stdout);
    const incomplete_stderr = try normalizeNewlinesOwned(allocator, incomplete_exec.stderr);
    defer allocator.free(incomplete_stderr);
    try std.testing.expectEqualStrings("", incomplete_stdout);
    try std.testing.expectEqualStrings("error: incomplete command\n", incomplete_stderr);

    const completion_exec = try runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "exec", "--id", shell_id, "2)" });
    defer completion_exec.deinit(allocator);
    try expectExitCode(completion_exec.term, 0, completion_exec.stdout, completion_exec.stderr);
    const completion_stdout = try normalizeNewlinesOwned(allocator, completion_exec.stdout);
    defer allocator.free(completion_stdout);
    const completion_stderr = try normalizeNewlinesOwned(allocator, completion_exec.stderr);
    defer allocator.free(completion_stderr);
    try std.testing.expectEqualStrings("3\n", completion_stdout);
    try std.testing.expectEqualStrings("", completion_stderr);
}

test "exec requests are serialized" {
    const allocator = std.testing.allocator;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shlice_exe = try findShliceExe(allocator);
    defer allocator.free(shlice_exe);

    const clj_exe = try process.resolveExecutable(allocator, "clj");
    defer allocator.free(clj_exe);
    const clojure_exe = process.resolveExecutable(allocator, "clojure") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (clojure_exe) |path| allocator.free(path);

    const workspace_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const osc_repl = "osc-repl.clj";

    const sandbox = try createSandbox(allocator, workspace_root);
    defer sandbox.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    try configureEnv(&env, sandbox.root, sandbox.home);

    const shell_id = "osc-repl-serialized-test";

    var stop_needed = false;
    defer if (stop_needed) {
        if (runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "stop", shell_id })) |stop_result| {
            defer stop_result.deinit(allocator);
        } else |_| {}
    };

    const start_result = try startRepl(allocator, &env, workspace_root, shlice_exe, shell_id, osc_repl, clj_exe, clojure_exe);
    defer start_result.deinit(allocator);
    try expectExitCode(start_result.term, 0, start_result.stdout, start_result.stderr);
    stop_needed = true;

    const first_argv = &.{
        shlice_exe,
        "exec",
        "--id",
        shell_id,
        "(do (println \"one\") (Thread/sleep 600) :first)",
    };
    const second_argv = &.{
        shlice_exe,
        "exec",
        "--id",
        shell_id,
        "(do (println \"two\") :second)",
    };

    var first_ctx = AsyncRun{ .env = &env, .cwd = workspace_root, .argv = first_argv };
    var second_ctx = AsyncRun{ .env = &env, .cwd = workspace_root, .argv = second_argv };

    var first_thread = try std.Thread.spawn(.{}, AsyncRun.run, .{ &first_ctx });
    std.time.sleep(100 * std.time.ns_per_ms);
    var second_thread = try std.Thread.spawn(.{}, AsyncRun.run, .{ &second_ctx });
    first_thread.join();
    second_thread.join();

    try std.testing.expect(first_ctx.err == null);
    try std.testing.expect(second_ctx.err == null);
    const first_result = first_ctx.result.?;
    const second_result = second_ctx.result.?;
    defer first_result.result.deinit(std.heap.page_allocator);
    defer second_result.result.deinit(std.heap.page_allocator);

    try expectExitCode(first_result.result.term, 0, first_result.result.stdout, first_result.result.stderr);
    try expectExitCode(second_result.result.term, 0, second_result.result.stdout, second_result.result.stderr);

    const first_stdout = try normalizeNewlinesOwned(allocator, first_result.result.stdout);
    defer allocator.free(first_stdout);
    const second_stdout = try normalizeNewlinesOwned(allocator, second_result.result.stdout);
    defer allocator.free(second_stdout);
    try std.testing.expectEqualStrings("one\n:first\n", first_stdout);
    try std.testing.expectEqualStrings("two\n:second\n", second_stdout);

    try std.testing.expect(first_result.duration_ms >= 500);
    try std.testing.expect(second_result.duration_ms >= 500);
    try std.testing.expect(second_result.duration_ms >= first_result.duration_ms - 150);
}

test "stop rejects queued exec" {
    const allocator = std.testing.allocator;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shlice_exe = try findShliceExe(allocator);
    defer allocator.free(shlice_exe);

    const clj_exe = try process.resolveExecutable(allocator, "clj");
    defer allocator.free(clj_exe);
    const clojure_exe = process.resolveExecutable(allocator, "clojure") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (clojure_exe) |path| allocator.free(path);

    const workspace_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const osc_repl = "osc-repl.clj";

    const sandbox = try createSandbox(allocator, workspace_root);
    defer sandbox.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    try configureEnv(&env, sandbox.root, sandbox.home);

    const shell_id = "osc-repl-stop-test";

    var stop_needed = false;
    defer if (stop_needed) {
        if (runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "stop", shell_id })) |stop_result| {
            defer stop_result.deinit(allocator);
        } else |_| {}
    };

    const start_result = try startRepl(allocator, &env, workspace_root, shlice_exe, shell_id, osc_repl, clj_exe, clojure_exe);
    defer start_result.deinit(allocator);
    try expectExitCode(start_result.term, 0, start_result.stdout, start_result.stderr);
    stop_needed = true;

    const long_argv = &.{
        shlice_exe,
        "exec",
        "--id",
        shell_id,
        "(do (println \"slow\") (Thread/sleep 1000) :first)",
    };
    const queued_argv = &.{
        shlice_exe,
        "exec",
        "--id",
        shell_id,
        "(do (println \"queued\") :second)",
    };

    var long_ctx = AsyncRun{ .env = &env, .cwd = workspace_root, .argv = long_argv };
    var queued_ctx = AsyncRun{ .env = &env, .cwd = workspace_root, .argv = queued_argv };

    var long_thread = try std.Thread.spawn(.{}, AsyncRun.run, .{ &long_ctx });
    std.time.sleep(100 * std.time.ns_per_ms);
    var queued_thread = try std.Thread.spawn(.{}, AsyncRun.run, .{ &queued_ctx });

    std.time.sleep(200 * std.time.ns_per_ms);
    const stop_result = try runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "stop", shell_id });
    defer stop_result.deinit(allocator);
    try expectExitCode(stop_result.term, 0, stop_result.stdout, stop_result.stderr);
    stop_needed = false;

    long_thread.join();
    queued_thread.join();

    try std.testing.expect(long_ctx.err == null);
    try std.testing.expect(queued_ctx.err == null);
    const long_result = long_ctx.result.?;
    const queued_result = queued_ctx.result.?;
    defer long_result.result.deinit(std.heap.page_allocator);
    defer queued_result.result.deinit(std.heap.page_allocator);

    try expectExitCode(long_result.result.term, 1, long_result.result.stdout, long_result.result.stderr);
    try expectExitCode(queued_result.result.term, 1, queued_result.result.stdout, queued_result.result.stderr);

    const long_stdout = try normalizeNewlinesOwned(allocator, long_result.result.stdout);
    defer allocator.free(long_stdout);
    const long_stderr = try normalizeNewlinesOwned(allocator, long_result.result.stderr);
    defer allocator.free(long_stderr);
    const queued_stdout = try normalizeNewlinesOwned(allocator, queued_result.result.stdout);
    defer allocator.free(queued_stdout);
    const queued_stderr = try normalizeNewlinesOwned(allocator, queued_result.result.stderr);
    defer allocator.free(queued_stderr);

    try std.testing.expect(std.mem.indexOf(u8, long_stderr, "shell stopped") != null);
    try std.testing.expectEqualStrings("", queued_stdout);
    try std.testing.expect(std.mem.indexOf(u8, queued_stderr, "shell stopped") != null);
}

test "start fails fast on missing shell command" {
    const allocator = std.testing.allocator;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const shlice_exe = try findShliceExe(allocator);
    defer allocator.free(shlice_exe);

    const workspace_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);

    const sandbox = try createSandbox(allocator, workspace_root);
    defer sandbox.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    try configureEnv(&env, sandbox.root, sandbox.home);

    const result = try runCommand(allocator, &env, workspace_root, &.{ shlice_exe, "start", "--id", "broken-start", "--", "definitely-not-a-real-command" });
    defer result.deinit(allocator);
    try expectExitCode(result.term, 1, result.stdout, result.stderr);
    const stderr = try normalizeNewlinesOwned(allocator, result.stderr);
    defer allocator.free(stderr);
    try std.testing.expect(stderr.len != 0);
}

const Sandbox = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    home: []u8,

    fn deinit(self: Sandbox) void {
        deleteTreeAbsolute(self.root) catch {};
        self.allocator.free(self.home);
        self.allocator.free(self.root);
    }
};

fn createSandbox(allocator: std.mem.Allocator, workspace_root: []const u8) !Sandbox {
    const parent = try std.fs.path.join(allocator, &.{ workspace_root, ".zig-cache", "integration" });
    defer allocator.free(parent);
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const root = try std.fmt.allocPrint(allocator, "{s}{c}{d}-{d}", .{ parent, std.fs.path.sep, std.time.nanoTimestamp(), std.crypto.random.int(u32) });
    try std.fs.makeDirAbsolute(root);

    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    errdefer allocator.free(root);
    errdefer allocator.free(home);
    try std.fs.makeDirAbsolute(home);

    if (builtin.os.tag == .macos) {
        const library = try std.fs.path.join(allocator, &.{ home, "Library" });
        defer allocator.free(library);
        std.fs.makeDirAbsolute(library) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const app_support = try std.fs.path.join(allocator, &.{ library, "Application Support" });
        defer allocator.free(app_support);
        std.fs.makeDirAbsolute(app_support) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    return .{ .allocator = allocator, .root = root, .home = home };
}

fn configureEnv(env: *std.process.EnvMap, root: []const u8, home: []const u8) !void {
    try env.put("HOME", home);
    try env.put("XDG_DATA_HOME", root);
    if (builtin.os.tag == .windows) {
        try env.put("APPDATA", root);
        try env.put("LOCALAPPDATA", root);
        try env.put("USERPROFILE", home);
    }
}

const TimedCommandResult = struct {
    result: CommandResult,
    duration_ms: i64,
};

const AsyncRun = struct {
    env: *const std.process.EnvMap,
    cwd: []const u8,
    argv: []const []const u8,
    result: ?TimedCommandResult = null,
    err: ?anyerror = null,

    fn run(self: *@This()) void {
        const start = std.time.milliTimestamp();
        const command_result = runCommand(std.heap.page_allocator, self.env, self.cwd, self.argv) catch |err| {
            self.err = err;
            return;
        };
        self.result = .{
            .result = command_result,
            .duration_ms = std.time.milliTimestamp() - start,
        };
    }
};

fn findShliceExe(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "SHLICE_TEST_EXE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => fallbackShliceExe(allocator),
        else => err,
    };
}

fn fallbackShliceExe(allocator: std.mem.Allocator) ![]u8 {
    const workspace_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);
    const exe_name = if (builtin.os.tag == .windows) "shlice.exe" else "shlice";
    return std.fs.path.join(allocator, &.{ workspace_root, "zig-out", "bin", exe_name });
}

fn startRepl(
    allocator: std.mem.Allocator,
    env: *const std.process.EnvMap,
    cwd: []const u8,
    shlice_exe: []const u8,
    shell_id: []const u8,
    osc_repl: []const u8,
    clj_exe: []const u8,
    clojure_exe: ?[]const u8,
) !CommandResult {
    const clj_result = try runCommand(allocator, env, cwd, &.{ shlice_exe, "start", "--id", shell_id, "--", clj_exe, "-M", osc_repl });
    if (clojure_exe) |path| {
        if (exitedWithCode(clj_result.term, 0)) return clj_result;
        clj_result.deinit(allocator);
        return runCommand(allocator, env, cwd, &.{ shlice_exe, "start", "--id", shell_id, "--", path, "-M", osc_repl });
    }
    return clj_result;
}

fn runCommand(allocator: std.mem.Allocator, env: *const std.process.EnvMap, cwd: []const u8, argv: []const []const u8) !CommandResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .env_map = env,
        .max_output_bytes = 1024 * 1024,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn exitedWithCode(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .Exited => |code| code == expected,
        else => false,
    };
}

fn expectExitCode(term: std.process.Child.Term, expected: u8, stdout: []const u8, stderr: []const u8) !void {
    switch (term) {
        .Exited => |code| {
            if (code != expected) {
                std.debug.print("expected exit code {d}, found {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ expected, code, stdout, stderr });
                return error.TestExpectedEqual;
            }
        },
        else => return error.UnexpectedTermination,
    }
}

fn normalizeNewlinesOwned(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, bytes, "\r\n", "\n");
}

fn deleteTreeAbsolute(path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const base_name = std.fs.path.basename(path);

    var parent = try std.fs.openDirAbsolute(parent_path, .{});
    defer parent.close();
    try parent.deleteTree(base_name);
}
