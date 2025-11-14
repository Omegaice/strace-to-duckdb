use criterion::{BenchmarkId, Criterion, Throughput, black_box, criterion_group, criterion_main};
use rust::parser::{parse_line, parse_regular, parse_unfinished};

fn benchmark_parser_regular(c: &mut Criterion) {
    let samples = vec![
        (
            "simple",
            "22:21:11.524449 brk(NULL) = 0x55edad95f000 <0.000004>",
        ),
        (
            "with_error",
            "22:21:11.524519 access(\"/etc/ld-nix.so.preload\", R_OK) = -1 ENOENT (No such file or directory) <0.000030>",
        ),
        (
            "complex",
            "22:21:11.524791 newfstatat(AT_FDCWD, \"/nix/store/ga8daf4c0airy2v5akmg3lcv5saik7nf-pipewire-1.4.9-jack/lib/\", {st_mode=S_IFDIR|0555, st_size=11, ...}, 0) = 0 <0.000006>",
        ),
        (
            "execve",
            "22:21:11.524157 execve(\"/etc/profiles/per-user/omegaice/bin/zoom\", [\"zoom\"], 0x7ffeec7c3190 /* 166 vars */) = 0 <0.000200>",
        ),
    ];

    let mut group = c.benchmark_group("parse_regular");

    for (name, sample) in samples.iter() {
        group.throughput(Throughput::Bytes(sample.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(name), sample, |b, s| {
            b.iter(|| {
                black_box(parse_regular(s));
            });
        });
    }
    group.finish();
}

fn benchmark_parser_unfinished(c: &mut Criterion) {
    let samples = vec![
        (
            "poll",
            "22:21:24.927885 poll([{fd=8, events=POLLIN}, {fd=7, events=POLLIN}], 2, -1 <unfinished ...>) = ?",
        ),
        (
            "wait4",
            "22:21:24.927885 wait4(1387721 <unfinished ...>) = ?",
        ),
        (
            "epoll",
            "22:21:22.203042 epoll_wait(20 <unfinished ...>) = ?",
        ),
    ];

    let mut group = c.benchmark_group("parse_unfinished");

    for (name, sample) in samples.iter() {
        group.throughput(Throughput::Bytes(sample.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(name), sample, |b, s| {
            b.iter(|| {
                black_box(parse_unfinished(s));
            });
        });
    }
    group.finish();
}

fn benchmark_parse_line(c: &mut Criterion) {
    let samples = vec![
        (
            "regular",
            "22:21:11.524449 brk(NULL) = 0x55edad95f000 <0.000004>",
        ),
        (
            "error",
            "22:21:11.524519 access(\"/etc/ld-nix.so.preload\", R_OK) = -1 ENOENT (No such file or directory) <0.000030>",
        ),
        (
            "unfinished",
            "22:21:24.927885 poll([{fd=8, events=POLLIN}], 2, -1 <unfinished ...>) = ?",
        ),
    ];

    let mut group = c.benchmark_group("parse_line");

    for (name, sample) in samples.iter() {
        group.throughput(Throughput::Bytes(sample.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(name), sample, |b, s| {
            b.iter(|| {
                black_box(parse_line(s));
            });
        });
    }
    group.finish();
}

fn benchmark_batch_parsing(c: &mut Criterion) {
    // Simulate parsing a realistic batch of lines
    let lines = vec![
        "22:21:11.524449 brk(NULL) = 0x55edad95f000 <0.000004>",
        "22:21:11.524519 access(\"/etc/ld-nix.so.preload\", R_OK) = -1 ENOENT (No such file or directory) <0.000030>",
        "22:21:11.524791 newfstatat(AT_FDCWD, \"/nix/store/path\", {st_mode=S_IFDIR|0555}, 0) = 0 <0.000006>",
        "22:21:24.927885 poll([{fd=8, events=POLLIN}], 2, -1 <unfinished ...>) = ?",
        "22:21:11.524157 execve(\"/bin/zoom\", [\"zoom\"], 0x7ffeec7c3190 /* 166 vars */) = 0 <0.000200>",
    ];

    let total_bytes: usize = lines.iter().map(|s| s.len()).sum();

    let mut group = c.benchmark_group("batch_parsing");
    group.throughput(Throughput::Bytes((total_bytes * 20) as u64));

    group.bench_function("batch_100_lines", |b| {
        b.iter(|| {
            for _ in 0..20 {
                for line in &lines {
                    black_box(parse_line(line));
                }
            }
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    benchmark_parser_regular,
    benchmark_parser_unfinished,
    benchmark_parse_line,
    benchmark_batch_parsing
);
criterion_main!(benches);
