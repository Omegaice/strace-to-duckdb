const std = @import("std");
const Database = @import("database.zig").Database;
const processor = @import("processor.zig");
const progress = @import("progress.zig");
const AggregateProgress = progress.AggregateProgress;

/// Statistics from parallel processing
pub const ParallelStats = struct {
    total_files: usize,
    files_processed: usize,
    total_lines: usize,
    parsed_lines: usize,
    failed_lines: usize,
    files_with_errors: usize,

    pub fn init() ParallelStats {
        return .{
            .total_files = 0,
            .files_processed = 0,
            .total_lines = 0,
            .parsed_lines = 0,
            .failed_lines = 0,
            .files_with_errors = 0,
        };
    }
};

/// Context passed to each worker thread
const WorkerContext = struct {
    worker_id: usize,
    db_main: *const Database,
    files: []const []const u8,
    num_workers: usize,
    allocator: std.mem.Allocator,

    // Atomic counters for progress tracking
    files_complete: *std.atomic.Value(usize),
    total_lines: *std.atomic.Value(usize),
    parsed_lines: *std.atomic.Value(usize),
    failed_lines: *std.atomic.Value(usize),
    files_with_errors: *std.atomic.Value(usize),

    // Error reporting
    error_slot: *?anyerror,

    fn run(self: @This()) !void {
        // Get database instance and create worker connection
        const db_instance = self.db_main.getDbInstance();
        var db = try Database.connectToInstance(db_instance);
        defer db.deinit();

        // Process assigned files using round-robin distribution
        // Worker 0 gets files 0, num_workers, 2*num_workers, ...
        // Worker 1 gets files 1, num_workers+1, 2*num_workers+1, ...
        var i = self.worker_id;
        while (i < self.files.len) : (i += self.num_workers) {
            const file_path = self.files[i];

            // Process the file (disable per-file progress in parallel mode)
            const stats = processor.processFile(self.allocator, &db, file_path, false) catch |err| {
                // File processing failed, increment error counter
                _ = self.files_with_errors.fetchAdd(1, .seq_cst);
                // Store error for debugging (overwrites previous errors)
                self.error_slot.* = err;
                continue;
            };

            // Update atomic counters with results
            _ = self.files_complete.fetchAdd(1, .seq_cst);
            _ = self.total_lines.fetchAdd(stats.total_lines, .seq_cst);
            _ = self.parsed_lines.fetchAdd(stats.parsed_lines, .seq_cst);
            _ = self.failed_lines.fetchAdd(stats.failed_lines, .seq_cst);
        }
    }
};

/// Wrapper for thread execution to capture errors
const ThreadWrapper = struct {
    ctx: WorkerContext,

    fn runWrapper(self: @This()) void {
        WorkerContext.run(self.ctx) catch |err| {
            self.ctx.error_slot.* = err;
        };
    }
};

/// Process multiple files in parallel using a worker thread pool
///
/// Parameters:
///   - allocator: Memory allocator for worker threads
///   - db_main: Main database connection (must own the database instance)
///   - files: Array of file paths to process
///   - num_workers: Number of worker threads to spawn
///
/// Returns:
///   Statistics about the parallel processing operation
pub fn processFilesParallel(
    allocator: std.mem.Allocator,
    db_main: *Database,
    files: []const []const u8,
    num_workers: usize,
) !ParallelStats {
    // Handle edge case: no files to process
    if (files.len == 0) {
        var stats = ParallelStats.init();
        stats.total_files = 0;
        return stats;
    }

    // Determine actual number of workers (can't have more workers than files)
    const actual_workers = @min(num_workers, files.len);

    // Initialize atomic counters
    var files_complete = std.atomic.Value(usize).init(0);
    var total_lines = std.atomic.Value(usize).init(0);
    var parsed_lines = std.atomic.Value(usize).init(0);
    var failed_lines = std.atomic.Value(usize).init(0);
    var files_with_errors = std.atomic.Value(usize).init(0);

    // Allocate thread and error arrays
    const threads = try allocator.alloc(std.Thread, actual_workers);
    defer allocator.free(threads);

    const errors = try allocator.alloc(?anyerror, actual_workers);
    defer allocator.free(errors);

    // Initialize errors to null
    for (errors) |*err| {
        err.* = null;
    }

    // Spawn worker threads
    for (0..actual_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, ThreadWrapper.runWrapper, .{ThreadWrapper{
            .ctx = WorkerContext{
                .worker_id = i,
                .db_main = db_main,
                .files = files,
                .num_workers = actual_workers,
                .allocator = allocator,
                .files_complete = &files_complete,
                .total_lines = &total_lines,
                .parsed_lines = &parsed_lines,
                .failed_lines = &failed_lines,
                .files_with_errors = &files_with_errors,
                .error_slot = &errors[i],
            },
        }});
    }

    // Show aggregate progress while workers are running
    var aggregate_progress = AggregateProgress.init(files.len);
    defer aggregate_progress.deinit();

    // Progress loop: continue until all files are processed (success or error)
    while (true) {
        const complete = files_complete.load(.seq_cst);
        const error_count = files_with_errors.load(.seq_cst);
        const lines = total_lines.load(.seq_cst);

        try aggregate_progress.render(complete, lines);

        // Check if all files have been processed (either completed or errored)
        if (complete + error_count >= files.len) {
            break;
        }

        // Update every 100ms
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Final progress update
    const final_complete = files_complete.load(.seq_cst);
    const final_lines = total_lines.load(.seq_cst);
    try aggregate_progress.render(final_complete, final_lines);
    try aggregate_progress.finish();

    // Check for critical errors (return first error found)
    // Note: File-level errors are already tracked in files_with_errors counter
    for (errors) |maybe_err| {
        if (maybe_err) |err| {
            // Check if this is a critical error (not a file-level error)
            // File-level errors are expected and tracked separately
            switch (err) {
                error.FileNotFound,
                error.AccessDenied,
                error.LineTooLong,
                => continue, // These are file-level errors, already counted
                else => return err, // Critical error, propagate it
            }
        }
    }

    // Collect final statistics
    return ParallelStats{
        .total_files = files.len,
        .files_processed = files_complete.load(.seq_cst),
        .total_lines = total_lines.load(.seq_cst),
        .parsed_lines = parsed_lines.load(.seq_cst),
        .failed_lines = failed_lines.load(.seq_cst),
        .files_with_errors = files_with_errors.load(.seq_cst),
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "parallel processing produces same results as sequential" {
    const allocator = std.testing.allocator;

    // Create test directory
    const test_dir = "zig-cache/test-parallel-equiv";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files with various patterns
    const num_files = 5;
    const lines_per_file = 20;

    var file_list = std.ArrayListUnmanaged([]const u8){};
    defer file_list.deinit(allocator);
    defer for (file_list.items) |fname| allocator.free(fname);

    // Create test files with identifiable data
    for (0..num_files) |file_idx| {
        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}/trace.{d}",
            .{ test_dir, file_idx + 1000 },
        );
        try file_list.append(allocator, filename);

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        // Write syscalls with unique return values per file
        for (0..lines_per_file) |line_idx| {
            const line = try std.fmt.allocPrint(
                allocator,
                "10:23:45.{d:06} write(1, \"file{d}_line{d}\", 10) = {d} <0.000001>\n",
                .{ line_idx, file_idx, line_idx, file_idx * 1000 + line_idx },
            );
            defer allocator.free(line);
            try file.writeAll(line);
        }
    }

    // Process sequentially
    const db_seq_path = try std.fmt.allocPrint(allocator, "{s}/sequential.db", .{test_dir});
    defer allocator.free(db_seq_path);

    var db_seq = try Database.init(db_seq_path);
    defer db_seq.deinit();

    var seq_stats = processor.ProcessStats.init();
    for (file_list.items) |file_path| {
        const stats = try processor.processFile(allocator, &db_seq, file_path, false);
        seq_stats.total_lines += stats.total_lines;
        seq_stats.parsed_lines += stats.parsed_lines;
        seq_stats.failed_lines += stats.failed_lines;
    }

    // Process in parallel
    const db_par_path = try std.fmt.allocPrint(allocator, "{s}/parallel.db", .{test_dir});
    defer allocator.free(db_par_path);

    var db_par = try Database.init(db_par_path);
    defer db_par.deinit();

    const par_stats = try processFilesParallel(allocator, &db_par, file_list.items, 2);

    // Compare results - both should have identical data
    // 1. Total syscall count
    const seq_count = try db_seq.getSyscallCount();
    const par_count = try db_par.getSyscallCount();
    try std.testing.expectEqual(seq_count, par_count);

    // 2. Statistics should match
    try std.testing.expectEqual(seq_stats.total_lines, par_stats.total_lines);
    try std.testing.expectEqual(seq_stats.parsed_lines, par_stats.parsed_lines);
    try std.testing.expectEqual(seq_stats.failed_lines, par_stats.failed_lines);

    // 3. Unique syscall count
    const seq_unique = try db_seq.getUniqueSyscallCount();
    const par_unique = try db_par.getUniqueSyscallCount();
    try std.testing.expectEqual(seq_unique, par_unique);

    // 4. Unique PID count
    const seq_pids = try db_seq.getUniquePidCount();
    const par_pids = try db_par.getUniquePidCount();
    try std.testing.expectEqual(seq_pids, par_pids);

    // 5. Failed syscall count
    const seq_failed = try db_seq.getFailedSyscallCount();
    const par_failed = try db_par.getFailedSyscallCount();
    try std.testing.expectEqual(seq_failed, par_failed);

    // Expected values
    try std.testing.expectEqual(@as(i64, num_files * lines_per_file), seq_count);
    try std.testing.expectEqual(@as(usize, num_files), par_stats.files_processed);
}

test "parallel processing with single file" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-parallel-single";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create single test file
    const filename = try std.fmt.allocPrint(allocator, "{s}/trace.5000", .{test_dir});
    defer allocator.free(filename);

    {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        for (0..10) |i| {
            const line = try std.fmt.allocPrint(
                allocator,
                "10:00:00.{d:06} write(1, \"test\", 4) = 4 <0.000001>\n",
                .{i},
            );
            defer allocator.free(line);
            try file.writeAll(line);
        }
    }

    // Process with 4 workers (only 1 will have work)
    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.db", .{test_dir});
    defer allocator.free(db_path);

    var db = try Database.init(db_path);
    defer db.deinit();

    const files = [_][]const u8{filename};
    const stats = try processFilesParallel(allocator, &db, &files, 4);

    // Verify results
    try std.testing.expectEqual(@as(usize, 1), stats.total_files);
    try std.testing.expectEqual(@as(usize, 1), stats.files_processed);
    try std.testing.expectEqual(@as(usize, 10), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 10), stats.parsed_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.failed_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.files_with_errors);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 10), count);
}

test "parallel processing with empty file list" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-parallel-empty";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.db", .{test_dir});
    defer allocator.free(db_path);

    var db = try Database.init(db_path);
    defer db.deinit();

    // Process with empty file list
    const files: []const []const u8 = &[_][]const u8{};
    const stats = try processFilesParallel(allocator, &db, files, 4);

    // Should return zeros for everything
    try std.testing.expectEqual(@as(usize, 0), stats.total_files);
    try std.testing.expectEqual(@as(usize, 0), stats.files_processed);
    try std.testing.expectEqual(@as(usize, 0), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 0), count);
}

test "parallel processing with more files than workers" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-parallel-many";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create 10 files, use only 2 workers
    const num_files = 10;
    const lines_per_file = 5;

    var file_list = std.ArrayListUnmanaged([]const u8){};
    defer file_list.deinit(allocator);
    defer for (file_list.items) |fname| allocator.free(fname);

    for (0..num_files) |file_idx| {
        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}/trace.{d}",
            .{ test_dir, file_idx + 2000 },
        );
        try file_list.append(allocator, filename);

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        for (0..lines_per_file) |line_idx| {
            const line = try std.fmt.allocPrint(
                allocator,
                "10:00:00.{d:06} getpid() = {d} <0.000001>\n",
                .{ line_idx, file_idx * 100 + line_idx },
            );
            defer allocator.free(line);
            try file.writeAll(line);
        }
    }

    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.db", .{test_dir});
    defer allocator.free(db_path);

    var db = try Database.init(db_path);
    defer db.deinit();

    // Process with only 2 workers for 10 files
    const stats = try processFilesParallel(allocator, &db, file_list.items, 2);

    // All files should be processed
    try std.testing.expectEqual(@as(usize, num_files), stats.total_files);
    try std.testing.expectEqual(@as(usize, num_files), stats.files_processed);
    try std.testing.expectEqual(@as(usize, num_files * lines_per_file), stats.total_lines);
    try std.testing.expectEqual(@as(usize, num_files * lines_per_file), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, num_files * lines_per_file), count);
}

test "parallel processing with one corrupt file" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-parallel-error";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var file_list = std.ArrayListUnmanaged([]const u8){};
    defer file_list.deinit(allocator);
    defer for (file_list.items) |fname| allocator.free(fname);

    // Create good file 1
    const file1 = try std.fmt.allocPrint(allocator, "{s}/good1.3001", .{test_dir});
    try file_list.append(allocator, file1);
    {
        const f = try std.fs.cwd().createFile(file1, .{});
        defer f.close();
        try f.writeAll("10:00:00.000001 write(1, \"test\", 4) = 4 <0.000001>\n");
        try f.writeAll("10:00:00.000002 write(1, \"test\", 4) = 4 <0.000001>\n");
    }

    // Create non-existent file reference (will error)
    const file2 = try std.fmt.allocPrint(allocator, "{s}/missing.3002", .{test_dir});
    try file_list.append(allocator, file2);

    // Create good file 2
    const file3 = try std.fmt.allocPrint(allocator, "{s}/good2.3003", .{test_dir});
    try file_list.append(allocator, file3);
    {
        const f = try std.fs.cwd().createFile(file3, .{});
        defer f.close();
        try f.writeAll("10:00:00.000003 read(3, \"data\", 4) = 4 <0.000001>\n");
    }

    const db_path = try std.fmt.allocPrint(allocator, "{s}/test.db", .{test_dir});
    defer allocator.free(db_path);

    var db = try Database.init(db_path);
    defer db.deinit();

    // Process files - should handle error gracefully
    const stats = try processFilesParallel(allocator, &db, file_list.items, 2);

    // Should have processed 2 good files
    try std.testing.expectEqual(@as(usize, 3), stats.total_files);
    try std.testing.expectEqual(@as(usize, 2), stats.files_processed);
    try std.testing.expectEqual(@as(usize, 3), stats.total_lines); // 2 + 1
    try std.testing.expectEqual(@as(usize, 3), stats.parsed_lines);
    try std.testing.expectEqual(@as(usize, 1), stats.files_with_errors);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 3), count);
}
