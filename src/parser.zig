const std = @import("std");
const types = @import("types.zig");
const Syscall = types.Syscall;

/// Result of parsing a line - either a syscall or null if unparseable
pub const ParseResult = ?Syscall;

/// Parse a single line of strace output
/// Caller owns the returned Syscall strings (they reference the input line)
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !ParseResult {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    // Empty line
    if (trimmed.len == 0) {
        return null;
    }

    // Try regular pattern first
    if (try parseRegular(allocator, trimmed)) |syscall| {
        return syscall;
    }

    // Try unfinished pattern
    if (try parseUnfinished(allocator, trimmed)) |syscall| {
        return syscall;
    }

    // Try resumed pattern
    if (try parseResumed(allocator, trimmed)) |syscall| {
        return syscall;
    }

    // No match
    return null;
}

/// Parse regular syscall format:
/// HH:MM:SS.microseconds syscall(args) = return_value [ERROR (msg)] <duration>
fn parseRegular(allocator: std.mem.Allocator, line: []const u8) !?Syscall {
    _ = allocator;

    // Find timestamp (format: HH:MM:SS.microseconds)
    const timestamp_end = blk: {
        var i: usize = 0;
        var dots: usize = 0;
        var colons: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == ':') colons += 1;
            if (c == '.') dots += 1;
            if (c == ' ' and colons >= 2 and dots >= 1) break :blk i;
        }
        return null;
    };

    const timestamp = line[0..timestamp_end];
    var rest = std.mem.trimLeft(u8, line[timestamp_end..], " ");

    // Find syscall name (ends with '(')
    const syscall_end = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const syscall = rest[0..syscall_end];
    rest = rest[syscall_end + 1 ..]; // skip '('

    // Find end of args (look for ') = ')
    const args_end = std.mem.indexOf(u8, rest, ") = ") orelse return null;
    const args = rest[0..args_end];
    rest = rest[args_end + 4 ..]; // skip ') = '

    // Parse return value (can be decimal, hex, or ?)
    var return_value: ?i64 = null;
    var error_code: ?[]const u8 = null;
    var error_message: ?[]const u8 = null;
    var duration: ?f64 = null;

    // Find next space or end of line
    const ret_end = std.mem.indexOfAny(u8, rest, " <") orelse rest.len;
    const ret_str = rest[0..ret_end];

    if (std.mem.eql(u8, ret_str, "?")) {
        return_value = null;
    } else if (std.mem.startsWith(u8, ret_str, "0x")) {
        return_value = std.fmt.parseInt(i64, ret_str[2..], 16) catch return null;
    } else {
        return_value = std.fmt.parseInt(i64, ret_str, 10) catch return null;
    }

    rest = if (ret_end < rest.len) rest[ret_end..] else "";
    rest = std.mem.trimLeft(u8, rest, " ");

    // Check for error code (uppercase word followed by '(')
    // Error codes ONLY appear when the syscall failed (return_value < 0)
    const is_failure = if (return_value) |val| val < 0 else false;
    if (is_failure and rest.len > 0 and rest[0] != '<') {
        // Should be error code
        const error_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        error_code = rest[0..error_end];
        rest = std.mem.trimLeft(u8, rest[error_end..], " ");

        // Parse error message between '(' and ')'
        if (rest.len > 0 and rest[0] == '(') {
            const msg_end = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            error_message = rest[1..msg_end]; // skip '('
            rest = rest[msg_end + 1 ..]; // skip ')'
            rest = std.mem.trimLeft(u8, rest, " ");
        }
    }

    // Check for duration <seconds>
    if (rest.len > 0 and rest[0] == '<') {
        const duration_end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const duration_str = rest[1..duration_end];
        duration = std.fmt.parseFloat(f64, duration_str) catch return null;
    }

    return Syscall.init(
        timestamp,
        syscall,
        args,
        return_value,
        error_code,
        error_message,
        duration,
        false,
        false,
    );
}

/// Parse unfinished syscall format:
/// HH:MM:SS.microseconds syscall(args <unfinished ...>
fn parseUnfinished(allocator: std.mem.Allocator, line: []const u8) !?Syscall {
    _ = allocator;

    // Check for "<unfinished ...>"
    if (std.mem.indexOf(u8, line, "<unfinished ...>") == null) {
        return null;
    }

    // Find timestamp
    const timestamp_end = blk: {
        var i: usize = 0;
        var dots: usize = 0;
        var colons: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == ':') colons += 1;
            if (c == '.') dots += 1;
            if (c == ' ' and colons >= 2 and dots >= 1) break :blk i;
        }
        return null;
    };

    const timestamp = line[0..timestamp_end];
    var rest = std.mem.trimLeft(u8, line[timestamp_end..], " ");

    // Find syscall name
    const syscall_end = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const syscall = rest[0..syscall_end];
    rest = rest[syscall_end + 1 ..]; // skip '('

    // Args are everything before '<unfinished' (including trailing space)
    const unfinished_marker = "<unfinished ...>";
    const marker_pos = std.mem.indexOf(u8, rest, unfinished_marker) orelse return null;
    const args = rest[0..marker_pos];

    return Syscall.init(
        timestamp,
        syscall,
        args,
        null,
        null,
        null,
        null,
        true,
        false,
    );
}

/// Parse resumed syscall format:
/// HH:MM:SS.microseconds <... syscall resumed>args) = return_value [ERROR (msg)] <duration>
fn parseResumed(allocator: std.mem.Allocator, line: []const u8) !?Syscall {
    _ = allocator;

    // Check for "<... " and " resumed>"
    if (std.mem.indexOf(u8, line, "<... ") == null or std.mem.indexOf(u8, line, " resumed>") == null) {
        return null;
    }

    // Find timestamp
    const timestamp_end = blk: {
        var i: usize = 0;
        var dots: usize = 0;
        var colons: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == ':') colons += 1;
            if (c == '.') dots += 1;
            if (c == ' ' and colons >= 2 and dots >= 1) break :blk i;
        }
        return null;
    };

    const timestamp = line[0..timestamp_end];
    var rest = std.mem.trimLeft(u8, line[timestamp_end..], " ");

    // Skip "<... "
    if (!std.mem.startsWith(u8, rest, "<... ")) return null;
    rest = rest[5..]; // skip "<... "

    // Find syscall name (ends with ' resumed>')
    const resumed_pos = std.mem.indexOf(u8, rest, " resumed>") orelse return null;
    const syscall = rest[0..resumed_pos];
    rest = rest[resumed_pos + 9 ..]; // skip ' resumed>'

    // Find args (everything before ') = ')
    const args_end = std.mem.indexOf(u8, rest, ") = ") orelse return null;
    const args = rest[0..args_end];
    rest = rest[args_end + 4 ..]; // skip ') = '

    // Parse return value
    var return_value: ?i64 = null;
    var error_code: ?[]const u8 = null;
    var error_message: ?[]const u8 = null;
    var duration: ?f64 = null;

    const ret_end = std.mem.indexOfAny(u8, rest, " <") orelse rest.len;
    const ret_str = rest[0..ret_end];

    if (std.mem.eql(u8, ret_str, "?")) {
        return_value = null;
    } else if (std.mem.startsWith(u8, ret_str, "0x")) {
        return_value = std.fmt.parseInt(i64, ret_str[2..], 16) catch return null;
    } else {
        return_value = std.fmt.parseInt(i64, ret_str, 10) catch return null;
    }

    rest = if (ret_end < rest.len) rest[ret_end..] else "";
    rest = std.mem.trimLeft(u8, rest, " ");

    // Check for error code
    // Error codes ONLY appear when the syscall failed (return_value < 0)
    const is_failure = if (return_value) |val| val < 0 else false;
    if (is_failure and rest.len > 0 and rest[0] != '<') {
        const error_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        error_code = rest[0..error_end];
        rest = std.mem.trimLeft(u8, rest[error_end..], " ");

        if (rest.len > 0 and rest[0] == '(') {
            const msg_end = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            error_message = rest[1..msg_end];
            rest = rest[msg_end + 1 ..];
            rest = std.mem.trimLeft(u8, rest, " ");
        }
    }

    // Check for duration
    if (rest.len > 0 and rest[0] == '<') {
        const duration_end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const duration_str = rest[1..duration_end];
        duration = std.fmt.parseFloat(f64, duration_str) catch return null;
    }

    return Syscall.init(
        timestamp,
        syscall,
        args,
        return_value,
        error_code,
        error_message,
        duration,
        false,
        true,
    );
}

// ============================================================================
// TESTS
// ============================================================================

test "parse empty line returns null" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "");
    try std.testing.expectEqual(@as(?Syscall, null), result);
}

test "parse whitespace only returns null" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "   \t  \n");
    try std.testing.expectEqual(@as(?Syscall, null), result);
}

test "parse regular syscall with duration" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 open(\"/tmp/file\", O_RDONLY) = 3 <0.000042>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("10:23:45.123456", syscall.timestamp);
    try std.testing.expectEqualStrings("open", syscall.syscall);
    try std.testing.expectEqualStrings("\"/tmp/file\", O_RDONLY", syscall.args);
    try std.testing.expectEqual(@as(?i64, 3), syscall.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_code);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_message);
    try std.testing.expectEqual(@as(?f64, 0.000042), syscall.duration);
    try std.testing.expectEqual(false, syscall.unfinished);
    try std.testing.expectEqual(false, syscall.resumed);
}

test "parse regular syscall without duration" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 getpid() = 12345";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("10:23:45.123456", syscall.timestamp);
    try std.testing.expectEqualStrings("getpid", syscall.syscall);
    try std.testing.expectEqualStrings("", syscall.args);
    try std.testing.expectEqual(@as(?i64, 12345), syscall.return_value);
    try std.testing.expectEqual(@as(?f64, null), syscall.duration);
}

test "parse syscall with error" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 open(\"/tmp/file\", O_RDONLY) = -1 ENOENT (No such file or directory) <0.000042>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("open", syscall.syscall);
    try std.testing.expectEqual(@as(?i64, -1), syscall.return_value);
    try std.testing.expectEqualStrings("ENOENT", syscall.error_code.?);
    try std.testing.expectEqualStrings("No such file or directory", syscall.error_message.?);
    try std.testing.expectEqual(@as(?f64, 0.000042), syscall.duration);
}

test "parse hex return value" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 mmap(NULL, 4096, PROT_READ) = 0x7f8a3c000000 <0.000042>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("mmap", syscall.syscall);
    try std.testing.expectEqual(@as(?i64, 0x7f8a3c000000), syscall.return_value);
}

test "parse unknown return value" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 exit(0) = ?";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("exit", syscall.syscall);
    try std.testing.expectEqual(@as(?i64, null), syscall.return_value);
}

test "parse unfinished syscall" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 read(3, <unfinished ...>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("10:23:45.123456", syscall.timestamp);
    try std.testing.expectEqualStrings("read", syscall.syscall);
    try std.testing.expectEqualStrings("3, ", syscall.args);
    try std.testing.expectEqual(@as(?i64, null), syscall.return_value);
    try std.testing.expectEqual(true, syscall.unfinished);
    try std.testing.expectEqual(false, syscall.resumed);
}

test "parse resumed syscall" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 <... read resumed>\"data\", 100) = 4 <0.000042>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("10:23:45.123456", syscall.timestamp);
    try std.testing.expectEqualStrings("read", syscall.syscall);
    try std.testing.expectEqualStrings("\"data\", 100", syscall.args);
    try std.testing.expectEqual(@as(?i64, 4), syscall.return_value);
    try std.testing.expectEqual(@as(?f64, 0.000042), syscall.duration);
    try std.testing.expectEqual(false, syscall.unfinished);
    try std.testing.expectEqual(true, syscall.resumed);
}

test "parse resumed syscall with error" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 <... read resumed>\"data\", 100) = -1 EINTR (Interrupted) <0.000042>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;

    try std.testing.expectEqualStrings("read", syscall.syscall);
    try std.testing.expectEqual(@as(?i64, -1), syscall.return_value);
    try std.testing.expectEqualStrings("EINTR", syscall.error_code.?);
    try std.testing.expectEqualStrings("Interrupted", syscall.error_message.?);
    try std.testing.expectEqual(true, syscall.resumed);
}

test "parse invalid line returns null" {
    const allocator = std.testing.allocator;
    const line = "this is not a valid strace line";
    const result = try parseLine(allocator, line);
    try std.testing.expectEqual(@as(?Syscall, null), result);
}

test "parse garbage returns null" {
    const allocator = std.testing.allocator;
    const line = "!@#$%^&*()";
    const result = try parseLine(allocator, line);
    try std.testing.expectEqual(@as(?Syscall, null), result);
}

test "successful syscall with positive return value has no error code" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 read(3, \"data\", 100) = 100 <0.000050>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;
    try std.testing.expectEqual(@as(?i64, 100), syscall.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_code);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_message);
}

test "successful syscall returning zero has no error code" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 close(3) = 0 <0.000010>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;
    try std.testing.expectEqual(@as(?i64, 0), syscall.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_code);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_message);
}

test "poll with ready file descriptors shown after return value" {
    const allocator = std.testing.allocator;
    // poll() shows which FDs are ready: = 1 ([{fd=3, revents=POLLIN}])
    const line = "10:23:45.123456 poll([{fd=3, events=POLLIN}], 1, -1) = 1 ([{fd=3, revents=POLLIN}]) <0.000100>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;
    try std.testing.expectEqualStrings("poll", syscall.syscall);
    try std.testing.expectEqual(@as(?i64, 1), syscall.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_code);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_message);
}

test "select with ready file descriptors shown after return value" {
    const allocator = std.testing.allocator;
    // select() shows ready FDs: = 3 (in [5 6], out [7])
    const line = "10:23:45.123456 select(10, [5 6 7], [7], NULL, NULL) = 3 (in [5 6], out [7]) <0.000150>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;
    try std.testing.expectEqualStrings("select", syscall.syscall);
    try std.testing.expectEqual(@as(?i64, 3), syscall.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_code);
}

test "large positive return value has no error code" {
    const allocator = std.testing.allocator;
    const line = "10:23:45.123456 read(3, \"...\", 1048576) = 1048576 <0.001234>";
    const result = try parseLine(allocator, line);

    try std.testing.expect(result != null);
    const syscall = result.?;
    try std.testing.expectEqual(@as(?i64, 1048576), syscall.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), syscall.error_code);
}

test "only negative return values should have error codes" {
    const allocator = std.testing.allocator;

    // Success case (return 0) - no error
    const success_line = "10:23:45.123456 close(3) = 0 <0.000010>";
    const success = try parseLine(allocator, success_line);
    try std.testing.expect(success != null);
    try std.testing.expectEqual(@as(?i64, 0), success.?.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), success.?.error_code);

    // Failure case (return -1) - has error
    const fail_line = "10:23:45.123456 open(\"/tmp/missing\", O_RDONLY) = -1 ENOENT (No such file) <0.000042>";
    const fail = try parseLine(allocator, fail_line);
    try std.testing.expect(fail != null);
    try std.testing.expectEqual(@as(?i64, -1), fail.?.return_value);
    try std.testing.expectEqualStrings("ENOENT", fail.?.error_code.?);
    try std.testing.expectEqualStrings("No such file", fail.?.error_message.?);
}

test "various successful syscall patterns have no error codes" {
    const allocator = std.testing.allocator;

    // getpid returns PID
    const getpid_line = "10:23:45.123456 getpid() = 12345";
    const getpid_result = try parseLine(allocator, getpid_line);
    try std.testing.expect(getpid_result != null);
    try std.testing.expectEqual(@as(?i64, 12345), getpid_result.?.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), getpid_result.?.error_code);

    // write returns bytes written
    const write_line = "10:23:45.123456 write(1, \"hello\", 5) = 5 <0.000020>";
    const write_result = try parseLine(allocator, write_line);
    try std.testing.expect(write_result != null);
    try std.testing.expectEqual(@as(?i64, 5), write_result.?.return_value);
    try std.testing.expectEqual(@as(?[]const u8, null), write_result.?.error_code);
}
