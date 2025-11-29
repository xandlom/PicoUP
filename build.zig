const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create PFCP module from dependency
    const pfcp_module = b.createModule(.{
        .root_source_file = b.path("deps/zig-pfcp/src/lib.zig"),
    });

    // Create GTP-U module from dependency
    const gtpu_module = b.createModule(.{
        .root_source_file = b.path("deps/zig-gtp-u/src/lib.zig"),
    });

    // Build main UPF executable
    const upf = b.addExecutable(.{
        .name = "picoupf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/upf.zig"),
            .target = target,
            .optimize = optimize,
        }),
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
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/upf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    upf_tests.root_module.addImport("zig-pfcp", pfcp_module);
    upf_tests.root_module.addImport("zig-gtp-u", gtpu_module);

    const run_upf_tests = b.addRunArtifact(upf_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_upf_tests.step);

    // Build QER integration test executable
    const qer_test = b.addExecutable(.{
        .name = "test_qer_integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_qer_integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add dependencies
    qer_test.root_module.addImport("zig-pfcp", pfcp_module);

    b.installArtifact(qer_test);

    // Create run step for integration test
    const run_qer_test = b.addRunArtifact(qer_test);
    run_qer_test.step.dependOn(b.getInstallStep());

    const qer_test_step = b.step("test-qer", "Run QER integration test");
    qer_test_step.dependOn(&run_qer_test.step);

    // Build URR integration test executable
    const urr_test = b.addExecutable(.{
        .name = "test_urr_integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_urr_integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add dependencies
    urr_test.root_module.addImport("zig-pfcp", pfcp_module);

    b.installArtifact(urr_test);

    // Create run step for integration test
    const run_urr_test = b.addRunArtifact(urr_test);
    run_urr_test.step.dependOn(b.getInstallStep());

    const urr_test_step = b.step("test-urr", "Run URR integration test");
    urr_test_step.dependOn(&run_urr_test.step);

    // Build N6 Echo Server example
    const echo_server = b.addExecutable(.{
        .name = "echo_server_n6",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server_n6.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(echo_server);

    const run_echo_server = b.addRunArtifact(echo_server);
    run_echo_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_echo_server.addArgs(args);
    }

    const echo_server_step = b.step("example-echo-server", "Run N6 echo server");
    echo_server_step.dependOn(&run_echo_server.step);

    // Build N3 UDP Client example
    const n3_client = b.addExecutable(.{
        .name = "udp_client_n3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/udp_client_n3.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    n3_client.root_module.addImport("zig-pfcp", pfcp_module);

    b.installArtifact(n3_client);

    const run_n3_client = b.addRunArtifact(n3_client);
    run_n3_client.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_n3_client.addArgs(args);
    }

    const n3_client_step = b.step("example-n3-client", "Run N3 UDP client");
    n3_client_step.dependOn(&run_n3_client.step);

    // Build N6 TCP Echo Server example
    const tcp_echo_server = b.addExecutable(.{
        .name = "tcp_echo_server_n6",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tcp_echo_server_n6.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(tcp_echo_server);

    const run_tcp_echo_server = b.addRunArtifact(tcp_echo_server);
    run_tcp_echo_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_tcp_echo_server.addArgs(args);
    }

    const tcp_echo_server_step = b.step("example-tcp-echo-server", "Run N6 TCP echo server");
    tcp_echo_server_step.dependOn(&run_tcp_echo_server.step);

    // Build N3 TCP Client example
    const tcp_n3_client = b.addExecutable(.{
        .name = "tcp_client_n3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tcp_client_n3.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    tcp_n3_client.root_module.addImport("zig-pfcp", pfcp_module);

    b.installArtifact(tcp_n3_client);

    const run_tcp_n3_client = b.addRunArtifact(tcp_n3_client);
    run_tcp_n3_client.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_tcp_n3_client.addArgs(args);
    }

    const tcp_n3_client_step = b.step("example-tcp-n3-client", "Run N3 TCP client");
    tcp_n3_client_step.dependOn(&run_tcp_n3_client.step);
}
