const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "strace-to-duckdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Link DuckDB library
    exe.linkSystemLibrary("duckdb");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test configuration
    const test_step = b.step("test", "Run all tests");

    // Test individual modules
    const modules = [_][]const u8{
        "src/types.zig",
        "src/parser.zig",
        "src/progress.zig",
        "src/database.zig",
        "src/processor.zig",
    };

    for (modules) |module_path| {
        const module_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(module_path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        // Link DuckDB for modules that need it
        module_test.linkSystemLibrary("duckdb");

        const run_module_test = b.addRunArtifact(module_test);
        test_step.dependOn(&run_module_test.step);
    }
}
