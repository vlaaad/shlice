const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bin_name = if (target.result.os.tag == .windows) "shlice.exe" else "shlice";

    const exe = b.addExecutable(.{
        .name = "shlice",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const integration_tests = b.addTest(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compile_unit_tests = b.step("test-compile", "Compile unit tests");
    compile_unit_tests.dependOn(&unit_tests.step);
    compile_unit_tests.dependOn(&integration_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());
    run_integration_tests.setEnvironmentVariable("SHLICE_TEST_EXE", b.getInstallPath(.bin, bin_name));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
