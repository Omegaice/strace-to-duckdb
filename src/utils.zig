const std = @import("std");

/// Extract PID from trace filename
/// Expected format: *.<pid> or *.trace.<pid>
/// Returns null if no PID found
pub fn extractPidFromFilename(filename: []const u8) ?i32 {
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

// ============================================================================
// TESTS
// ============================================================================

test "extractPidFromFilename from standard filename" {
    try std.testing.expectEqual(@as(?i32, 12345), extractPidFromFilename("zoom-trace-20240101-120000.12345"));
    try std.testing.expectEqual(@as(?i32, 5678), extractPidFromFilename("strace.5678"));
    try std.testing.expectEqual(@as(?i32, 999), extractPidFromFilename("trace.999"));
}

test "extractPidFromFilename from filename with multiple dots" {
    try std.testing.expectEqual(@as(?i32, 12345), extractPidFromFilename("my.trace.file.12345"));
    try std.testing.expectEqual(@as(?i32, 99), extractPidFromFilename("a.b.c.d.99"));
}

test "extractPidFromFilename returns null for no PID" {
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("no-pid-here.txt"));
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("trace.log"));
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("invalid.abc"));
}

test "extractPidFromFilename returns null for empty extension" {
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("file."));
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("trace."));
}

test "extractPidFromFilename returns null for no extension" {
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("noextension"));
    try std.testing.expectEqual(@as(?i32, null), extractPidFromFilename("trace"));
}
