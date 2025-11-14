use crate::database::Database;
use crate::processor::{self, ProcessStats};
use anyhow::Result;
use crossbeam::channel;
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::thread;
use std::time::Instant;

pub fn process_files_parallel(
    db: Arc<Database>,
    _db_path: &str,
    files: Vec<PathBuf>,
) -> Result<ProcessStats> {
    let num_threads = num_cpus::get();
    let num_files = files.len();
    let (sender, receiver) = channel::unbounded::<PathBuf>();

    // Send all files to the channel
    for file in files {
        sender.send(file)?;
    }
    drop(sender); // Close the channel

    // Setup progress bars
    let multi_progress = MultiProgress::new();
    let overall_progress = multi_progress.add(ProgressBar::new(num_files as u64));
    overall_progress.set_style(
        ProgressStyle::default_bar()
            .template(
                "{spinner:.green} [{bar:40.cyan/blue}] {pos}/{len} files ({percent}%) | {msg}",
            )
            .unwrap()
            .progress_chars("#>-"),
    );

    let files_processed = Arc::new(AtomicUsize::new(0));
    let start_time = Instant::now();

    // Shared statistics counters
    let total_lines = Arc::new(AtomicUsize::new(0));
    let parsed_lines = Arc::new(AtomicUsize::new(0));
    let failed_lines = Arc::new(AtomicUsize::new(0));
    let time_reading = Arc::new(std::sync::Mutex::new(std::time::Duration::ZERO));
    let time_parsing = Arc::new(std::sync::Mutex::new(std::time::Duration::ZERO));
    let time_db_insert = Arc::new(std::sync::Mutex::new(std::time::Duration::ZERO));

    // Spawn worker threads
    let mut handles = vec![];

    for worker_id in 0..num_threads {
        let receiver = receiver.clone();
        let db_clone = Arc::clone(&db);
        let total = Arc::clone(&total_lines);
        let parsed = Arc::clone(&parsed_lines);
        let failed = Arc::clone(&failed_lines);
        let t_read = Arc::clone(&time_reading);
        let t_parse = Arc::clone(&time_parsing);
        let t_db = Arc::clone(&time_db_insert);
        let files_done = Arc::clone(&files_processed);
        let progress = overall_progress.clone();

        let handle = thread::spawn(move || -> Result<()> {
            // Clone connection for this worker (connection to same DB instance)
            let worker_conn = {
                let main_conn = db_clone.get_connection();
                let conn = main_conn.lock().unwrap();
                conn.try_clone()?
            }; // Mutex released immediately

            // Create ONE appender for this worker
            let mut appender = worker_conn.appender("syscalls")?;

            // Process all files with the same appender
            while let Ok(file_path) = receiver.recv() {
                let file_name = file_path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("unknown");

                match processor::process_file_with_appender(&mut appender, &file_path) {
                    Ok(stats) => {
                        let current_total = total.fetch_add(stats.total_lines, Ordering::SeqCst)
                            + stats.total_lines;
                        parsed.fetch_add(stats.parsed_lines, Ordering::SeqCst);
                        failed.fetch_add(stats.failed_lines, Ordering::SeqCst);

                        // Accumulate timing stats
                        *t_read.lock().unwrap() += stats.time_reading;
                        *t_parse.lock().unwrap() += stats.time_parsing;
                        *t_db.lock().unwrap() += stats.time_db_insert;

                        let done = files_done.fetch_add(1, Ordering::SeqCst) + 1;

                        // Calculate throughput
                        let elapsed = start_time.elapsed().as_secs_f64();
                        let lines_per_sec = if elapsed > 0.0 {
                            current_total as f64 / elapsed
                        } else {
                            0.0
                        };

                        progress.set_position(done as u64);
                        progress.set_message(format!(
                            "{:.1}K lines/sec | Last: {}",
                            lines_per_sec / 1000.0,
                            file_name
                        ));
                    }
                    Err(e) => {
                        eprintln!(
                            "[Worker {}] Error processing {}: {}",
                            worker_id,
                            file_path.display(),
                            e
                        );
                    }
                }
            }

            // Flush once when worker is done with all files
            appender.flush()?;

            Ok(())
        });

        handles.push(handle);
    }

    // Wait for all workers to complete
    for (i, handle) in handles.into_iter().enumerate() {
        match handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                eprintln!("Worker {} returned error: {}", i, e);
            }
            Err(_) => {
                eprintln!("Worker {} panicked", i);
            }
        }
    }

    overall_progress.finish_with_message("Complete!");

    Ok(ProcessStats {
        total_lines: total_lines.load(Ordering::SeqCst),
        parsed_lines: parsed_lines.load(Ordering::SeqCst),
        failed_lines: failed_lines.load(Ordering::SeqCst),
        time_reading: *time_reading.lock().unwrap(),
        time_parsing: *time_parsing.lock().unwrap(),
        time_db_insert: *time_db_insert.lock().unwrap(),
    })
}
