const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create PFCP module from dependency
    const pfcp_module = b.createModule(.{
        .root_source_file = b.path("deps/zig-pfcp/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create GTP-U module from dependency
    const gtpu_module = b.createModule(.{
        .root_source_file = b.path("deps/zig-gtp-u/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build main UPF executable
    const upf = b.addExecutable(.{
        .name = "picoupf",
        .root_source_file = b.path("src/upf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    upf.root_module.addImport("zig-pfcp", pfcp_module);
    upf.root_module.addImport("zig-gtp-u", gtpu_module);

    b.installArtifact(upf);

    // Create run step
    const run_cmd = b.addRunArtifact(upf);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the UPF");
    run_step.dependOn(&run_cmd.step);

    // Create test step
    const upf_tests = b.addTest(.{
        .root_source_file = b.path("src/upf.zig"),
        .target = target,
        .optimize = optimize,
    });

    upf_tests.root_module.addImport("zig-pfcp", pfcp_module);
    upf_tests.root_module.addImport("zig-gtp-u", gtpu_module);

    const run_upf_tests = b.addRunArtifact(upf_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_upf_tests.step);
}
