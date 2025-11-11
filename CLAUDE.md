# CLAUDE.md - AI Assistant Reference

## Critical Architecture Patterns

### Database Concurrency Model (DO NOT CHANGE)

**Pattern**: Shared database instance, multiple connections

```zig
// Main thread - owns the database instance
var db_main = try Database.init(db_path);
defer db_main.deinit();

// Worker threads - connect to same instance (do NOT own it)
const db_instance = db_main.getDbInstance();
var worker_db = try Database.connectToInstance(db_instance);
defer worker_db.deinit(); // Safe: only closes connection, not DB
```

**Critical details**:
- Main thread: `Database.init()` → `owns_db = true` → `deinit()` closes database
- Worker threads: `Database.connectToInstance()` → `owns_db = false` → `deinit()` only closes connection
- **DO NOT** call `Database.init()` or `Database.openExisting()` in worker threads
- **DO NOT** try to "optimize" by having each worker create its own database file

**Why this matters**: DuckDB supports multiple connections to the same database instance for concurrent writes. Creating separate database files or using the wrong initialization pattern will break parallel processing.

### Appender API Requirement

**Pattern**: Always use appender API, never raw SQL inserts

```zig
try db.beginAppend();
for (syscalls) |syscall| {
    try db.appendSyscall(trace_file, pid, syscall);
}
try db.endAppend();
```

**DO NOT** replace with:
```zig
// ❌ SLOW - Don't do this
const sql = "INSERT INTO syscalls VALUES (...)";
try db.execute(sql);
```

**Why**: Appender API is 10-100x faster for bulk inserts. This is a performance-critical path.

### Two-Pass File Processing (Intentional)

**Pattern**: processor.zig reads each file twice

1. **First pass**: Count lines, find max line length (`countLinesAndMaxLength`)
2. **Second pass**: Allocate buffer to actual max size, process file

**This looks redundant but IS NOT**. Do not "optimize" to single-pass.

**Why**: Memory efficiency. Without first pass, we'd need:
- Fixed 10MB buffer per file (wasteful for small files)
- OR dynamic reallocation (complex, error-prone)
- First pass lets us allocate exactly what we need

**Bonus**: First pass fails fast if any line exceeds 10MB limit (before wasting time on large file).

## Build and Test

### Running Tests

```bash
# Run all tests (recommended)
zig build test

# Tests create temporary files in:
zig-cache/test-*
```

**Note**: Tests need write access to `zig-cache/` directory. If tests fail with file access errors, check permissions.

### Running the Application

```bash
# Pass arguments through build system
zig build run -- -o output.db trace.12345 trace.67890

# Or run binary directly
./zig-out/bin/strace-to-duckdb -o output.db trace.*
```

## File Naming Convention

**Pattern**: PID extracted from filename using `*.PID` convention

```
trace.12345     → pid = 12345
strace.5678     → pid = 5678
foo.bar.99      → pid = 99
nopid.txt       → pid = 0 (default)
```

Extraction logic: `extractPid()` takes everything after the last `.` and parses as integer.

**Why this matters**: If adding features that involve PIDs, understand they come from filenames, not file contents.

## Code Modification Guidelines

### When Adding New Syscall Fields

If adding fields to `Syscall` struct:

1. Update `types.zig` → `Syscall` struct
2. Update `database.zig` → Schema creation + appender calls
3. Update `parser.zig` → All three parsing functions (regular, unfinished, resumed)
4. Add tests for the new field

**Critical**: The appender API requires fields in exact schema order. If you get the order wrong, inserts will silently corrupt data.

### When Modifying Parallel Processing

The atomic counter pattern in `parallel_processor.zig` is thread-safe. If modifying:

- Use `std.atomic.Value(T)` for shared state
- Use `.seq_cst` memory ordering for updates
- Update progress loop to read new counters

**DO NOT**:
- Use regular variables shared between threads
- Try to "simplify" by removing atomics
- Assume `usize` increment is atomic (it's not guaranteed in Zig)

## Discovery Commands

```bash
# Find all test functions
grep -r "^test " src/

# Check what DuckDB symbols are used
grep -r "duckdb_" src/

# See progress bar rendering logic
grep -A10 "fn render" src/progress.zig
```

## Common Patterns

### Progress Bar Usage

```zig
var pbar = ProgressBar.init("Label", total_items);
defer pbar.deinit(); // Auto-finishes on scope exit

// In loop
try pbar.increment();

// Or update directly
try pbar.update(current_count);
```

**Note**: `deinit()` is safe to call in `defer` (returns void, ignores errors). This is intentional for cleanup paths.

### Error Handling in Workers

Worker threads catch errors and store in error slot:

```zig
const stats = processor.processFile(...) catch |err| {
    _ = self.files_with_errors.fetchAdd(1, .seq_cst);
    self.error_slot.* = err;
    continue; // Keep processing other files
};
```

**Pattern**: File-level errors don't stop processing. Workers continue with remaining files.
