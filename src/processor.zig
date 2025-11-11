const std = @import("std");
const parser = @import("parser.zig");
const database = @import("database.zig");
const Database = database.Database;

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

    // Open file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Read file line by line using buffered reader
    var file_buffer: [8192]u8 = undefined;
    var reader = file.reader(&file_buffer);

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
            continue;
        };

        if (maybe_syscall) |syscall| {
            // Successfully parsed - insert into database
            db.insertSyscall(filename, pid, syscall) catch |err| {
                // Database insert error
                stats.failed_lines += 1;
                std.debug.print("Insert error on line {}: {}\n", .{ stats.total_lines, err });
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
