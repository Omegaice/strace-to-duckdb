const std = @import("std");
const parser = @import("parser.zig");
const database = @import("database.zig");
const progress = @import("progress.zig");
const Database = database.Database;
const ProgressBar = progress.ProgressBar;

/// Statistics from processing a trace file
pub const ProcessStats = struct {
    total_lines: usize,
    parsed_lines: usize,
    failed_lines: usize,

    pub fn init() ProcessStats {
        return .{
            .total_lines = 0,
            .parsed_lines = 0,
            .failed_lines = 0,
        };
    }
};

/// Extract PID from trace filename
/// Expected format: *.<pid> or *.trace.<pid>
/// Returns null if no PID found
pub fn extractPid(filename: []const u8) ?i32 {
    // Find the last '.' in the filename
    var i: usize = filename.len;
    while (i > 0) {
        i -= 1;
        if (filename[i] == '.') {
            // Everything after the last '.' should be the PID
            const pid_str = filename[i + 1 ..];
            if (pid_str.len == 0) return null;

            // Try to parse as integer
            const pid = std.fmt.parseInt(i32, pid_str, 10) catch return null;
            return pid;
        }
    }

    return null;
}

/// Process a single strace trace file
/// Returns statistics about the processing
pub fn processFile(
    allocator: std.mem.Allocator,
    db: *Database,
    file_path: []const u8,
) !ProcessStats {
    var stats = ProcessStats.init();

    // Extract PID from filename
    const filename = std.fs.path.basename(file_path);
    const pid = extractPid(filename) orelse 0; // Default to 0 if no PID found

    // Maximum line length we'll process (10MB sanity cap)
    const MAX_LINE_SIZE: usize = 10 * 1024 * 1024;

    // First pass: count total lines and find maximum line length
    var total_lines: usize = 0;
    var max_line_length: usize = 0;
    {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var count_buffer: [8192]u8 = undefined;
        var count_reader = file.reader(&count_buffer);

        while (true) {
            const bytes_discarded = count_reader.interface.discardDelimiterInclusive('\n') catch break;
            total_lines += 1;
            max_line_length = @max(max_line_length, bytes_discarded);
        }
    }

    // Allocate buffer based on actual maximum line length (capped at 10MB)
    // Use at least 4KB to avoid tiny allocations for empty/small files
    const buffer_size = @min(@max(max_line_length, 4096), MAX_LINE_SIZE);
    const line_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(line_buffer);

    // Create progress bar with truncated filename (keep it short to fit terminal width)
    const short_name = if (filename.len > 20) filename[0..20] else filename;
    var pbar = ProgressBar.init(short_name, total_lines);

    // Second pass: process file with progress
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var reader = file.reader(line_buffer);

    while (reader.interface.takeDelimiter('\n') catch |err| {
        std.debug.print("Read error: {}\n", .{err});
        return err;
    }) |line| {
        stats.total_lines += 1;

        // Parse the line
        const maybe_syscall = parser.parseLine(allocator, line) catch |err| {
            // Parsing error - count as failed
            stats.failed_lines += 1;
            std.debug.print("Parse error on line {}: {}\n", .{ stats.total_lines, err });
            try pbar.increment();
            continue;
        };

        if (maybe_syscall) |syscall| {
            // Successfully parsed - insert into database
            db.insertSyscall(filename, pid, syscall) catch |err| {
                // Database insert error
                stats.failed_lines += 1;
                std.debug.print("Insert error on line {}: {}\n", .{ stats.total_lines, err });
                try pbar.increment();
                continue;
            };
            stats.parsed_lines += 1;
        } else {
            // Line didn't match any pattern (comment, empty, etc.)
            // Don't count as failed - these are expected
        }

        // Update progress
        try pbar.increment();
    }

    // Finish progress bar
    try pbar.finish();

    return stats;
}

// ============================================================================
// TESTS
// ============================================================================

test "extractPid from standard filename" {
    try std.testing.expectEqual(@as(?i32, 12345), extractPid("zoom-trace-20240101-120000.12345"));
    try std.testing.expectEqual(@as(?i32, 5678), extractPid("strace.5678"));
    try std.testing.expectEqual(@as(?i32, 999), extractPid("trace.999"));
}

test "extractPid from filename with multiple dots" {
    try std.testing.expectEqual(@as(?i32, 12345), extractPid("my.trace.file.12345"));
    try std.testing.expectEqual(@as(?i32, 99), extractPid("a.b.c.d.99"));
}

test "extractPid returns null for no PID" {
    try std.testing.expectEqual(@as(?i32, null), extractPid("no-pid-here.txt"));
    try std.testing.expectEqual(@as(?i32, null), extractPid("trace.log"));
    try std.testing.expectEqual(@as(?i32, null), extractPid("invalid.abc"));
}

test "extractPid returns null for empty extension" {
    try std.testing.expectEqual(@as(?i32, null), extractPid("file."));
    try std.testing.expectEqual(@as(?i32, null), extractPid("trace."));
}

test "extractPid returns null for no extension" {
    try std.testing.expectEqual(@as(?i32, null), extractPid("noextension"));
    try std.testing.expectEqual(@as(?i32, null), extractPid("trace"));
}

test "processFile with valid trace data" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/test.1234";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Write some test strace data
    const test_data =
        \\10:23:45.123456 open("/tmp/file", O_RDONLY) = 3 <0.000042>
        \\10:23:45.123457 read(3, "data", 4) = 4 <0.000050>
        \\10:23:45.123458 close(3) = 0 <0.000010>
        \\
        \\# This is a comment line
        \\invalid garbage line
        \\10:23:45.123459 write(1, "hello", 5) = 5 <0.000020>
    ;
    try file.writeAll(test_data);
    file.close();

    // Create in-memory database
    var db = try Database.init(":memory:");
    defer db.deinit();

    // Process the file
    const stats = try processFile(allocator, &db, test_file);

    // Verify statistics
    try std.testing.expectEqual(@as(usize, 7), stats.total_lines); // 7 lines total
    try std.testing.expectEqual(@as(usize, 4), stats.parsed_lines); // 4 valid syscalls

    // Verify data in database
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 4), count);

    // Verify PID was extracted correctly
    const pid_count = try db.getUniquePidCount();
    try std.testing.expectEqual(@as(i64, 1), pid_count);
}

test "processFile with empty file" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/empty.5678";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    try std.testing.expectEqual(@as(usize, 0), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 0), count);
}

test "processFile with only invalid lines" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/invalid.9999";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data =
        \\# Comment line
        \\
        \\Invalid line 1
        \\Another bad line
        \\Not strace output
    ;
    try file.writeAll(test_data);
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    try std.testing.expectEqual(@as(usize, 5), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 0), count);
}

test "processFile with syscall errors" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/errors.1111";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data =
        \\10:23:45.123456 open("/tmp/file", O_RDONLY) = -1 ENOENT (No such file) <0.000042>
        \\10:23:45.123457 read(3, "data", 4) = -1 EBADF (Bad file descriptor) <0.000050>
    ;
    try file.writeAll(test_data);
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    try std.testing.expectEqual(@as(usize, 2), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 2), stats.parsed_lines);

    // Both syscalls should be in DB with error codes
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), count);

    const failed_count = try db.getFailedSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), failed_count);
}

test "processFile with unfinished and resumed syscalls" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/async.2222";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data =
        \\10:23:45.123456 read(3, <unfinished ...>
        \\10:23:45.123457 write(1, "hello", 5) = 5 <0.000020>
        \\10:23:45.123458 <... read resumed>"data", 100) = 4 <0.000042>
    ;
    try file.writeAll(test_data);
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    try std.testing.expectEqual(@as(usize, 3), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 3), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 3), count);
}

test "processFile with very long lines exceeding buffer size" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/longlines.3333";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create a line longer than 8192 bytes (the buffer size)
    // This simulates strace output with very long arguments
    const long_data = "A" ** 10000; // 10KB line

    try file.writeAll("10:23:45.123456 read(3, \"");
    try file.writeAll(long_data);
    try file.writeAll("\", 10000) = 10000 <0.000100>\n");
    try file.writeAll("10:23:45.123457 write(1, \"short\", 5) = 5 <0.000020>\n");
    try file.writeAll("10:23:45.123458 read(4, \"");
    try file.writeAll(long_data);
    try file.writeAll("\", 10000) = 10000 <0.000100>\n");
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    // Should count all 3 lines correctly despite some being > 8192 bytes
    try std.testing.expectEqual(@as(usize, 3), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 3), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 3), count);
}

test "processFile with extremely long line (50KB)" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/extremelong.4444";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create an extremely long line (50KB) - multiple times larger than buffer
    const huge_data = "X" ** 50000;

    try file.writeAll("10:23:45.123456 read(3, \"");
    try file.writeAll(huge_data);
    try file.writeAll("\", 50000) = 50000 <0.001000>\n");
    try file.writeAll("10:23:45.123457 close(3) = 0 <0.000010>\n");
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    // Should handle extremely long lines correctly
    try std.testing.expectEqual(@as(usize, 2), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 2), stats.parsed_lines);
}

test "processFile with file ending without newline" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/nonewline.5555";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // File with lines but no trailing newline on the last line
    const test_data = "10:23:45.123456 open(\"/tmp/file\", O_RDONLY) = 3 <0.000042>\n10:23:45.123457 close(3) = 0 <0.000010>";
    try file.writeAll(test_data);
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    // Both lines should be counted even though last one has no newline
    try std.testing.expectEqual(@as(usize, 2), stats.total_lines);
}

test "processFile counts lines correctly with mixed lengths" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/mixed.6666";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const long_data = "B" ** 9000; // Just over 8KB buffer size

    // Mix of short and long lines
    try file.writeAll("10:23:45.123456 getpid() = 1234 <0.000010>\n"); // Short
    try file.writeAll("10:23:45.123457 read(3, \"");
    try file.writeAll(long_data);
    try file.writeAll("\", 9000) = 9000 <0.000100>\n"); // Long
    try file.writeAll("10:23:45.123458 write(1, \"test\", 4) = 4 <0.000020>\n"); // Short
    try file.writeAll("10:23:45.123459 read(4, \"");
    try file.writeAll(long_data);
    try file.writeAll("\", 9000) = 9000 <0.000100>\n"); // Long
    try file.writeAll("10:23:45.123460 close(3) = 0 <0.000010>\n"); // Short
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    const stats = try processFile(allocator, &db, test_file);

    // All 5 lines should be counted correctly
    try std.testing.expectEqual(@as(usize, 5), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 5), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 5), count);
}
