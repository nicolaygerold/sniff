const std = @import("std");
const Allocator = std.mem.Allocator;

const PathIndex = @import("index.zig").PathIndex;
const PathEntry = @import("index.zig").PathEntry;
const Query = @import("query.zig").Query;
const Scorer = @import("scorer.zig").Scorer;
const Scanner = @import("scanner.zig").Scanner;
const ScanConfig = @import("scanner.zig").ScanConfig;
const ResultHeap = @import("results.zig").ResultHeap;
pub const SearchResult = @import("results.zig").SearchResult;

pub const Config = struct {
    scan: ScanConfig = .{},
    max_results: usize = 512,
};

pub const Sniff = struct {
    allocator: Allocator,
    index: PathIndex,
    scorer: Scorer,
    config: Config,
    results: ResultHeap,

    pub fn init(allocator: Allocator, config: Config) Sniff {
        return .{
            .allocator = allocator,
            .index = PathIndex.init(allocator),
            .scorer = Scorer.init(),
            .config = config,
            .results = ResultHeap.init(),
        };
    }

    pub fn deinit(self: *Sniff) void {
        self.index.deinit();
    }

    pub fn indexDirectory(self: *Sniff, root: []const u8) !void {
        var scanner = Scanner.init(&self.index, self.config.scan);
        try scanner.scan(root);
    }

    pub fn search(self: *Sniff, query_str: []const u8) []SearchResult {
        if (query_str.len == 0) {
            return &.{};
        }

        var query = Query.init(self.allocator, query_str) catch return &.{};
        defer query.deinit(self.allocator);

        self.results = ResultHeap.init();

        for (self.index.entries.items) |*entry| {
            const path = if (query.has_path_sep) entry.path else entry.path[entry.basename_start..];
            const path_lower = if (query.has_path_sep) entry.path_lower else entry.path_lower[entry.basename_start..];

            if (self.scorer.score(query.raw, query.lower, path, path_lower)) |match| {
                self.results.insert(.{
                    .entry = entry,
                    .score = match.score,
                    .positions = match.positions.slice(),
                });
            }
        }

        return self.results.getSorted();
    }

    pub fn clear(self: *Sniff) void {
        self.index.clear();
    }

    pub fn fileCount(self: Sniff) usize {
        return self.index.count();
    }
};
