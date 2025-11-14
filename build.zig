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

    // Benchmark configuration
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    // Add zBench module
    bench.root_module.addImport("zbench", zbench_dep.module("zbench"));

    // Add parser only - other modules cause conflicts due to shared types.zig
    bench.root_module.addAnonymousImport("parser", .{
        .root_source_file = b.path("src/parser.zig"),
    });

    // Link DuckDB and libc for benchmarks
    bench.linkSystemLibrary("duckdb");
    bench.linkLibC();

    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run micro-benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // End-to-end benchmark using hyperfine
    const e2e_bench_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/e2e-bench.sh",
    });
    e2e_bench_cmd.step.dependOn(b.getInstallStep());

    const e2e_bench_step = b.step("e2e-bench", "Run end-to-end benchmark with hyperfine");
    e2e_bench_step.dependOn(&e2e_bench_cmd.step);

    // Test configuration
    const test_step = b.step("test", "Run all tests");

    // Test individual modules
    const modules = [_][]const u8{
        "src/types.zig",
        "src/parser.zig",
        "src/progress.zig",
        "src/database.zig",
        "src/processor.zig",
        "src/parallel_processor.zig",
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
