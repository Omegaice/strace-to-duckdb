const std = @import("std");
const database = @import("database.zig");
const processor = @import("processor.zig");
const parallel_processor = @import("parallel_processor.zig");
const progress = @import("progress.zig");
const Database = database.Database;
const ProgressBar = progress.ProgressBar;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(args[0]);
        std.process.exit(1);
    }

    // Default output database
    var output_db: []const u8 = "strace.db";
    var use_sequential = false;
    var trace_files = std.ArrayListUnmanaged([]const u8){};
    defer trace_files.deinit(allocator);

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            // Next arg is the output database
            i += 1;
            if (i >= args.len) {
                try std.fs.File.stdout().writeAll("Error: -o requires an argument\n");
                std.process.exit(1);
            }
            output_db = args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sequential")) {
            use_sequential = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(args[0]);
            std.process.exit(0);
        } else {
            // It's a trace file
            try trace_files.append(allocator, arg);
        }
    }

    if (trace_files.items.len == 0) {
        try std.fs.File.stdout().writeAll("Error: No trace files specified\n\n");
        try printUsage(args[0]);
        std.process.exit(1);
    }

    // Print what we're doing
    try std.fs.File.stdout().writeAll("Creating database: ");
    try std.fs.File.stdout().writeAll(output_db);
    try std.fs.File.stdout().writeAll("\n");

    // Delete existing database if it exists (overwrite mode)
    std.fs.cwd().deleteFile(output_db) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Warning: Could not delete existing database: {}\n", .{err});
        }
    };

    // Create database
    var db = try Database.init(output_db);
    defer db.deinit();

    try std.fs.File.stdout().writeAll("Database created successfully\n\n");

    var total_lines: usize = 0;
    var total_parsed: usize = 0;
    var total_failed: usize = 0;
    var files_processed: usize = 0;

    if (use_sequential) {
        // Sequential processing
        try std.fs.File.stdout().writeAll("Processing trace files sequentially...\n\n");

        for (trace_files.items) |trace_file| {
            // Check if file exists
            std.fs.cwd().access(trace_file, .{}) catch |err| {
                std.debug.print("Warning: Cannot access file '{s}': {}\n", .{ trace_file, err });
                continue;
            };

            const stats = try processor.processFile(allocator, &db, trace_file, true);

            total_lines += stats.total_lines;
            total_parsed += stats.parsed_lines;
            total_failed += stats.failed_lines;
            files_processed += 1;
        }
    } else {
        // Parallel processing
        const num_workers = @max(1, try std.Thread.getCpuCount());
        try std.fs.File.stdout().writeAll("Processing trace files in parallel...\n\n");

        const par_stats = try parallel_processor.processFilesParallel(
            allocator,
            &db,
            trace_files.items,
            num_workers,
        );

        try std.fs.File.stdout().writeAll("\n");

        total_lines = par_stats.total_lines;
        total_parsed = par_stats.parsed_lines;
        total_failed = par_stats.failed_lines;
        files_processed = par_stats.files_processed;
    }

    // Print summary
    try std.fs.File.stdout().writeAll("\n=== Summary ===\n");
    std.debug.print("Files processed: {}/{}\n", .{ files_processed, trace_files.items.len });
    std.debug.print("Total lines: {}\n", .{total_lines});
    std.debug.print("Total syscalls parsed: {}\n", .{total_parsed});
    std.debug.print("Total failed lines: {}\n", .{total_failed});
    std.debug.print("Database: {s}\n", .{output_db});

    // Database statistics
    try std.fs.File.stdout().writeAll("\n=== Database Statistics ===\n");
    const syscall_count = try db.getSyscallCount();
    std.debug.print("Total syscalls in DB: {}\n", .{syscall_count});

    const unique_syscalls = try db.getUniqueSyscallCount();
    std.debug.print("Unique syscalls: {}\n", .{unique_syscalls});

    const unique_pids = try db.getUniquePidCount();
    std.debug.print("Unique PIDs: {}\n", .{unique_pids});

    const failed_syscalls = try db.getFailedSyscallCount();
    std.debug.print("Failed syscalls: {}\n", .{failed_syscalls});

    try std.fs.File.stdout().writeAll("\nSuccess!\n");
}

fn printUsage(program_name: []const u8) !void {
    const usage =
        \\Usage: {s} [OPTIONS] <trace_files...>
        \\
        \\Parse strace output files and load them into a DuckDB database.
        \\
        \\Options:
        \\  -o, --output <file>  Output database file (default: strace.db)
        \\  -s, --sequential     Use sequential processing (default: parallel)
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  {s} trace.1234 trace.5678
        \\  {s} -o output.db trace.*
        \\  {s} --sequential --output mydata.db strace-*.log
        \\
    ;

    std.debug.print(usage, .{ program_name, program_name, program_name, program_name });
}
