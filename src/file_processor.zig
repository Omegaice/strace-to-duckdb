const std = @import("std");
const parser = @import("parser.zig");
const database = @import("database.zig");
const Database = database.Database;
const types = @import("types.zig");
const utils = @import("utils.zig");
const FileStats = types.FileStats;

/// Line counting statistics
const LineStats = struct {
    total_lines: usize,
    max_line_length: usize,
};

/// Count total lines and find maximum line length in a file
/// Returns error.LineTooLong if any line exceeds max_allowed bytes
fn countLinesAndMaxLength(file_path: []const u8, max_allowed: usize) !LineStats {
    var stats = LineStats{ .total_lines = 0, .max_line_length = 0 };

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var count_buffer: [8192]u8 = undefined;
    var count_reader = file.reader(&count_buffer);

    while (true) {
        const bytes_discarded = count_reader.interface.discardDelimiterInclusive('\n') catch break;
        stats.total_lines += 1;
        stats.max_line_length = @max(stats.max_line_length, bytes_discarded);

        // Fail fast if line exceeds sanity limit
        if (bytes_discarded > max_allowed) {
            std.debug.print("Error: Line {} exceeds maximum allowed size of {} bytes ({} bytes)\n", .{
                stats.total_lines,
                max_allowed,
                bytes_discarded,
            });
            return error.LineTooLong;
        }
    }

    return stats;
}

/// Process a single strace trace file
/// Returns statistics about the processing
pub fn processFile(
    allocator: std.mem.Allocator,
    db: *Database,
    file_path: []const u8,
) !FileStats {
    var stats = FileStats.init();

    // Extract PID from filename
    const filename = std.fs.path.basename(file_path);
    const pid = utils.extractPidFromFilename(filename) orelse 0; // Default to 0 if no PID found

    // Maximum line length we'll process (10MB sanity cap)
    const MAX_LINE_SIZE: usize = 10 * 1024 * 1024;

    // First pass: count total lines and find maximum line length
    // Fails fast with error.LineTooLong if any line > 10MB
    const line_stats = try countLinesAndMaxLength(file_path, MAX_LINE_SIZE);

    // Allocate buffer based on actual maximum line length
    // Use at least 4KB to avoid tiny allocations for empty/small files
    const buffer_size = @max(line_stats.max_line_length, 4096);
    const line_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(line_buffer);

    // NOTE: Caller must call db.beginAppend() before calling this function
    // and db.endAppend() after processing all files

    // Second pass: process file
    // Buffer is sized to max line length, so takeDelimiter should never fail with StreamTooLong
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var reader = file.reader(line_buffer);

    while (reader.interface.takeDelimiter('\n') catch |err| {
        // Should not happen - buffer is sized correctly
        std.debug.print("Unexpected read error: {}\n", .{err});
        return err;
    }) |line| {
        stats.total_lines += 1;

        // Parse the line
        const maybe_syscall = parser.parseLine(allocator, line) catch |err| {
            // Parsing error - count as failed
            stats.failed_lines += 1;
            std.debug.print("Parse error on line {}: {}\n", .{ stats.total_lines, err });
            continue;
        };

        if (maybe_syscall) |syscall| {
            // Successfully parsed - append to database using fast appender API
            db.appendSyscall(filename, pid, syscall) catch |err| {
                // Database append error
                stats.failed_lines += 1;
                std.debug.print("Append error on line {}: {}\n", .{ stats.total_lines, err });
                continue;
            };
            stats.parsed_lines += 1;
        } else {
            // Line didn't match any pattern (comment, empty, etc.)
            // Don't count as failed - these are expected
        }
    }

    return stats;
}

// ============================================================================
// TESTS
// ============================================================================

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

    try db.beginAppend();

    // Process the file
    const stats = try processFile(allocator, &db, test_file);

    // Flush appender before querying
    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

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

    try db.beginAppend();

    const stats = try processFile(allocator, &db, test_file);

    try db.endAppend();

    // All 5 lines should be counted correctly
    try std.testing.expectEqual(@as(usize, 5), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 5), stats.parsed_lines);

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 5), count);
}

test "countLinesAndMaxLength with normal file" {
    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/count-test.7777";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create file with known line lengths
    try file.writeAll("short line\n"); // 11 bytes (10 + newline)
    try file.writeAll("medium length line here\n"); // 24 bytes
    try file.writeAll("x\n"); // 2 bytes
    const long_line = "L" ** 5000;
    try file.writeAll(long_line);
    try file.writeAll("\n"); // 5001 bytes
    file.close();

    const stats = try countLinesAndMaxLength(test_file, 10 * 1024 * 1024);

    try std.testing.expectEqual(@as(usize, 4), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 5001), stats.max_line_length);
}

test "countLinesAndMaxLength fails on line exceeding limit" {
    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/toolong.8888";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create file with line exceeding 1MB limit (using smaller limit for test speed)
    try file.writeAll("normal line\n");
    const huge_line = "X" ** (1024 * 1024 + 100); // Just over 1MB
    try file.writeAll(huge_line);
    try file.writeAll("\n");
    file.close();

    // Should fail with LineTooLong when limit is 1MB
    const result = countLinesAndMaxLength(test_file, 1024 * 1024);
    try std.testing.expectError(error.LineTooLong, result);
}

test "countLinesAndMaxLength handles exactly at limit" {
    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/exactlimit.9999";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create file with line exactly at limit (100KB for test speed)
    const limit = 100 * 1024;
    const exact_line = "E" ** (limit - 1); // -1 for newline
    try file.writeAll(exact_line);
    try file.writeAll("\n");
    file.close();

    // Should succeed - exactly at limit
    const stats = try countLinesAndMaxLength(test_file, limit);

    try std.testing.expectEqual(@as(usize, 1), stats.total_lines);
    try std.testing.expectEqual(@as(usize, limit), stats.max_line_length);
}

test "processFile fails with LineTooLong error for oversized line" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/process-toolong.1010";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create file with valid line followed by line exceeding 10MB
    try file.writeAll("10:23:45.123456 getpid() = 1234 <0.000010>\n");

    // Write an 11MB line (this will be slow, but validates the real limit)
    const huge_line = "Z" ** (11 * 1024 * 1024);
    try file.writeAll(huge_line);
    try file.writeAll("\n");
    file.close();

    var db = try Database.init(":memory:");
    defer db.deinit();

    // Should fail with LineTooLong
    const result = processFile(allocator, &db, test_file);
    try std.testing.expectError(error.LineTooLong, result);
}

test "countLinesAndMaxLength with empty file" {
    const test_dir = "zig-cache/test-traces";
    try std.fs.cwd().makePath(test_dir);

    const test_file = "zig-cache/test-traces/empty-count.1111";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer std.fs.cwd().deleteFile(test_file) catch {};
    file.close();

    const stats = try countLinesAndMaxLength(test_file, 10 * 1024 * 1024);

    try std.testing.expectEqual(@as(usize, 0), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.max_line_length);
}
