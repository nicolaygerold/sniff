const std = @import("std");
const Sniff = @import("sniff.zig").Sniff;
const Config = @import("sniff.zig").Config;
const SearchResult = @import("sniff.zig").SearchResult;

const Mode = enum { interactive, json, oneshot };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var directory: ?[]const u8 = null;
    var query_arg: ?[]const u8 = null;
    var mode: Mode = .interactive;
    var max_results: usize = 100;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            mode = .json;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i < args.len) {
                max_results = std.fmt.parseInt(usize, args[i], 10) catch 100;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (directory == null) {
            directory = arg;
        } else if (query_arg == null) {
            query_arg = arg;
            if (mode != .json) mode = .oneshot;
        }
    }

    if (directory == null) {
        printUsage();
        return;
    }

    const abs_path = std.fs.cwd().realpathAlloc(allocator, directory.?) catch |err| {
        if (mode == .json) {
            try writeJsonError("Failed to resolve directory path");
        } else {
            std.debug.print("Error resolving path '{s}': {}\n", .{ directory.?, err });
        }
        return;
    };
    defer allocator.free(abs_path);

    var sniff = Sniff.init(allocator, Config{ .max_results = max_results });
    defer sniff.deinit();

    const start = std.time.milliTimestamp();
    sniff.indexDirectory(abs_path) catch |err| {
        if (mode == .json) {
            try writeJsonError("Failed to index directory");
        } else {
            std.debug.print("Error indexing directory: {}\n", .{err});
        }
        return;
    };
    const index_time = std.time.milliTimestamp() - start;

    switch (mode) {
        .json => try runJsonMode(&sniff, index_time),
        .oneshot => {
            std.debug.print("Indexed {d} files in {d}ms\n", .{ sniff.fileCount(), index_time });
            if (query_arg) |query| {
                const search_start = std.time.milliTimestamp();
                const results = sniff.search(query);
                const search_time = std.time.milliTimestamp() - search_start;
                printResults(results);
                std.debug.print("Search completed in {d}ms\n", .{search_time});
            }
        },
        .interactive => {
            std.debug.print("Indexed {d} files in {d}ms\n", .{ sniff.fileCount(), index_time });
            try runInteractiveMode(&sniff);
        },
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: sniff [options] <directory> [query]
        \\
        \\Options:
        \\  --json       JSON protocol mode (for tool integration)
        \\  --limit N    Maximum results to return (default: 100)
        \\  --help, -h   Show this help
        \\
        \\Modes:
        \\  sniff <dir>           Interactive mode (human-friendly)
        \\  sniff <dir> <query>   One-shot search
        \\  sniff --json <dir>    JSON mode (reads queries from stdin, outputs JSON)
        \\
        \\JSON Protocol:
        \\  Input:  One query per line
        \\  Output: JSON object per line (newline-delimited JSON)
        \\
        \\  Ready message:   {{"type":"ready","files":N,"indexTime":M}}
        \\  Results message: {{"type":"results","query":"...","results":[...],"searchTime":M}}
        \\  Error message:   {{"type":"error","message":"..."}}
        \\
    , .{});
}

fn runJsonMode(sniff: *Sniff, index_time: i64) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    // Send ready message
    try stdout.print("{{\"type\":\"ready\",\"files\":{d},\"indexTime\":{d}}}\n", .{
        sniff.fileCount(),
        index_time,
    });

    var buf: [4096]u8 = undefined;

    while (true) {
        const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            try writeJsonError("Read error");
            continue;
        };

        const query = std.mem.trim(u8, line, " \t\r");
        if (query.len == 0) continue;

        const search_start = std.time.milliTimestamp();
        const results = sniff.search(query);
        const search_time = std.time.milliTimestamp() - search_start;

        try writeJsonResults(stdout, query, results, search_time);
    }
}

fn writeJsonResults(writer: anytype, query: []const u8, results: []const SearchResult, search_time: i64) !void {
    try writer.print("{{\"type\":\"results\",\"query\":\"", .{});
    try writeJsonString(writer, query);
    try writer.print("\",\"searchTime\":{d},\"results\":[", .{search_time});

    for (results, 0..) |result, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"path\":\"", .{});
        try writeJsonString(writer, result.entry.path);
        try writer.print("\",\"score\":{d},\"positions\":[", .{result.score});

        // Write match positions
        for (result.positions, 0..) |pos, pidx| {
            if (pidx > 0) try writer.writeByte(',');
            try writer.print("{d}", .{pos});
        }
        try writer.print("]}}", .{});
    }

    try writer.print("]}}\n", .{});
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

fn writeJsonError(message: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{{\"type\":\"error\",\"message\":\"{s}\"}}\n", .{message});
}

fn runInteractiveMode(sniff: *Sniff) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var buf: [1024]u8 = undefined;

    while (true) {
        try stdout.print("> ", .{});
        const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        const query = std.mem.trim(u8, line, " \t\r");
        if (query.len == 0) continue;

        const results = sniff.search(query);
        printResults(results);
    }
}

fn printResults(results: []const SearchResult) void {
    if (results.len == 0) {
        std.debug.print("No results\n", .{});
        return;
    }

    for (results) |result| {
        std.debug.print("{s} (score: {d})\n", .{ result.entry.path, result.score });
    }
}
