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
        };

        // Create schema
        try database.createSchema();

        return database;
    }

    /// Close database and clean up resources
    pub fn deinit(self: *Database) void {
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

    /// Insert a parsed syscall into the database
    pub fn insertSyscall(
        self: *Database,
        trace_file: []const u8,
        pid: i32,
        syscall: Syscall,
    ) !void {
        // Use prepared statement for safe parameter binding
        var stmt: c.duckdb_prepared_statement = undefined;

        const query =
            \\INSERT INTO syscalls (
            \\    trace_file, pid, timestamp, syscall, args,
            \\    return_value, error_code, error_message, duration,
            \\    unfinished, resumed
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return error.PrepareStatementFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        // Bind parameters (1-indexed in DuckDB)
        // VARCHAR parameters (use length-based binding for non-null-terminated slices)
        _ = c.duckdb_bind_varchar_length(stmt, 1, @ptrCast(trace_file.ptr), @intCast(trace_file.len));
        _ = c.duckdb_bind_int32(stmt, 2, pid);
        _ = c.duckdb_bind_varchar_length(stmt, 3, @ptrCast(syscall.timestamp.ptr), @intCast(syscall.timestamp.len));
        _ = c.duckdb_bind_varchar_length(stmt, 4, @ptrCast(syscall.syscall.ptr), @intCast(syscall.syscall.len));
        _ = c.duckdb_bind_varchar_length(stmt, 5, @ptrCast(syscall.args.ptr), @intCast(syscall.args.len));

        // Return value (nullable)
        if (syscall.return_value) |val| {
            _ = c.duckdb_bind_int64(stmt, 6, val);
        } else {
            _ = c.duckdb_bind_null(stmt, 6);
        }

        // Error code (nullable)
        if (syscall.error_code) |code| {
            _ = c.duckdb_bind_varchar_length(stmt, 7, @ptrCast(code.ptr), @intCast(code.len));
        } else {
            _ = c.duckdb_bind_null(stmt, 7);
        }

        // Error message (nullable)
        if (syscall.error_message) |msg| {
            _ = c.duckdb_bind_varchar_length(stmt, 8, @ptrCast(msg.ptr), @intCast(msg.len));
        } else {
            _ = c.duckdb_bind_null(stmt, 8);
        }

        // Duration (nullable)
        if (syscall.duration) |dur| {
            _ = c.duckdb_bind_double(stmt, 9, dur);
        } else {
            _ = c.duckdb_bind_null(stmt, 9);
        }

        // Boolean flags
        _ = c.duckdb_bind_boolean(stmt, 10, syscall.unfinished);
        _ = c.duckdb_bind_boolean(stmt, 11, syscall.resumed);

        // Execute statement
        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            defer c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
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

    try db.insertSyscall("test.trace", 1234, syscall);

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

    try db.insertSyscall("test.trace", 1234, syscall);

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

    try db.insertSyscall("test.trace", 1234, syscall);

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

    try db.insertSyscall("test.trace", 1234, syscall1);
    try db.insertSyscall("test.trace", 1234, syscall2);
    try db.insertSyscall("test.trace", 1234, syscall3);

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

    try db.insertSyscall("test.trace", 1234, syscall);
    try db.insertSyscall("test.trace", 5678, syscall);
    try db.insertSyscall("test.trace", 9012, syscall);

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

    try db.insertSyscall("test.trace", 1234, unfinished);
    try db.insertSyscall("test.trace", 1234, resumed);

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

    try db.insertSyscall("trace1.txt", 1234, open_success);
    try db.insertSyscall("trace1.txt", 1234, open_fail);
    try db.insertSyscall("trace2.txt", 5678, read_syscall);

    // Test statistics
    try std.testing.expectEqual(@as(i64, 3), try db.getSyscallCount());
    try std.testing.expectEqual(@as(i64, 2), try db.getUniqueSyscallCount()); // open and read
    try std.testing.expectEqual(@as(i64, 2), try db.getUniquePidCount()); // 1234 and 5678
    try std.testing.expectEqual(@as(i64, 1), try db.getFailedSyscallCount()); // only the failed open
}
