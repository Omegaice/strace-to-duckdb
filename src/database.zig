const std = @import("std");
const types = @import("types.zig");
const Syscall = types.Syscall;

// Import DuckDB C API
const c = @cImport({
    @cInclude("duckdb.h");
});

/// Database handle for strace data
pub const Database = struct {
    db: c.duckdb_database,
    conn: c.duckdb_connection,
    path: []const u8,
    appender: ?c.duckdb_appender,

    /// Initialize database and create schema
    /// Path can be a file path or ":memory:" for in-memory database
    pub fn init(path: []const u8) !Database {
        var db: c.duckdb_database = undefined;
        var conn: c.duckdb_connection = undefined;

        // Open database - DuckDB will create if doesn't exist, or overwrite if it does
        const path_cstr = if (std.mem.eql(u8, path, ":memory:"))
            null
        else
            @as([*c]const u8, @ptrCast(path.ptr));

        if (c.duckdb_open(path_cstr, &db) == c.DuckDBError) {
            return error.DatabaseOpenFailed;
        }
        errdefer c.duckdb_close(&db);

        // Connect to database
        if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
            return error.DatabaseConnectFailed;
        }
        errdefer c.duckdb_disconnect(&conn);

        var database = Database{
            .db = db,
            .conn = conn,
            .path = path,
            .appender = null,
        };

        // Create schema
        try database.createSchema();

        return database;
    }

    /// Close database and clean up resources
    pub fn deinit(self: *Database) void {
        // Clean up appender if it exists
        if (self.appender != null) {
            _ = c.duckdb_appender_destroy(&self.appender.?);
        }
        c.duckdb_disconnect(&self.conn);
        c.duckdb_close(&self.db);
    }

    /// Create database schema (tables and indexes)
    fn createSchema(self: *Database) !void {
        // Create syscalls table
        const create_table =
            \\CREATE TABLE IF NOT EXISTS syscalls (
            \\    trace_file VARCHAR,
            \\    pid INTEGER,
            \\    timestamp VARCHAR,
            \\    syscall VARCHAR,
            \\    args TEXT,
            \\    return_value BIGINT,
            \\    error_code VARCHAR,
            \\    error_message VARCHAR,
            \\    duration DOUBLE,
            \\    unfinished BOOLEAN DEFAULT FALSE,
            \\    resumed BOOLEAN DEFAULT FALSE
            \\)
        ;

        if (c.duckdb_query(self.conn, create_table, null) == c.DuckDBError) {
            return error.SchemaCreationFailed;
        }

        // Create indexes for common queries
        const indexes = [_][]const u8{
            "CREATE INDEX IF NOT EXISTS idx_syscall ON syscalls(syscall)",
            "CREATE INDEX IF NOT EXISTS idx_pid ON syscalls(pid)",
            "CREATE INDEX IF NOT EXISTS idx_error ON syscalls(error_code)",
            "CREATE INDEX IF NOT EXISTS idx_trace_file ON syscalls(trace_file)",
        };

        for (indexes) |index_sql| {
            if (c.duckdb_query(self.conn, @ptrCast(index_sql.ptr), null) == c.DuckDBError) {
                return error.IndexCreationFailed;
            }
        }
    }

    /// Begin bulk appending syscalls using DuckDB's appender API
    /// This is much faster than individual inserts for large batches
    pub fn beginAppend(self: *Database) !void {
        // Destroy existing appender if any
        if (self.appender != null) {
            _ = c.duckdb_appender_destroy(&self.appender.?);
        }

        var appender: c.duckdb_appender = undefined;
        if (c.duckdb_appender_create(self.conn, null, "syscalls", &appender) == c.DuckDBError) {
            return error.AppenderCreateFailed;
        }

        self.appender = appender;
    }

    /// Append a single syscall using the appender API
    /// Must call beginAppend() before using this method
    pub fn appendSyscall(
        self: *Database,
        trace_file: []const u8,
        pid: i32,
        syscall: Syscall,
    ) !void {
        const appender = self.appender orelse return error.AppenderNotInitialized;

        // Append each column in order
        // Column 1: trace_file (VARCHAR)
        if (c.duckdb_append_varchar_length(appender, @ptrCast(trace_file.ptr), @intCast(trace_file.len)) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // Column 2: pid (INTEGER)
        if (c.duckdb_append_int32(appender, pid) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // Column 3: timestamp (VARCHAR)
        if (c.duckdb_append_varchar_length(appender, @ptrCast(syscall.timestamp.ptr), @intCast(syscall.timestamp.len)) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // Column 4: syscall (VARCHAR)
        if (c.duckdb_append_varchar_length(appender, @ptrCast(syscall.syscall.ptr), @intCast(syscall.syscall.len)) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // Column 5: args (TEXT)
        if (c.duckdb_append_varchar_length(appender, @ptrCast(syscall.args.ptr), @intCast(syscall.args.len)) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // Column 6: return_value (BIGINT, nullable)
        if (syscall.return_value) |val| {
            if (c.duckdb_append_int64(appender, val) == c.DuckDBError) {
                return error.AppendFailed;
            }
        } else {
            if (c.duckdb_append_null(appender) == c.DuckDBError) {
                return error.AppendFailed;
            }
        }

        // Column 7: error_code (VARCHAR, nullable)
        if (syscall.error_code) |code| {
            if (c.duckdb_append_varchar_length(appender, @ptrCast(code.ptr), @intCast(code.len)) == c.DuckDBError) {
                return error.AppendFailed;
            }
        } else {
            if (c.duckdb_append_null(appender) == c.DuckDBError) {
                return error.AppendFailed;
            }
        }

        // Column 8: error_message (VARCHAR, nullable)
        if (syscall.error_message) |msg| {
            if (c.duckdb_append_varchar_length(appender, @ptrCast(msg.ptr), @intCast(msg.len)) == c.DuckDBError) {
                return error.AppendFailed;
            }
        } else {
            if (c.duckdb_append_null(appender) == c.DuckDBError) {
                return error.AppendFailed;
            }
        }

        // Column 9: duration (DOUBLE, nullable)
        if (syscall.duration) |dur| {
            if (c.duckdb_append_double(appender, dur) == c.DuckDBError) {
                return error.AppendFailed;
            }
        } else {
            if (c.duckdb_append_null(appender) == c.DuckDBError) {
                return error.AppendFailed;
            }
        }

        // Column 10: unfinished (BOOLEAN)
        if (c.duckdb_append_bool(appender, syscall.unfinished) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // Column 11: resumed (BOOLEAN)
        if (c.duckdb_append_bool(appender, syscall.resumed) == c.DuckDBError) {
            return error.AppendFailed;
        }

        // End the row
        if (c.duckdb_appender_end_row(appender) == c.DuckDBError) {
            return error.AppendFailed;
        }
    }

    /// Flush the appender to commit all pending rows
    pub fn flushAppend(self: *Database) !void {
        const appender = self.appender orelse return error.AppenderNotInitialized;

        if (c.duckdb_appender_flush(appender) == c.DuckDBError) {
            return error.AppenderFlushFailed;
        }
    }

    /// End appending and destroy the appender
    /// This also flushes any remaining rows
    pub fn endAppend(self: *Database) !void {
        if (self.appender != null) {
            // Flush before destroying
            if (c.duckdb_appender_flush(self.appender.?) == c.DuckDBError) {
                return error.AppenderFlushFailed;
            }

            if (c.duckdb_appender_destroy(&self.appender.?) == c.DuckDBError) {
                return error.AppenderDestroyFailed;
            }

            self.appender = null;
        }
    }

    /// Get count of total syscalls in database
    pub fn getSyscallCount(self: *Database) !i64 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COUNT(*) FROM syscalls";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        // Get the count value from first row, first column
        const count = c.duckdb_value_int64(&result, 0, 0);
        return count;
    }

    /// Get count of unique syscalls
    pub fn getUniqueSyscallCount(self: *Database) !i64 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COUNT(DISTINCT syscall) FROM syscalls";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }

    /// Get count of unique PIDs
    pub fn getUniquePidCount(self: *Database) !i64 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COUNT(DISTINCT pid) FROM syscalls";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }

    /// Get count of failed syscalls (those with error codes)
    pub fn getFailedSyscallCount(self: *Database) !i64 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COUNT(*) FROM syscalls WHERE error_code IS NOT NULL";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "create in-memory database" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    // Verify it was created successfully by counting rows (should be 0)
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 0), count);
}

test "schema has syscalls table" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    // Verify table exists by querying it
    var result: c.duckdb_result = undefined;
    const query = "SELECT * FROM syscalls LIMIT 0";

    const state = c.duckdb_query(db.conn, query, &result);
    defer c.duckdb_destroy_result(&result);

    try std.testing.expect(state == c.DuckDBSuccess);
}

test "insert single syscall" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const syscall = Syscall.init(
        "10:23:45.123456",
        "open",
        "\"/tmp/file\", O_RDONLY",
        3,
        null,
        null,
        0.000042,
        false,
        false,
    );

    try db.beginAppend();
    try db.appendSyscall("test.trace", 1234, syscall);
    try db.endAppend();

    // Verify it was inserted
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "insert syscall with null fields" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const syscall = Syscall.init(
        "10:23:45.123456",
        "exit",
        "0",
        null, // null return value
        null,
        null,
        null, // null duration
        false,
        false,
    );

    try db.beginAppend();
    try db.appendSyscall("test.trace", 1234, syscall);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "insert syscall with error" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const syscall = Syscall.init(
        "10:23:45.123456",
        "open",
        "\"/tmp/file\", O_RDONLY",
        -1,
        "ENOENT",
        "No such file or directory",
        0.000042,
        false,
        false,
    );

    try db.beginAppend();
    try db.appendSyscall("test.trace", 1234, syscall);
    try db.endAppend();

    // Verify it was inserted and error is tracked
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 1), count);

    const failed_count = try db.getFailedSyscallCount();
    try std.testing.expectEqual(@as(i64, 1), failed_count);
}

test "insert multiple syscalls" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const syscall1 = Syscall.init(
        "10:23:45.123456",
        "open",
        "\"/tmp/file1\"",
        3,
        null,
        null,
        0.000042,
        false,
        false,
    );

    const syscall2 = Syscall.init(
        "10:23:45.123457",
        "read",
        "3, buffer, 100",
        100,
        null,
        null,
        0.000050,
        false,
        false,
    );

    const syscall3 = Syscall.init(
        "10:23:45.123458",
        "close",
        "3",
        0,
        null,
        null,
        0.000010,
        false,
        false,
    );

    try db.beginAppend();
    try db.appendSyscall("test.trace", 1234, syscall1);
    try db.appendSyscall("test.trace", 1234, syscall2);
    try db.appendSyscall("test.trace", 1234, syscall3);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 3), count);

    const unique_count = try db.getUniqueSyscallCount();
    try std.testing.expectEqual(@as(i64, 3), unique_count);
}

test "insert syscalls from different PIDs" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const syscall = Syscall.init(
        "10:23:45.123456",
        "getpid",
        "",
        1234,
        null,
        null,
        null,
        false,
        false,
    );

    try db.beginAppend();
    try db.appendSyscall("test.trace", 1234, syscall);
    try db.appendSyscall("test.trace", 5678, syscall);
    try db.appendSyscall("test.trace", 9012, syscall);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 3), count);

    const pid_count = try db.getUniquePidCount();
    try std.testing.expectEqual(@as(i64, 3), pid_count);
}

test "insert unfinished and resumed syscalls" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const unfinished = Syscall.init(
        "10:23:45.123456",
        "read",
        "3, ",
        null,
        null,
        null,
        null,
        true, // unfinished
        false,
    );

    const resumed = Syscall.init(
        "10:23:45.123457",
        "read",
        "buffer, 100",
        100,
        null,
        null,
        0.000050,
        false,
        true, // resumed
    );

    try db.beginAppend();
    try db.appendSyscall("test.trace", 1234, unfinished);
    try db.appendSyscall("test.trace", 1234, resumed);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "query statistics" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    // Insert some test data
    const open_success = Syscall.init("10:00:00.000001", "open", "\"file1\"", 3, null, null, 0.001, false, false);
    const open_fail = Syscall.init("10:00:00.000002", "open", "\"file2\"", -1, "ENOENT", "No such file", 0.001, false, false);
    const read_syscall = Syscall.init("10:00:00.000003", "read", "3, buf, 100", 100, null, null, 0.002, false, false);

    try db.beginAppend();
    try db.appendSyscall("trace1.txt", 1234, open_success);
    try db.appendSyscall("trace1.txt", 1234, open_fail);
    try db.appendSyscall("trace2.txt", 5678, read_syscall);
    try db.endAppend();

    // Test statistics
    try std.testing.expectEqual(@as(i64, 3), try db.getSyscallCount());
    try std.testing.expectEqual(@as(i64, 2), try db.getUniqueSyscallCount()); // open and read
    try std.testing.expectEqual(@as(i64, 2), try db.getUniquePidCount()); // 1234 and 5678
    try std.testing.expectEqual(@as(i64, 1), try db.getFailedSyscallCount()); // only the failed open
}

// ============================================================================
// APPENDER API TESTS
// ============================================================================

test "appender basic workflow" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    // Begin appending
    try db.beginAppend();

    // Append a syscall
    const syscall = Syscall.init(
        "10:23:45.123456",
        "open",
        "\"/tmp/file\", O_RDONLY",
        3,
        null,
        null,
        0.000042,
        false,
        false,
    );

    try db.appendSyscall("test.trace", 1234, syscall);

    // Flush and end
    try db.endAppend();

    // Verify it was inserted
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "appender multiple syscalls" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    try db.beginAppend();

    const syscalls = [_]Syscall{
        Syscall.init("10:00:00.000001", "open", "\"file1\"", 3, null, null, 0.001, false, false),
        Syscall.init("10:00:00.000002", "read", "3, buf, 100", 100, null, null, 0.002, false, false),
        Syscall.init("10:00:00.000003", "write", "1, \"data\", 4", 4, null, null, 0.001, false, false),
        Syscall.init("10:00:00.000004", "close", "3", 0, null, null, 0.0005, false, false),
    };

    for (syscalls) |syscall| {
        try db.appendSyscall("test.trace", 5678, syscall);
    }

    try db.endAppend();

    // Verify all were inserted
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 4), count);

    const unique_count = try db.getUniqueSyscallCount();
    try std.testing.expectEqual(@as(i64, 4), unique_count);
}

test "appender with null fields" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    try db.beginAppend();

    // Syscall with various null fields
    const syscall = Syscall.init(
        "10:23:45.123456",
        "exit",
        "0",
        null, // null return value
        null, // null error code
        null, // null error message
        null, // null duration
        false,
        false,
    );

    try db.appendSyscall("test.trace", 1234, syscall);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "appender with error codes" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    try db.beginAppend();

    const syscall1 = Syscall.init(
        "10:00:00.000001",
        "open",
        "\"/tmp/missing\"",
        -1,
        "ENOENT",
        "No such file or directory",
        0.000042,
        false,
        false,
    );

    const syscall2 = Syscall.init(
        "10:00:00.000002",
        "read",
        "999, buf, 100",
        -1,
        "EBADF",
        "Bad file descriptor",
        0.000030,
        false,
        false,
    );

    try db.appendSyscall("test.trace", 1234, syscall1);
    try db.appendSyscall("test.trace", 1234, syscall2);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), count);

    const failed_count = try db.getFailedSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), failed_count);
}

test "appender with unfinished and resumed syscalls" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    try db.beginAppend();

    const unfinished = Syscall.init(
        "10:23:45.123456",
        "read",
        "3, ",
        null,
        null,
        null,
        null,
        true, // unfinished
        false,
    );

    const resumed = Syscall.init(
        "10:23:45.123457",
        "read",
        "buffer, 100",
        100,
        null,
        null,
        0.000050,
        false,
        true, // resumed
    );

    try db.appendSyscall("test.trace", 1234, unfinished);
    try db.appendSyscall("test.trace", 1234, resumed);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "appender multiple batches with flush" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    try db.beginAppend();

    // First batch
    for (0..100) |i| {
        const syscall = Syscall.init(
            "10:00:00.000001",
            "getpid",
            "",
            @intCast(i),
            null,
            null,
            null,
            false,
            false,
        );
        try db.appendSyscall("test.trace", 1234, syscall);
    }

    // Flush intermediate
    try db.flushAppend();

    // Second batch
    for (0..100) |i| {
        const syscall = Syscall.init(
            "10:00:00.000002",
            "write",
            "1, \"test\", 4",
            4,
            null,
            null,
            null,
            false,
            false,
        );
        try db.appendSyscall("test.trace", @intCast(5000 + i), syscall);
    }

    try db.endAppend();

    // Verify all 200 were inserted
    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 200), count);

    const pid_count = try db.getUniquePidCount();
    try std.testing.expectEqual(@as(i64, 101), pid_count); // 1234 + 100 unique PIDs
}

test "appender error without beginAppend" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    const syscall = Syscall.init(
        "10:23:45.123456",
        "open",
        "\"file\"",
        3,
        null,
        null,
        0.001,
        false,
        false,
    );

    // Should fail because we didn't call beginAppend
    const result = db.appendSyscall("test.trace", 1234, syscall);
    try std.testing.expectError(error.AppenderNotInitialized, result);
}

test "appender multiple begin calls restart appender" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    // First session
    try db.beginAppend();
    const syscall1 = Syscall.init("10:00:00.000001", "open", "\"file1\"", 3, null, null, 0.001, false, false);
    try db.appendSyscall("test.trace", 1234, syscall1);
    try db.endAppend();

    // Second session - beginAppend should work again
    try db.beginAppend();
    const syscall2 = Syscall.init("10:00:00.000002", "close", "3", 0, null, null, 0.001, false, false);
    try db.appendSyscall("test.trace", 1234, syscall2);
    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "appender large batch performance test" {
    var db = try Database.init(":memory:");
    defer db.deinit();

    try db.beginAppend();

    // Insert 1000 syscalls to test batching
    for (0..1000) |i| {
        const syscall = Syscall.init(
            "10:23:45.123456",
            "write",
            "1, \"test data\", 9",
            9,
            null,
            null,
            0.000020,
            false,
            false,
        );
        try db.appendSyscall("test.trace", @intCast(i), syscall);
    }

    try db.endAppend();

    const count = try db.getSyscallCount();
    try std.testing.expectEqual(@as(i64, 1000), count);

    const pid_count = try db.getUniquePidCount();
    try std.testing.expectEqual(@as(i64, 1000), pid_count);
}
