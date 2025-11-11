const std = @import("std");

/// Represents a parsed system call from strace output
pub const Syscall = struct {
    timestamp: []const u8,
    syscall: []const u8,
    args: []const u8,
    return_value: ?i64, // null for "?"
    error_code: ?[]const u8,
    error_message: ?[]const u8,
    duration: ?f64, // in seconds
    unfinished: bool = false,
    resumed: bool = false,

    /// Create a syscall with all fields initialized
    pub fn init(
        timestamp: []const u8,
        syscall: []const u8,
        args: []const u8,
        return_value: ?i64,
        error_code: ?[]const u8,
        error_message: ?[]const u8,
        duration: ?f64,
        unfinished: bool,
        resumed: bool,
    ) Syscall {
        return Syscall{
            .timestamp = timestamp,
            .syscall = syscall,
            .args = args,
            .return_value = return_value,
            .error_code = error_code,
            .error_message = error_message,
            .duration = duration,
            .unfinished = unfinished,
            .resumed = resumed,
        };
    }
};
