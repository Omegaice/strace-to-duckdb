use crate::database::Database;
use crate::parser;
use anyhow::{Context, Result};
use duckdb::{Appender, params};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct ProcessStats {
    pub total_lines: usize,
    pub parsed_lines: usize,
    pub failed_lines: usize,
    pub time_reading: Duration,
    pub time_parsing: Duration,
    pub time_db_insert: Duration,
}

/// Extract PID from filename like "trace.12345" -> Some(12345)
pub fn extract_pid(filename: &str) -> Option<i32> {
    filename.rsplit('.').next()?.parse::<i32>().ok()
}

/// Process a single trace file and insert into database using batch appender
pub fn process_file(db: &Database, file_path: &Path) -> Result<ProcessStats> {
    use std::time::Instant;

    let start_total = Instant::now();

    // Time file I/O
    let start_io = Instant::now();
    let file =
        File::open(file_path).context(format!("Failed to open file: {}", file_path.display()))?;
    let reader = BufReader::new(file);

    let filename = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown");

    let pid = extract_pid(filename).unwrap_or(0);

    let mut stats = ProcessStats {
        total_lines: 0,
        parsed_lines: 0,
        failed_lines: 0,
        time_reading: Duration::ZERO,
        time_parsing: Duration::ZERO,
        time_db_insert: Duration::ZERO,
    };

    // Parse all syscalls into a vector first
    let mut syscalls = Vec::new();
    let mut time_reading = Duration::ZERO;
    let mut time_parsing = Duration::ZERO;

    for line_result in reader.lines() {
        let read_start = Instant::now();
        let line = line_result?;
        time_reading += read_start.elapsed();

        stats.total_lines += 1;

        let parse_start = Instant::now();
        if let Some(syscall) = parser::parse_line(&line) {
            syscalls.push(syscall);
            stats.parsed_lines += 1;
        } else {
            stats.failed_lines += 1;
        }
        time_parsing += parse_start.elapsed();
    }

    stats.time_reading = time_reading;
    stats.time_parsing = time_parsing;

    // Batch insert all syscalls at once using Appender API
    let db_start = Instant::now();
    if !syscalls.is_empty() {
        db.append_batch(filename, pid, &syscalls)?;
    }
    stats.time_db_insert = db_start.elapsed();

    Ok(stats)
}

/// Process a file using a provided appender (for reuse across multiple files)
pub fn process_file_with_appender(
    appender: &mut Appender,
    file_path: &Path,
) -> Result<ProcessStats> {
    use std::time::Instant;

    let start_io = Instant::now();
    let file =
        File::open(file_path).context(format!("Failed to open file: {}", file_path.display()))?;
    let reader = BufReader::new(file);

    let filename = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown");

    let pid = extract_pid(filename).unwrap_or(0);

    let mut stats = ProcessStats {
        total_lines: 0,
        parsed_lines: 0,
        failed_lines: 0,
        time_reading: Duration::ZERO,
        time_parsing: Duration::ZERO,
        time_db_insert: Duration::ZERO,
    };

    let mut time_reading = Duration::ZERO;
    let mut time_parsing = Duration::ZERO;
    let mut time_db = Duration::ZERO;

    for line_result in reader.lines() {
        let read_start = Instant::now();
        let line = line_result?;
        time_reading += read_start.elapsed();

        stats.total_lines += 1;

        let parse_start = Instant::now();
        if let Some(syscall) = parser::parse_line(&line) {
            time_parsing += parse_start.elapsed();

            // Append directly without buffering
            let db_start = Instant::now();
            appender.append_row(params![
                filename,
                pid,
                &syscall.timestamp,
                &syscall.syscall,
                &syscall.args,
                syscall.return_value,
                syscall.error_code.as_deref(),
                syscall.error_message.as_deref(),
                syscall.duration,
                syscall.unfinished,
                syscall.resumed,
            ])?;
            time_db += db_start.elapsed();

            stats.parsed_lines += 1;
        } else {
            time_parsing += parse_start.elapsed();
            stats.failed_lines += 1;
        }
    }

    stats.time_reading = time_reading;
    stats.time_parsing = time_parsing;
    stats.time_db_insert = time_db;

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_pid() {
        assert_eq!(extract_pid("trace.12345"), Some(12345));
        assert_eq!(
            extract_pid("zoom-trace-20251110-222110.1387679"),
            Some(1387679)
        );
        assert_eq!(extract_pid("notrace"), None);
        assert_eq!(extract_pid("trace.txt"), None);
    }

    #[test]
    fn test_process_tiny_file() {
        let db = Database::init(":memory:").expect("Failed to create database");
        let path = Path::new("tests/fixtures/tiny-trace.txt");

        let stats = process_file(&db, path).expect("Failed to process file");

        assert_eq!(stats.total_lines, 10, "Should read 10 lines");
        assert_eq!(stats.parsed_lines, 10, "Should parse all 10 lines");
        assert_eq!(stats.failed_lines, 0, "Should have no failures");

        let count = db.count_syscalls().expect("Failed to count");
        assert_eq!(count, 10, "Database should have 10 syscalls");
    }

    #[test]
    fn test_process_file_verifies_data() {
        let db = Database::init(":memory:").expect("Failed to create database");
        let path = Path::new("tests/fixtures/tiny-trace.txt");

        process_file(&db, path).expect("Failed to process file");

        // Verify first syscall (execve)
        let conn = db.get_connection();
        let conn = conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT syscall, timestamp FROM syscalls ORDER BY timestamp LIMIT 1")
            .expect("Failed to prepare");

        let result = stmt
            .query_row([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .expect("Failed to query");

        assert_eq!(result.0, "execve");
        assert_eq!(result.1, "22:21:11.524157");
    }
}
