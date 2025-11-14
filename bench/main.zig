const std = @import("std");
const zbench = @import("zbench");
const parser = @import("parser");

// ============================================================================
// PARSER BENCHMARKS - Understanding the 3-way dispatch cost
// ============================================================================

// Real-world samples from large-trace dataset
const REGULAR_SIMPLE = "22:21:11.675122 set_robust_list(0x7fa8e531c4a0, 24) = 0 <0.000009>";
const REGULAR_WITH_ERROR = "22:21:11.675759 access(\"/etc/ld-nix.so.preload\", R_OK) = -1 ENOENT (No such file or directory) <0.000006>";
const REGULAR_LONG = "22:21:11.675282 read(3, \"[General]\\n%2B8gcPZIuASRcihpYJW6UA83rPnH%2B7ifu11s9xp3p8Rc%23=1762831253\\n63tJmSFEpYg9dR34FZPBHK8VKGPcUT1yDVJWSS9UTuU%23=1762831253\\nGeoLocale=system\", 4096) = 4037 <0.000011>";
const REGULAR_NESTED_PARENS = "22:21:11.675258 fstat(3, {st_mode=S_IFREG|0644, st_size=4037, ...}) = 0 <0.000005>";
const UNFINISHED = "22:21:24.927885 poll([{fd=8, events=POLLIN}], 2, -1 <unfinished ...>) = ?";
const RESUMED = "22:21:24.928000 <... poll resumed>) = 1 ([{fd=8, revents=POLLIN}]) <0.000115>";
const INVALID = "this is not a valid strace line";
const EMPTY = "";

// Benchmark: Regular syscall (fast path)
fn benchmarkParseRegular(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, REGULAR_SIMPLE) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Regular with error (more parsing)
fn benchmarkParseRegularError(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, REGULAR_WITH_ERROR) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Regular with long args (tests string operations at scale)
fn benchmarkParseRegularLong(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, REGULAR_LONG) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Nested parentheses (tests findClosingParen)
fn benchmarkParseNestedParens(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, REGULAR_NESTED_PARENS) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Unfinished pattern (tries regular first, then unfinished)
fn benchmarkParseUnfinished(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, UNFINISHED) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Resumed pattern (tries regular, unfinished, then resumed)
fn benchmarkParseResumed(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, RESUMED) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Invalid line (tries all 3 parsers, all fail)
fn benchmarkParseInvalid(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, INVALID) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Empty line (fast rejection)
fn benchmarkParseEmpty(allocator: std.mem.Allocator) void {
    const result = parser.parseLine(allocator, EMPTY) catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// Benchmark: Realistic mix based on database stats:
// - 1,270,193 total syscalls
// - 110 unfinished (0.009%)
// - 0 resumed in DB (but they exist in traces)
// - 152,612 errors (12%)
// - Rest are successful regular calls
fn benchmarkParseMixedRealistic(allocator: std.mem.Allocator) void {
    // 100 calls: 88 regular success, 12 regular with errors, 0-1 unfinished/resumed
    const lines = [_][]const u8{
        REGULAR_SIMPLE, REGULAR_SIMPLE, REGULAR_SIMPLE,     REGULAR_SIMPLE,
        REGULAR_SIMPLE, REGULAR_SIMPLE, REGULAR_SIMPLE,     REGULAR_SIMPLE,
        REGULAR_LONG,   REGULAR_LONG,   REGULAR_WITH_ERROR, REGULAR_WITH_ERROR,
    };

    for (lines) |line| {
        const result = parser.parseLine(allocator, line) catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }
}

// ============================================================================
// PARSER DISPATCH COST - How expensive is the 3-way try?
// ============================================================================

// This measures the cost of the dispatch itself
// Regular patterns match immediately (1 attempt)
// Unfinished patterns need 2 attempts
// Resumed patterns need 3 attempts
// Invalid needs 3 attempts + all fail

fn benchmarkDispatchCostRegular(_: std.mem.Allocator) void {
    // Measures: 1 pattern attempt (immediate match)
    const has_unfinished = std.mem.indexOf(u8, REGULAR_SIMPLE, "<unfinished ...>") != null;
    std.mem.doNotOptimizeAway(has_unfinished);
}

fn benchmarkDispatchCostUnfinished(_: std.mem.Allocator) void {
    // Measures: 2 pattern attempts (regular fails, unfinished matches)
    const has_unfinished1 = std.mem.indexOf(u8, UNFINISHED, "<unfinished ...>") != null;
    const has_unfinished2 = std.mem.indexOf(u8, UNFINISHED, "<unfinished ...>") != null;
    std.mem.doNotOptimizeAway(has_unfinished1);
    std.mem.doNotOptimizeAway(has_unfinished2);
}

fn benchmarkDispatchCostResumed(_: std.mem.Allocator) void {
    // Measures: 3 pattern attempts (regular fails, unfinished fails, resumed matches)
    const has_unfinished = std.mem.indexOf(u8, RESUMED, "<unfinished ...>") != null;
    const has_resumed_start = std.mem.indexOf(u8, RESUMED, "<... ") != null;
    const has_resumed_end = std.mem.indexOf(u8, RESUMED, " resumed>") != null;
    std.mem.doNotOptimizeAway(has_unfinished);
    std.mem.doNotOptimizeAway(has_resumed_start);
    std.mem.doNotOptimizeAway(has_resumed_end);
}

// ============================================================================
// FINDCLOSINGPAREN - Critical inner loop
// ============================================================================

const NESTED_ARGS = "{st_mode=S_IFREG|0644, st_rdev=makedev(0x88, 0), st_size=4037, ...}";
const DEEPLY_NESTED = "[{WIFEXITED(s) && WEXITSTATUS(s) == 0}], 0, NULL";

fn benchmarkFindClosingParenSimple(_: std.mem.Allocator) void {
    // Simulate what findClosingParen does - already past opening '('
    var depth: i32 = 1;
    var i: usize = 0;
    while (i < NESTED_ARGS.len) : (i += 1) {
        const c = NESTED_ARGS[i];
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    std.mem.doNotOptimizeAway(i);
}

fn benchmarkFindClosingParenDeep(_: std.mem.Allocator) void {
    var depth: i32 = 1;
    var i: usize = 0;
    while (i < DEEPLY_NESTED.len) : (i += 1) {
        const c = DEEPLY_NESTED[i];
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    std.mem.doNotOptimizeAway(i);
}

// ============================================================================
// FILE I/O BENCHMARKS - Read and parse only (no DB)
// ============================================================================

const TEST_FILE_1000 = "/tmp/claude/bench-sample-1000.txt";
const TEST_FILE_10000 = "/tmp/claude/bench-sample-10000.txt";

// Benchmark: Read and parse lines (NO database writes)
fn benchmarkReadAndParse1000(allocator: std.mem.Allocator) void {
    const file = std.fs.cwd().openFile(TEST_FILE_1000, .{}) catch unreachable;
    defer file.close();

    var buffer: [16384]u8 = undefined;
    var reader = file.reader(&buffer);

    var count: usize = 0;
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        const result = parser.parseLine(allocator, line) catch unreachable;
        std.mem.doNotOptimizeAway(result);
        count += 1;
    }
    std.mem.doNotOptimizeAway(count);
}

fn benchmarkReadAndParse10000(allocator: std.mem.Allocator) void {
    const file = std.fs.cwd().openFile(TEST_FILE_10000, .{}) catch unreachable;
    defer file.close();

    var buffer: [16384]u8 = undefined;
    var reader = file.reader(&buffer);

    var count: usize = 0;
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        const result = parser.parseLine(allocator, line) catch unreachable;
        std.mem.doNotOptimizeAway(result);
        count += 1;
    }
    std.mem.doNotOptimizeAway(count);
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var stdout = std.fs.File.stdout().writerStreaming(&.{});
    const writer = &stdout.interface;

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    // Parser benchmarks - different patterns
    try bench.add("Parse: Regular (simple)", benchmarkParseRegular, .{});
    try bench.add("Parse: Regular (error)", benchmarkParseRegularError, .{});
    try bench.add("Parse: Regular (long)", benchmarkParseRegularLong, .{});
    try bench.add("Parse: Nested parens", benchmarkParseNestedParens, .{});
    try bench.add("Parse: Unfinished", benchmarkParseUnfinished, .{});
    try bench.add("Parse: Resumed", benchmarkParseResumed, .{});
    try bench.add("Parse: Invalid", benchmarkParseInvalid, .{});
    try bench.add("Parse: Empty", benchmarkParseEmpty, .{});
    try bench.add("Parse: Mixed realistic", benchmarkParseMixedRealistic, .{});

    // Dispatch cost analysis
    try bench.add("Dispatch: Regular (1 try)", benchmarkDispatchCostRegular, .{});
    try bench.add("Dispatch: Unfinished (2 tries)", benchmarkDispatchCostUnfinished, .{});
    try bench.add("Dispatch: Resumed (3 tries)", benchmarkDispatchCostResumed, .{});

    // Inner loop analysis
    try bench.add("Inner: findClosingParen simple", benchmarkFindClosingParenSimple, .{});
    try bench.add("Inner: findClosingParen deep", benchmarkFindClosingParenDeep, .{});

    // File I/O benchmarks
    try bench.add("FileIO: Read+Parse 1K", benchmarkReadAndParse1000, .{});
    try bench.add("FileIO: Read+Parse 10K", benchmarkReadAndParse10000, .{});

    try writer.writeAll("\n");
    try zbench.prettyPrintHeader(writer);

    const tty_config = std.io.tty.detectConfig(std.fs.File.stdout());
    const progress = std.Progress.start(.{});
    defer progress.end();

    const suite_node = progress.start("Benchmarks", 16);
    defer suite_node.end();

    var iter = try bench.iterator();
    var current_benchmark: []const u8 = "";
    var benchmark_node: ?std.Progress.Node = null;
    var completed_benchmarks: usize = 0;

    while (try iter.next()) |step| switch (step) {
        .progress => |p| {
            if (p.total_runs > 0) {
                if (!std.mem.eql(u8, current_benchmark, p.current_name)) {
                    if (benchmark_node) |*node| {
                        node.end();
                    }
                    current_benchmark = p.current_name;
                    benchmark_node = suite_node.start(p.current_name, p.total_runs);
                }
                if (benchmark_node) |*node| {
                    node.setCompletedItems(p.completed_runs);
                }
            }
        },
        .result => |r| {
            defer r.deinit();

            if (benchmark_node) |*node| {
                node.end();
                benchmark_node = null;
            }

            completed_benchmarks += 1;
            suite_node.setCompletedItems(completed_benchmarks);
            try r.prettyPrint(allocator, writer, tty_config);
        },
    };

    if (benchmark_node) |*node| {
        node.end();
    }
}
