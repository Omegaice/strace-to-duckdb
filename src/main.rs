use rust::{database, parallel_processor, processor};

use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Parser, Debug)]
#[command(name = "strace-to-duckdb")]
#[command(about = "Parse strace output files and load into DuckDB", long_about = None)]
struct Args {
    /// Output database path
    #[arg(short, long)]
    output: PathBuf,

    /// Sequential mode (disable parallel processing)
    #[arg(short, long)]
    sequential: bool,

    /// Input trace files
    files: Vec<PathBuf>,
}

fn main() -> Result<()> {
    let args = Args::parse();

    if args.files.is_empty() {
        eprintln!("Error: No input files specified");
        std::process::exit(1);
    }

    // Delete existing database if it exists
    if args.output.exists() {
        std::fs::remove_file(&args.output).context("Failed to delete existing database")?;
    }

    // Initialize database
    let db = Arc::new(database::Database::init(
        args.output.to_str().unwrap_or("output.db"),
    )?);

    println!("Processing {} file(s)...", args.files.len());

    let start = std::time::Instant::now();
    let total_stats = if args.sequential {
        // Sequential processing
        let mut total_stats = processor::ProcessStats {
            total_lines: 0,
            parsed_lines: 0,
            failed_lines: 0,
            time_reading: std::time::Duration::ZERO,
            time_parsing: std::time::Duration::ZERO,
            time_db_insert: std::time::Duration::ZERO,
        };

        for file_path in &args.files {
            println!("Processing: {}", file_path.display());
            let stats = processor::process_file(&db, file_path)?;

            total_stats.total_lines += stats.total_lines;
            total_stats.parsed_lines += stats.parsed_lines;
            total_stats.failed_lines += stats.failed_lines;
            total_stats.time_reading += stats.time_reading;
            total_stats.time_parsing += stats.time_parsing;
            total_stats.time_db_insert += stats.time_db_insert;

            println!(
                "  Lines: {} total, {} parsed, {} failed",
                stats.total_lines, stats.parsed_lines, stats.failed_lines
            );
        }
        total_stats
    } else {
        // Parallel processing
        println!("Using {} threads", num_cpus::get());
        let db_path = args.output.to_str().unwrap_or("output.db");
        parallel_processor::process_files_parallel(Arc::clone(&db), db_path, args.files)?
    };

    let elapsed = start.elapsed();

    println!("\n=== Summary ===");
    println!("Total lines:  {}", total_stats.total_lines);
    println!("Parsed:       {}", total_stats.parsed_lines);
    println!("Failed:       {}", total_stats.failed_lines);
    println!("Time:         {:.2}s", elapsed.as_secs_f64());
    println!(
        "Throughput:   {:.1}K lines/sec",
        total_stats.total_lines as f64 / elapsed.as_secs_f64() / 1000.0
    );

    println!("\n=== Time Breakdown ===");
    let total_work =
        total_stats.time_reading + total_stats.time_parsing + total_stats.time_db_insert;
    println!(
        "File I/O:     {:.2}s ({:.1}%)",
        total_stats.time_reading.as_secs_f64(),
        total_stats.time_reading.as_secs_f64() / total_work.as_secs_f64() * 100.0
    );
    println!(
        "Parsing:      {:.2}s ({:.1}%)",
        total_stats.time_parsing.as_secs_f64(),
        total_stats.time_parsing.as_secs_f64() / total_work.as_secs_f64() * 100.0
    );
    println!(
        "DB Insert:    {:.2}s ({:.1}%)",
        total_stats.time_db_insert.as_secs_f64(),
        total_stats.time_db_insert.as_secs_f64() / total_work.as_secs_f64() * 100.0
    );
    println!("Total Work:   {:.2}s", total_work.as_secs_f64());
    println!(
        "Parallelism:  {:.1}x (wall: {:.2}s, work: {:.2}s)",
        total_work.as_secs_f64() / elapsed.as_secs_f64(),
        elapsed.as_secs_f64(),
        total_work.as_secs_f64()
    );

    println!("\nDatabase:     {}", args.output.display());

    let syscall_count = db.count_syscalls()?;
    println!("Syscalls in DB: {}", syscall_count);

    Ok(())
}
