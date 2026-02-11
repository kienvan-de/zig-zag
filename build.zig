const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-zag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the proxy server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const openai_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/openai.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const anthropic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/anthropic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const provider_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/provider.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Create modules for dependencies
    const openai_module = b.createModule(.{
        .root_source_file = b.path("src/providers/openai.zig"),
        .target = target,
        .optimize = optimize,
    });

    const anthropic_module = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic.zig"),
        .target = target,
        .optimize = optimize,
    });

    const request_test_module = b.createModule(.{
        .root_source_file = b.path("src/transformers/anthropic.zig"),
        .target = target,
        .optimize = optimize,
    });
    request_test_module.addImport("../providers/openai.zig", openai_module);
    request_test_module.addImport("../providers/anthropic.zig", anthropic_module);

    const request_tests = b.addTest(.{
        .root_module = request_test_module,
    });

    const run_config_tests = b.addRunArtifact(config_tests);
    const run_server_tests = b.addRunArtifact(server_tests);
    const run_openai_tests = b.addRunArtifact(openai_tests);
    const run_anthropic_tests = b.addRunArtifact(anthropic_tests);
    const run_provider_tests = b.addRunArtifact(provider_tests);
    const run_request_tests = b.addRunArtifact(request_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_anthropic_tests.step);
    test_step.dependOn(&run_provider_tests.step);
    test_step.dependOn(&run_request_tests.step);
}