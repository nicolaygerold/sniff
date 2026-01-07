const std = @import("std");
const PathIndex = @import("index.zig").PathIndex;
const Scanner = @import("scanner.zig").Scanner;
const ScanConfig = @import("scanner.zig").ScanConfig;
const ParallelScanner = @import("parallel_scanner.zig").ParallelScanner;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: bench <directory>\n", .{});
        return;
    }

    const path = try std.fs.cwd().realpathAlloc(allocator, args[1]);
    defer allocator.free(path);

    std.debug.print("Benchmarking directory: {s}\n\n", .{path});

    const config_no_gitignore = ScanConfig{
        .respect_gitignore = false,
    };

    const config_with_gitignore = ScanConfig{
        .respect_gitignore = true,
    };

    // Warm up filesystem cache with a quick scan
    {
        var index = PathIndex.init(allocator);
        defer index.deinit();
        var scanner = Scanner.init(&index, config_no_gitignore);
        defer scanner.deinit();
        scanner.scan(path) catch {};
    }

    // Benchmark scanner WITHOUT gitignore (baseline)
    std.debug.print("=== Baseline (no gitignore processing) ===\n\n", .{});
    var baseline_total: i64 = 0;
    var baseline_count: usize = 0;
    for (0..3) |i| {
        var index = PathIndex.init(allocator);
        defer index.deinit();

        var scanner = Scanner.init(&index, config_no_gitignore);
        defer scanner.deinit();

        const start = std.time.milliTimestamp();
        try scanner.scan(path);
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("  Run {d}: {d} files in {d}ms\n", .{ i + 1, index.count(), elapsed });
        baseline_total += elapsed;
        baseline_count = index.count();
    }
    const baseline_avg = @divTrunc(baseline_total, 3);
    std.debug.print("  Average: {d}ms\n\n", .{baseline_avg});

    // Benchmark scanner WITH FastGitIgnore
    std.debug.print("=== With FastGitIgnore (optimized) ===\n\n", .{});
    var fast_total: i64 = 0;
    var fast_count: usize = 0;
    for (0..3) |i| {
        var index = PathIndex.init(allocator);
        defer index.deinit();

        var scanner = Scanner.init(&index, config_with_gitignore);
        defer scanner.deinit();

        const start = std.time.milliTimestamp();
        try scanner.scan(path);
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("  Run {d}: {d} files in {d}ms\n", .{ i + 1, index.count(), elapsed });
        fast_total += elapsed;
        fast_count = index.count();
    }
    const fast_avg = @divTrunc(fast_total, 3);
    std.debug.print("  Average: {d}ms\n\n", .{fast_avg});

    // Benchmark parallel scanner WITHOUT gitignore
    std.debug.print("=== Parallel scanner (no gitignore) ===\n", .{});
    std.debug.print("({d} threads)\n\n", .{std.Thread.getCpuCount() catch 4});
    var para_total: i64 = 0;
    var para_count: usize = 0;
    for (0..3) |i| {
        var index = PathIndex.init(allocator);
        defer index.deinit();

        var scanner = ParallelScanner.init(allocator, config_no_gitignore);

        const start = std.time.milliTimestamp();
        try scanner.scan(&index, path);
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("  Run {d}: {d} files in {d}ms\n", .{ i + 1, index.count(), elapsed });
        para_total += elapsed;
        para_count = index.count();
    }
    const para_avg = @divTrunc(para_total, 3);
    std.debug.print("  Average: {d}ms\n\n", .{para_avg});

    // Summary
    std.debug.print("=== Summary ===\n\n", .{});
    std.debug.print("  Baseline (no gitignore):   {d} files in {d}ms\n", .{ baseline_count, baseline_avg });
    std.debug.print("  FastGitIgnore:             {d} files in {d}ms\n", .{ fast_count, fast_avg });
    std.debug.print("  Parallel (no gitignore):   {d} files in {d}ms\n\n", .{ para_count, para_avg });

    const gitignore_overhead = @as(f64, @floatFromInt(fast_avg)) / @as(f64, @floatFromInt(baseline_avg));
    const parallel_speedup = @as(f64, @floatFromInt(baseline_avg)) / @as(f64, @floatFromInt(para_avg));

    std.debug.print("  GitIgnore overhead: {d:.2}x (target: <1.5x)\n", .{gitignore_overhead});
    std.debug.print("  Parallel speedup:   {d:.2}x\n", .{parallel_speedup});

    if (gitignore_overhead < 1.5) {
        std.debug.print("\n  ✓ GitIgnore overhead is within target!\n", .{});
    } else {
        std.debug.print("\n  ✗ GitIgnore overhead exceeds 1.5x target\n", .{});
    }
}
