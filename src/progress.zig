const std = @import("std");

/// Aggregate progress bar for parallel processing
pub const AggregateProgress = struct {
    total_files: usize,
    start_time: i64,
    enabled: bool,

    pub fn init(total_files: usize) AggregateProgress {
        const stdout = std.fs.File.stdout();
        const enabled = stdout.isTty();

        return AggregateProgress{
            .total_files = total_files,
            .start_time = std.time.milliTimestamp(),
            .enabled = enabled,
        };
    }

    /// Render aggregate progress from atomic counters
    pub fn render(
        self: *AggregateProgress,
        files_complete: usize,
        lines_processed: usize,
    ) !void {
        if (!self.enabled) return;

        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const rate = if (elapsed_sec > 0)
            @as(f64, @floatFromInt(lines_processed)) / elapsed_sec
        else
            0.0;

        const percent = if (self.total_files > 0)
            (files_complete * 100) / self.total_files
        else
            0;

        // Format: [8/10] 80% | 125483 lines | 112500 lines/s
        var buffer: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buffer,
            "\r[{d}/{d}] {d}% | {d} lines | {d:.0} lines/s    ",
            .{ files_complete, self.total_files, percent, lines_processed, rate },
        );
        try std.fs.File.stdout().writeAll(msg);
    }

    /// Finish and print newline
    pub fn finish(self: *AggregateProgress) !void {
        if (!self.enabled) return;
        try std.fs.File.stdout().writeAll("\n");
    }

    /// Clean up (best-effort, for use with defer)
    pub fn deinit(self: *AggregateProgress) void {
        self.finish() catch {};
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "aggregate progress init" {
    const progress = AggregateProgress.init(10);
    try std.testing.expectEqual(@as(usize, 10), progress.total_files);
}

test "aggregate progress render disabled" {
    var progress = AggregateProgress.init(10);
    progress.enabled = false; // Disable for testing

    // Should not error when disabled
    try progress.render(5, 1000);
    try progress.finish();
}

test "aggregate progress deinit is safe" {
    var progress = AggregateProgress.init(10);
    progress.enabled = false;
    defer progress.deinit(); // Should work with defer

    try progress.render(5, 1000);
}
