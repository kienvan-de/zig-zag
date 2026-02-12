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
            .root_source_file = b.path("src/providers/openai/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const anthropic_types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/anthropic/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const provider_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/provider.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Create modules for dependencies
    const openai_module = b.createModule(.{
        .root_source_file = b.path("src/providers/openai/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const anthropic_types_module = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const anthropic_client_test_module = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    anthropic_client_test_module.addImport("types.zig", anthropic_types_module);
    anthropic_client_test_module.addImport("../../config.zig", config_module);

    const anthropic_client_tests = b.addTest(.{
        .root_module = anthropic_client_test_module,
    });

    const errors_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/errors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const router_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/router.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const transformer_test_module = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic/transformer.zig"),
        .target = target,
        .optimize = optimize,
    });
    transformer_test_module.addImport("../openai/types.zig", openai_module);
    transformer_test_module.addImport("types.zig", anthropic_types_module);

    const transformer_tests = b.addTest(.{
        .root_module = transformer_test_module,
    });

    const utils_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_config_tests = b.addRunArtifact(config_tests);
    const run_server_tests = b.addRunArtifact(server_tests);
    const run_openai_tests = b.addRunArtifact(openai_tests);
    const run_anthropic_types_tests = b.addRunArtifact(anthropic_types_tests);
    const run_provider_tests = b.addRunArtifact(provider_tests);
    const run_transformer_tests = b.addRunArtifact(transformer_tests);
    const run_anthropic_client_tests = b.addRunArtifact(anthropic_client_tests);
    const run_errors_tests = b.addRunArtifact(errors_tests);
    const run_router_tests = b.addRunArtifact(router_tests);
    const run_utils_tests = b.addRunArtifact(utils_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_anthropic_types_tests.step);
    test_step.dependOn(&run_provider_tests.step);
    test_step.dependOn(&run_transformer_tests.step);
    test_step.dependOn(&run_anthropic_client_tests.step);
    test_step.dependOn(&run_errors_tests.step);
    test_step.dependOn(&run_router_tests.step);
    test_step.dependOn(&run_utils_tests.step);

    // Integration tests
    const recorder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/recorder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const mock_upstream_module = b.createModule(.{
        .root_source_file = b.path("test/integration/mock_upstream.zig"),
        .target = target,
        .optimize = optimize,
    });
    const recorder_module = b.createModule(.{
        .root_source_file = b.path("test/integration/recorder.zig"),
        .target = target,
        .optimize = optimize,
    });
    mock_upstream_module.addImport("recorder.zig", recorder_module);

    const mock_upstream_tests = b.addTest(.{
        .root_module = mock_upstream_module,
    });

    const mock_client_module = b.createModule(.{
        .root_source_file = b.path("test/integration/mock_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    mock_client_module.addImport("recorder.zig", recorder_module);

    const mock_client_tests = b.addTest(.{
        .root_module = mock_client_module,
    });

    const integration_main_module = b.createModule(.{
        .root_source_file = b.path("test/integration/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_main_module.addImport("recorder.zig", recorder_module);
    integration_main_module.addImport("mock_client.zig", mock_client_module);
    integration_main_module.addImport("mock_upstream.zig", mock_upstream_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_main_module,
    });

    const integration_exe = b.addExecutable(.{
        .name = "integration-test",
        .root_module = integration_main_module,
    });
    b.installArtifact(integration_exe);

    const run_integration_exe = b.addRunArtifact(integration_exe);
    run_integration_exe.step.dependOn(b.getInstallStep());

    const run_recorder_tests = b.addRunArtifact(recorder_tests);
    const run_mock_upstream_tests = b.addRunArtifact(mock_upstream_tests);
    const run_mock_client_tests = b.addRunArtifact(mock_client_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test:integration", "Run integration tests");
    integration_test_step.dependOn(&run_recorder_tests.step);
    integration_test_step.dependOn(&run_mock_upstream_tests.step);
    integration_test_step.dependOn(&run_mock_client_tests.step);
    integration_test_step.dependOn(&run_integration_tests.step);

    const run_integration_step = b.step("run:integration", "Run full integration test suite");
    run_integration_step.dependOn(&run_integration_exe.step);
}