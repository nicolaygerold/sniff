const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Use ReleaseSafe by default for release builds (ReleaseFast has issues with glob matching)
    const optimize = b.standardOptimizeOption(.{});

    // Add gitignore tests
    const gitignore_tests = b.addTest(.{
        .root_source_file = b.path("src/gitignore.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sniff",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the sniff CLI");
    run_step.dependOn(&run_cmd.step);

    const lib = b.addStaticLibrary(.{
        .name = "sniff",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const index_tests = b.addTest(.{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
    });

    const results_tests = b.addTest(.{
        .root_source_file = b.path("src/results.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scanner_tests = b.addTest(.{
        .root_source_file = b.path("src/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });

    const query_tests = b.addTest(.{
        .root_source_file = b.path("src/query.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scorer_tests = b.addTest(.{
        .root_source_file = b.path("src/scorer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_index_tests = b.addRunArtifact(index_tests);
    const run_results_tests = b.addRunArtifact(results_tests);
    const run_scanner_tests = b.addRunArtifact(scanner_tests);
    const run_query_tests = b.addRunArtifact(query_tests);
    const run_scorer_tests = b.addRunArtifact(scorer_tests);
    const run_gitignore_tests = b.addRunArtifact(gitignore_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_index_tests.step);
    test_step.dependOn(&run_results_tests.step);
    test_step.dependOn(&run_scanner_tests.step);
    test_step.dependOn(&run_query_tests.step);
    test_step.dependOn(&run_scorer_tests.step);
    test_step.dependOn(&run_gitignore_tests.step);
}
