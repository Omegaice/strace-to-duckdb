# strace-to-duckdb

A high-performance tool for parsing strace output files and loading them into a DuckDB database for analysis. Written in Zig for speed and efficiency.

## Features

- **High Performance**: Parallel file processing using all available CPU cores
- **Memory Efficient**: Dynamic buffer allocation based on actual line lengths
- **Fast Inserts**: Uses DuckDB's appender API for bulk loading
- **Robust Parsing**: Handles all strace output formats (regular, unfinished, resumed syscalls)
- **Progress Tracking**: Real-time progress bars with terminal width detection
- **Graceful Error Handling**: Continues processing even if individual files fail
- **Comprehensive Tests**: Extensive test coverage for all components

## Prerequisites

- [Zig](https://ziglang.org/) compiler (for building from source)
- [DuckDB](https://duckdb.org/) library (libduckdb)
- Linux, macOS, or other Unix-like system

## Installation

### Using Nix (Recommended)

```bash
nix develop
zig build
```

### Manual Build

Ensure DuckDB is installed on your system:

```bash
# Ubuntu/Debian
sudo apt-get install libduckdb-dev

# macOS
brew install duckdb

# Arch Linux
sudo pacman -S duckdb
```

Then build:

```bash
zig build
```

The binary will be in `zig-out/bin/strace-to-duckdb`.

## Usage

### Basic Usage

```bash
# Process single file (creates strace.db by default)
./zig-out/bin/strace-to-duckdb trace.12345

# Process multiple files
./zig-out/bin/strace-to-duckdb trace.* strace-*.log

# Specify output database
./zig-out/bin/strace-to-duckdb -o myanalysis.db trace.12345 trace.67890

# Use sequential processing (instead of parallel)
./zig-out/bin/strace-to-duckdb --sequential trace.*
```

### Command Line Options

```
Usage: strace-to-duckdb [OPTIONS] <trace_files...>

Options:
  -o, --output <file>  Output database file (default: strace.db)
  -s, --sequential     Use sequential processing (default: parallel)
  -h, --help           Show help message
```

## Generating Strace Output

To generate trace files compatible with this tool:

```bash
# Trace a single process with timestamps
strace -tt -T -o trace.log command args

# Trace with microsecond precision
strace -ttt -T -o trace.log command args

# Follow forks and create separate files per PID
strace -ff -tt -T -o trace command args
# This creates trace.1234, trace.5678, etc.
```

The tool automatically extracts PIDs from filenames in the format `*.PID`.

## Database Schema

The tool creates a `syscalls` table with the following structure:

| Column         | Type    | Description                                    |
|----------------|---------|------------------------------------------------|
| trace_file     | VARCHAR | Source filename                                |
| pid            | INTEGER | Process ID (extracted from filename)           |
| timestamp      | VARCHAR | Syscall timestamp (HH:MM:SS.microseconds)      |
| syscall        | VARCHAR | System call name                               |
| args           | TEXT    | System call arguments                          |
| return_value   | BIGINT  | Return value (NULL for incomplete calls)       |
| error_code     | VARCHAR | Error code (e.g., ENOENT) if syscall failed    |
| error_message  | VARCHAR | Human-readable error message                   |
| duration       | DOUBLE  | Syscall duration in seconds                    |
| unfinished     | BOOLEAN | Async syscall marked as <unfinished ...>       |
| resumed        | BOOLEAN | Async syscall marked as <... resumed>          |

### Indexes

The following indexes are automatically created for fast queries:

- `idx_syscall` on `syscall`
- `idx_pid` on `pid`
- `idx_error` on `error_code`
- `idx_trace_file` on `trace_file`

## Querying the Database

Once your data is loaded, use DuckDB to analyze it:

```bash
duckdb strace.db
```

### Example Queries

```sql
-- Top 10 most frequent syscalls
SELECT syscall, COUNT(*) as count
FROM syscalls
GROUP BY syscall
ORDER BY count DESC
LIMIT 10;

-- Failed syscalls by error code
SELECT error_code, error_message, COUNT(*) as count
FROM syscalls
WHERE error_code IS NOT NULL
GROUP BY error_code, error_message
ORDER BY count DESC;

-- Slowest syscalls
SELECT syscall, args, duration
FROM syscalls
WHERE duration IS NOT NULL
ORDER BY duration DESC
LIMIT 20;

-- Syscalls by PID
SELECT pid, COUNT(*) as syscall_count
FROM syscalls
GROUP BY pid
ORDER BY syscall_count DESC;

-- File operations that failed
SELECT syscall, args, error_code, error_message
FROM syscalls
WHERE syscall IN ('open', 'openat', 'stat', 'access', 'read', 'write')
  AND error_code IS NOT NULL;

-- Average duration by syscall type
SELECT syscall,
       COUNT(*) as count,
       AVG(duration) as avg_duration,
       MAX(duration) as max_duration
FROM syscalls
WHERE duration IS NOT NULL
GROUP BY syscall
ORDER BY avg_duration DESC
LIMIT 20;

-- Timeline of syscalls for a specific PID
SELECT timestamp, syscall, return_value, duration
FROM syscalls
WHERE pid = 12345
ORDER BY timestamp;

-- Find incomplete async operations
SELECT pid, timestamp, syscall, args
FROM syscalls
WHERE unfinished = true
ORDER BY pid, timestamp;
```

## Performance

### Parallel Processing

By default, the tool uses all available CPU cores to process multiple files simultaneously. Each worker:
- Creates its own connection to the shared database instance
- Processes files in a round-robin distribution
- Uses atomic counters for thread-safe progress tracking

For sequential processing (useful for debugging or low-memory systems):

```bash
./zig-out/bin/strace-to-duckdb --sequential trace.*
```

### Memory Usage

The tool uses a two-pass approach to minimize memory allocation:

1. **First pass**: Counts lines and finds the maximum line length (fails fast if any line exceeds 10MB)
2. **Second pass**: Allocates a buffer sized to the actual maximum line length and processes the file

This means memory usage scales with the longest line in each file, not a fixed worst-case buffer.

### Bulk Loading

The tool uses DuckDB's appender API instead of individual INSERT statements, providing significant performance improvements for large datasets.

## Development

### Running Tests

```bash
# Run all tests
zig build test

# Run tests for a specific module
zig test src/parser.zig
```

### Project Structure

```
src/
├── types.zig               # Data structures (Syscall)
├── parser.zig              # Strace output parsing
├── database.zig            # DuckDB interface with appender API
├── progress.zig            # Progress bars and status display
├── processor.zig           # Single-file processing logic
├── parallel_processor.zig  # Multi-threaded file processing
└── main.zig                # CLI entry point
```

### Architecture

- **Parser**: Supports three strace formats (regular, unfinished, resumed)
- **Database**: Thread-safe connections to shared DB instance
- **Processor**: Two-pass file reading with dynamic buffer allocation
- **Parallel Processor**: Worker pool with graceful error handling

## Limitations

- Maximum line length: 10MB (configurable in source)
- Strace output format: Requires `-tt` or `-ttt` flag for timestamps
- Strace output format: Requires `-T` flag for durations (optional but recommended)

## Troubleshooting

### "Line exceeds maximum allowed size"

This occurs when a strace line is longer than 10MB. This typically happens with syscalls that have extremely long arguments. You can:
- Filter your strace output to truncate long arguments
- Modify `MAX_LINE_SIZE` in `src/processor.zig` and rebuild

### "Database connect failed"

Ensure DuckDB is properly installed and the library is accessible. Check:
- `libduckdb.so` is in your library path (Linux)
- `libduckdb.dylib` is accessible (macOS)

### Tests failing

Make sure you have write permissions in the `zig-cache/` directory, as tests create temporary files there.

## Contributing

Contributions are welcome! Please ensure:
- All tests pass (`zig build test`)
- New features include tests
- Code follows existing style conventions

## License

[Add your license here]

## See Also

- [strace manual](https://man7.org/linux/man-pages/man1/strace.1.html)
- [DuckDB documentation](https://duckdb.org/docs/)
- [Zig language](https://ziglang.org/)
