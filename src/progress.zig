const std = @import("std");
const builtin = @import("builtin");

/// Get terminal width, returns null if not available
fn getTerminalWidth() ?usize {
    if (!builtin.os.tag.isDarwin() and builtin.os.tag != .linux) {
        return null; // Only support Unix-like systems
    }

    const stdout = std.fs.File.stdout();
    if (!stdout.isTty()) return null;

    // Use TIOCGWINSZ ioctl to get terminal size
    const c = struct {
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
        const TIOCGWINSZ: c_ulong = if (builtin.os.tag.isDarwin()) 0x40087468 else 0x5413;
        const winsize = extern struct {
            ws_row: c_ushort,
            ws_col: c_ushort,
            ws_xpixel: c_ushort,
            ws_ypixel: c_ushort,
        };
    };

    var ws: c.winsize = undefined;
    const result = c.ioctl(stdout.handle, c.TIOCGWINSZ, &ws);
    if (result == -1 or ws.ws_col == 0) {
        return null;
    }

    return @as(usize, ws.ws_col);
}

/// Progress bar for terminal visualization
pub const ProgressBar = struct {
    total: usize,
    current: usize,
    label: []const u8,
    enabled: bool,
    start_time: i64,
    bar_width: usize = 20,

    /// Initialize a progress bar
    pub fn init(label: []const u8, total: usize) ProgressBar {
        const stdout = std.fs.File.stdout();
        const enabled = stdout.isTty();

        return ProgressBar{
            .total = total,
            .current = 0,
            .label = label,
            .enabled = enabled,
            .start_time = std.time.milliTimestamp(),
            .bar_width = 30,
        };
    }

    /// Update progress to a specific value
    pub fn update(self: *ProgressBar, current: usize) !void {
        self.current = current;
        if (!self.enabled) return;

        try self.render();
    }

    /// Increment progress by 1
    pub fn increment(self: *ProgressBar) !void {
        self.current += 1;
        if (!self.enabled) return;

        // Only render every 100 updates to avoid performance issues
        if (self.current % 100 == 0 or self.current == self.total) {
            try self.render();
        }
    }

    /// Render the progress bar
    fn render(self: *ProgressBar) !void {
        // Calculate percentage
        const percent = if (self.total > 0)
            @min((self.current * 100) / self.total, 100)
        else
            0;

        // Calculate filled portion of bar
        const filled = if (self.total > 0)
            @min((self.current * self.bar_width) / self.total, self.bar_width)
        else
            0;

        const empty = self.bar_width - filled;

        // Calculate elapsed time and rate
        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const rate = if (elapsed_sec > 0)
            @as(f64, @floatFromInt(self.current)) / elapsed_sec
        else
            0.0;

        // Dynamically calculate max label width based on terminal width
        const term_width = getTerminalWidth() orelse 80; // Default to 80 if unknown
        // Fixed content: "\r", ": [", "]", " 100% (99999/99999) | 99999 lines/s" ≈ 45 chars
        // Bar width: self.bar_width (20) * 3 bytes per char (UTF-8) = 60 chars
        const fixed_content_width = 45 + (self.bar_width * 3);
        const available_for_label = if (term_width > fixed_content_width)
            term_width - fixed_content_width
        else
            10; // Minimum label width

        // Truncate label if needed
        const display_label = if (self.label.len > available_for_label)
            self.label[0..available_for_label]
        else
            self.label;

        // Build progress bar string
        var bar_buffer: [512]u8 = undefined;
        var bar_len: usize = 0;

        // Add carriage return and label
        bar_buffer[bar_len] = '\r';
        bar_len += 1;

        @memcpy(bar_buffer[bar_len .. bar_len + display_label.len], display_label);
        bar_len += display_label.len;

        bar_buffer[bar_len] = ':';
        bar_len += 1;
        bar_buffer[bar_len] = ' ';
        bar_len += 1;
        bar_buffer[bar_len] = '[';
        bar_len += 1;

        // Add filled portion
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            const block = "█";
            @memcpy(bar_buffer[bar_len .. bar_len + block.len], block);
            bar_len += block.len;
        }

        // Add empty portion
        i = 0;
        while (i < empty) : (i += 1) {
            const block = "░";
            @memcpy(bar_buffer[bar_len .. bar_len + block.len], block);
            bar_len += block.len;
        }

        // Add stats
        const stats_str = try std.fmt.bufPrint(
            bar_buffer[bar_len..],
            "] {d}% ({d}/{d}) | {d:.0} lines/s",
            .{ percent, self.current, self.total, rate },
        );
        bar_len += stats_str.len;

        // Write to stdout
        try std.fs.File.stdout().writeAll(bar_buffer[0..bar_len]);
    }

    /// Finish the progress bar and print a newline
    pub fn finish(self: *ProgressBar) !void {
        if (!self.enabled) return;

        // Update to total if needed and render
        if (self.current != self.total) {
            self.current = self.total;
            try self.render();
        }

        // Print newline to move to next line
        try std.fs.File.stdout().writeAll("\n");
    }

    /// Clean up progress bar (best-effort, for use with defer)
    /// This is the idiomatic Zig cleanup method that doesn't return errors
    pub fn deinit(self: *ProgressBar) void {
        self.finish() catch {}; // Best-effort finish, ignore errors
    }

    /// Clear the current progress bar line
    pub fn clear(self: *ProgressBar) !void {
        if (!self.enabled) return;

        // Move to start of line and clear it
        var clear_buffer: [128]u8 = undefined;
        var clear_len: usize = 0;

        clear_buffer[clear_len] = '\r';
        clear_len += 1;

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            clear_buffer[clear_len] = ' ';
            clear_len += 1;
        }

        clear_buffer[clear_len] = '\r';
        clear_len += 1;

        try std.fs.File.stdout().writeAll(clear_buffer[0..clear_len]);
    }
};

/// Simple status printer for non-TTY output
pub const StatusPrinter = struct {
    label: []const u8,
    total: usize,
    current: usize,
    last_print: usize,
    print_interval: usize,

    pub fn init(label: []const u8, total: usize) StatusPrinter {
        return StatusPrinter{
            .label = label,
            .total = total,
            .current = 0,
            .last_print = 0,
            .print_interval = 1000, // Print every 1000 lines
        };
    }

    pub fn update(self: *StatusPrinter, current: usize) !void {
        self.current = current;

        // Print at intervals
        if (current - self.last_print >= self.print_interval or current == self.total) {
            std.debug.print("{s}: {d}/{d} lines\n", .{
                self.label,
                current,
                self.total,
            });
            self.last_print = current;
        }
    }

    pub fn increment(self: *StatusPrinter) !void {
        self.current += 1;
        try self.update(self.current);
    }

    pub fn finish(self: *StatusPrinter) !void {
        try self.update(self.total);
    }

    pub fn clear(self: *StatusPrinter) !void {
        _ = self;
        // Nothing to clear for status printer
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "progress bar init" {
    const bar = ProgressBar.init("Test", 100);
    try std.testing.expectEqual(@as(usize, 100), bar.total);
    try std.testing.expectEqual(@as(usize, 0), bar.current);
    try std.testing.expectEqualStrings("Test", bar.label);
}

test "progress bar update" {
    var bar = ProgressBar.init("Test", 100);
    bar.enabled = false; // Disable for testing

    try bar.update(50);
    try std.testing.expectEqual(@as(usize, 50), bar.current);

    try bar.update(100);
    try std.testing.expectEqual(@as(usize, 100), bar.current);
}

test "progress bar increment" {
    var bar = ProgressBar.init("Test", 100);
    bar.enabled = false; // Disable for testing

    try bar.increment();
    try std.testing.expectEqual(@as(usize, 1), bar.current);

    try bar.increment();
    try std.testing.expectEqual(@as(usize, 2), bar.current);
}

test "status printer init" {
    const printer = StatusPrinter.init("Test", 100);
    try std.testing.expectEqual(@as(usize, 100), printer.total);
    try std.testing.expectEqual(@as(usize, 0), printer.current);
}

test "status printer update" {
    var printer = StatusPrinter.init("Test", 100);

    try printer.update(50);
    try std.testing.expectEqual(@as(usize, 50), printer.current);
}

test "progress bar deinit can be deferred" {
    var bar = ProgressBar.init("Test", 100);
    bar.enabled = false; // Disable for testing
    defer bar.deinit(); // Should work in defer

    try bar.update(50);
    // deinit() will be called automatically when scope exits
}

test "progress bar deinit is safe to call multiple times" {
    var bar = ProgressBar.init("Test", 100);
    bar.enabled = false; // Disable for testing

    bar.deinit();
    bar.deinit(); // Should be safe to call twice
}
