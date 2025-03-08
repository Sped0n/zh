const std = @import("std");

// Learn more about this file here: https://ziglang.org/learn/build-system
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.addModule("zh", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zh",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // For zls build_on_save
    const exe_check = b.addExecutable(.{
        .name = "zh",
        .root_module = root_module,
    });

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test
    const test_module = b.createModule(.{ .root_source_file = b.path("src/test/tests.zig") });
    const tests = b.addTest(.{
        .name = "tests",
        .root_source_file = b.path("src/main.zig"),
    });
    tests.root_module.addImport("tests", test_module);
    const test_cmd = b.addRunArtifact(tests);
    test_cmd.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&test_cmd.step);

    // For zls build_on_save
    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&exe_check.step);
}
