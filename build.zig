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

    // Integration tests
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

    const mock_client_module = b.createModule(.{
        .root_source_file = b.path("test/integration/mock_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    mock_client_module.addImport("recorder.zig", recorder_module);

    const integration_main_module = b.createModule(.{
        .root_source_file = b.path("test/integration/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_main_module.addImport("recorder.zig", recorder_module);
    integration_main_module.addImport("mock_client.zig", mock_client_module);
    integration_main_module.addImport("mock_upstream.zig", mock_upstream_module);

    const integration_exe = b.addExecutable(.{
        .name = "integration-test",
        .root_module = integration_main_module,
    });
    b.installArtifact(integration_exe);

    // Mock upstream executable
    const mock_upstream_exe_module = b.createModule(.{
        .root_source_file = b.path("test/integration/mock_upstream.zig"),
        .target = target,
        .optimize = optimize,
    });
    mock_upstream_exe_module.addImport("recorder.zig", recorder_module);

    const mock_upstream_exe = b.addExecutable(.{
        .name = "mock-upstream",
        .root_module = mock_upstream_exe_module,
    });
    b.installArtifact(mock_upstream_exe);

    const run_integration_exe = b.addRunArtifact(integration_exe);
    run_integration_exe.step.dependOn(b.getInstallStep());

    const run_integration_step = b.step("test", "Run full integration test suite");
    run_integration_step.dependOn(&run_integration_exe.step);

    // Release build of executable (smallest binary)
    const release_exe = b.addExecutable(.{
        .name = "zig-zag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });

    const release_step = b.step("exec:release", "Build release binary (smallest size)");
    const install_release = b.addInstallArtifact(release_exe, .{});
    release_step.dependOn(&install_release.step);

    // =========================================================================
    // Shared library for platform UI integration
    // =========================================================================

    // Determine OS-specific output paths and filenames
    const os = target.result.os.tag;
    const dylib_name = switch (os) {
        .macos => "libzig-zag.dylib",
        .linux => "libzig-zag.so",
        .windows => "zig-zag.dll",
        else => "libzig-zag.so",
    };
    const ui_dir: ?[]const u8 = switch (os) {
        .macos => "ui/macos/zig-zag/zig-zag",
        .linux => "ui/linux/zig-zag",
        .windows => "ui/windows/zig-zag",
        else => null,
    };

    // Debug shared library
    const lib = b.addLibrary(.{
        .name = "zig-zag",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const lib_install = b.addInstallArtifact(lib, .{});
    const lib_step = b.step("lib", "Build shared library for platform UI integration");
    lib_step.dependOn(&lib_install.step);

    // Release shared library
    const lib_release = b.addLibrary(.{
        .name = "zig-zag",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });

    const lib_release_install = b.addInstallArtifact(lib_release, .{});
    const lib_release_step = b.step("lib:release", "Build release shared library for platform UI integration");
    lib_release_step.dependOn(&lib_release_install.step);

    // Auto-copy dylib + header to the platform UI project folder after build
    if (ui_dir) |dir| {
        const src_dylib = b.pathJoin(&.{ "zig-out/lib", dylib_name });
        const dst_dylib = b.pathJoin(&.{ dir, dylib_name });
        const dst_header = b.pathJoin(&.{ dir, "zig-zag.h" });

        // Debug copy
        const copy_dylib = b.addSystemCommand(&.{ "cp", src_dylib, dst_dylib });
        copy_dylib.step.dependOn(&lib_install.step);

        const copy_header = b.addSystemCommand(&.{ "cp", "include/zig-zag.h", dst_header });

        lib_step.dependOn(&copy_dylib.step);
        lib_step.dependOn(&copy_header.step);

        // Release copy
        const copy_dylib_release = b.addSystemCommand(&.{ "cp", src_dylib, dst_dylib });
        copy_dylib_release.step.dependOn(&lib_release_install.step);

        const copy_header_release = b.addSystemCommand(&.{ "cp", "include/zig-zag.h", dst_header });

        lib_release_step.dependOn(&copy_dylib_release.step);
        lib_release_step.dependOn(&copy_header_release.step);
    }
}
