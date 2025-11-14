use crate::types::Syscall;
use anyhow::{Context, Result};
use duckdb::{Connection, params};
use std::sync::{Arc, Mutex};

pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

impl Database {
    /// Initialize a new database with schema
    pub fn init(path: &str) -> Result<Self> {
        let conn =
            Connection::open(path).context(format!("Failed to open database at {}", path))?;

        // Create table
        conn.execute(
            r#"
            CREATE TABLE IF NOT EXISTS syscalls (
                trace_file VARCHAR,
                pid INTEGER,
                timestamp VARCHAR,
                syscall VARCHAR,
                args TEXT,
                return_value BIGINT,
                error_code VARCHAR,
                error_message VARCHAR,
                duration DOUBLE,
                unfinished BOOLEAN DEFAULT FALSE,
                resumed BOOLEAN DEFAULT FALSE
            )
            "#,
            [],
        )?;

        // Create indexes
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_syscall ON syscalls(syscall)",
            [],
        )?;
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pid ON syscalls(pid)", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_error ON syscalls(error_code)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_trace_file ON syscalls(trace_file)",
            [],
        )?;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Connect to an existing database (for workers)
    pub fn connect(path: &str) -> Result<Connection> {
        Connection::open(path).context(format!("Failed to connect to database at {}", path))
    }

    /// Get a clone of the connection for concurrent access
    pub fn get_connection(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.conn)
    }

    /// Append a syscall to the database using Appender API (10-100x faster)
    pub fn append_syscall(&self, trace_file: &str, pid: i32, syscall: &Syscall) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let mut appender = conn.appender("syscalls")?;

        appender.append_row(params![
            trace_file,
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

        appender.flush()?;
        Ok(())
    }

    /// Batch append multiple syscalls using Appender API (most efficient)
    pub fn append_batch(&self, trace_file: &str, pid: i32, syscalls: &[Syscall]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let mut appender = conn.appender("syscalls")?;

        for syscall in syscalls {
            appender.append_row(params![
                trace_file,
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
        }

        appender.flush()?;
        Ok(())
    }

    /// Count total syscalls
    pub fn count_syscalls(&self) -> Result<usize> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT COUNT(*) FROM syscalls")?;
        let count: i64 = stmt.query_row([], |row| row.get(0))?;
        Ok(count as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_database_init() {
        let db = Database::init(":memory:").expect("Failed to create database");
        let count = db.count_syscalls().expect("Failed to count");
        assert_eq!(count, 0, "New database should be empty");
    }

    #[test]
    fn test_append_syscall() {
        let db = Database::init(":memory:").expect("Failed to create database");

        let syscall = Syscall {
            timestamp: "22:21:11.524449".to_string(),
            syscall: "brk".to_string(),
            args: "NULL".to_string(),
            return_value: Some(0x55edad95f000_i64),
            error_code: None,
            error_message: None,
            duration: Some(0.000004),
            unfinished: false,
            resumed: false,
        };

        db.append_syscall("test.trace", 12345, &syscall)
            .expect("Failed to append syscall");

        let count = db.count_syscalls().expect("Failed to count");
        assert_eq!(count, 1, "Should have one syscall");

        // Verify the data
        let conn = db.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT syscall, pid, trace_file FROM syscalls")
            .expect("Failed to prepare query");

        let result = stmt
            .query_row([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i32>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .expect("Failed to query");

        assert_eq!(result, ("brk".to_string(), 12345, "test.trace".to_string()));
    }

    #[test]
    fn test_concurrent_appenders() {
        use std::thread;

        let db = Database::init(":memory:").expect("Failed to create database");
        let db = Arc::new(db);

        let mut handles = vec![];

        // Spawn 3 threads, each appending 100 syscalls
        for thread_id in 0..3 {
            let db_clone = Arc::clone(&db);
            let handle = thread::spawn(move || {
                for i in 0..100 {
                    let syscall = Syscall {
                        timestamp: format!("22:21:11.{:06}", i),
                        syscall: format!("syscall_{}", thread_id),
                        args: format!("arg_{}", i),
                        return_value: Some(i as i64),
                        error_code: None,
                        error_message: None,
                        duration: Some(0.000001),
                        unfinished: false,
                        resumed: false,
                    };

                    db_clone
                        .append_syscall(&format!("thread_{}.trace", thread_id), thread_id, &syscall)
                        .expect("Failed to append");
                }
            });
            handles.push(handle);
        }

        // Wait for all threads to complete
        for handle in handles {
            handle.join().expect("Thread panicked");
        }

        // Verify we have exactly 300 syscalls
        let count = db.count_syscalls().expect("Failed to count");
        assert_eq!(count, 300, "Should have 300 syscalls from 3 threads x 100");

        // Verify each thread's data
        for thread_id in 0..3 {
            let conn = db.conn.lock().unwrap();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT COUNT(*) FROM syscalls WHERE pid = {}",
                    thread_id
                ))
                .expect("Failed to prepare");

            let count: i64 = stmt
                .query_row([], |row| row.get(0))
                .expect("Failed to query");
            assert_eq!(count, 100, "Thread {} should have 100 syscalls", thread_id);
        }
    }
}
