const std = @import("std");

// Import DuckDB C API
const c = @cImport({
    @cInclude("duckdb.h");
});

pub fn main() !void {
    try std.fs.File.stdout().writeAll("Creating DuckDB database...\n");

    // Create database and connection
    var db: c.duckdb_database = undefined;
    var con: c.duckdb_connection = undefined;

    // Open database (NULL for in-memory)
    if (c.duckdb_open(null, &db) == c.DuckDBError) {
        try std.fs.File.stdout().writeAll("Error: Failed to open database\n");
        return error.DatabaseOpenFailed;
    }
    defer c.duckdb_close(&db);

    // Connect to database
    if (c.duckdb_connect(db, &con) == c.DuckDBError) {
        try std.fs.File.stdout().writeAll("Error: Failed to connect to database\n");
        return error.DatabaseConnectFailed;
    }
    defer c.duckdb_disconnect(&con);

    try std.fs.File.stdout().writeAll("Database connected successfully!\n\n");

    // Create a table
    try std.fs.File.stdout().writeAll("Creating table...\n");
    var result: c.duckdb_result = undefined;
    var state = c.duckdb_query(con, "CREATE TABLE test (id INTEGER, name VARCHAR)", null);
    if (state == c.DuckDBError) {
        try std.fs.File.stdout().writeAll("Error: Failed to create table\n");
        return error.QueryFailed;
    }

    // Insert data
    try std.fs.File.stdout().writeAll("Inserting data...\n");
    state = c.duckdb_query(con, "INSERT INTO test VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Charlie')", null);
    if (state == c.DuckDBError) {
        try std.fs.File.stdout().writeAll("Error: Failed to insert data\n");
        return error.QueryFailed;
    }

    // Query data
    try std.fs.File.stdout().writeAll("Querying data...\n\n");
    state = c.duckdb_query(con, "SELECT * FROM test", &result);
    if (state == c.DuckDBError) {
        try std.fs.File.stdout().writeAll("Error: Failed to query data\n");
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_result(&result);

    // Print results
    const row_count = c.duckdb_row_count(&result);
    const col_count = c.duckdb_column_count(&result);

    std.debug.print("Results ({} rows, {} columns):\n", .{ row_count, col_count });

    // Print column names
    var col: usize = 0;
    while (col < col_count) : (col += 1) {
        const col_name = c.duckdb_column_name(&result, @intCast(col));
        if (col > 0) std.debug.print(" | ", .{});
        std.debug.print("{s}", .{col_name});
    }
    std.debug.print("\n", .{});

    // Print separator
    col = 0;
    while (col < col_count) : (col += 1) {
        if (col > 0) std.debug.print("-+-", .{});
        std.debug.print("----------", .{});
    }
    std.debug.print("\n", .{});

    // Print rows
    var row: usize = 0;
    while (row < row_count) : (row += 1) {
        col = 0;
        while (col < col_count) : (col += 1) {
            if (col > 0) std.debug.print(" | ", .{});

            const val = c.duckdb_value_varchar(&result, @intCast(col), @intCast(row));
            defer c.duckdb_free(val);

            if (val != null) {
                std.debug.print("{s: <10}", .{val});
            } else {
                std.debug.print("NULL      ", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    try std.fs.File.stdout().writeAll("\nSuccess!\n");
}
