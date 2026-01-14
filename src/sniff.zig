const std = @import("std");
const Allocator = std.mem.Allocator;

const PathIndex = @import("index.zig").PathIndex;
const PathEntry = @import("index.zig").PathEntry;
const Query = @import("query.zig").Query;
const Scorer = @import("scorer.zig").Scorer;
const Scanner = @import("scanner.zig").Scanner;
const ScanConfig = @import("scanner.zig").ScanConfig;
const ResultHeap = @import("results.zig").ResultHeap;
const Cache = @import("cache.zig").Cache;
const Watcher = @import("watcher.zig").Watcher;
const WatchEvent = @import("watcher.zig").WatchEvent;

pub const SearchResult = @import("results.zig").SearchResult;

pub const Config = struct {
    scan: ScanConfig = .{},
    max_results: usize = 512,
    use_cache: bool = true,
    use_watcher: bool = true,
};

pub const Sniff = struct {
    allocator: Allocator,
    index: PathIndex,
    scorer: Scorer,
    config: Config,
    results: ResultHeap,
    cache: ?Cache,
    watcher: ?Watcher,
    root_path: ?[]const u8,
    index_time: i64,

    pub fn init(allocator: Allocator, config: Config) Sniff {
        var cache: ?Cache = null;
        if (config.use_cache) {
            cache = Cache.init(allocator) catch null;
        }

        return .{
            .allocator = allocator,
            .index = PathIndex.init(allocator),
            .scorer = Scorer.init(),
            .config = config,
            .results = ResultHeap.init(),
            .cache = cache,
            .watcher = null,
            .root_path = null,
            .index_time = 0,
        };
    }

    pub fn deinit(self: *Sniff) void {
        if (self.watcher) |*w| w.deinit();
        if (self.cache) |*c| c.deinit();
        if (self.root_path) |p| self.allocator.free(p);
        self.index.deinit();
    }

    pub fn indexDirectory(self: *Sniff, root: []const u8) !void {
        // Store root path
        if (self.root_path) |p| self.allocator.free(p);
        self.root_path = try self.allocator.dupe(u8, root);

        // Try to load from cache first
        if (self.cache) |*cache| {
            if (cache.loadIndex(&self.index, root)) |index_time| {
                self.index_time = index_time;

                // Start watcher for incremental updates
                if (self.config.use_watcher) {
                    self.watcher = Watcher.init(self.allocator, root) catch null;
                }
                return;
            } else |_| {
                // Cache miss or error, do full scan
            }
        }

        // Full scan
        var scanner = Scanner.init(&self.index, self.config.scan);
        try scanner.scan(root);

        // Save to cache
        if (self.cache) |*cache| {
            cache.saveIndex(&self.index, root) catch {};
        }

        self.index_time = std.time.timestamp();

        // Start watcher
        if (self.config.use_watcher) {
            self.watcher = Watcher.init(self.allocator, root) catch null;
        }
    }

    pub fn processWatchEvents(self: *Sniff) !void {
        const root = self.root_path orelse return;
        const watcher_ptr: *Watcher = &(self.watcher orelse return);

        const events = try watcher_ptr.poll();

        for (events) |ev| {
            switch (ev.kind) {
                .created => {
                    // Check if it's a file and add to index
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, ev.path });
                    defer self.allocator.free(full_path);

                    const stat = std.fs.cwd().statFile(full_path) catch continue;
                    if (stat.kind == .file) {
                        // Add relative path to index
                        try self.index.addPath(ev.path);
                    } else if (stat.kind == .directory) {
                        // Scan the new directory
                        var scanner = Scanner.init(&self.index, self.config.scan);
                        scanner.scanDir(std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch continue, ev.path, 0) catch {};
                    }
                },
                .deleted => {
                    // Remove from index (handles both files and directories)
                    self.index.removePath(ev.path);
                    self.index.removePathsWithPrefix(ev.path);
                },
                .modified => {
                    // For a fuzzy file finder, file content changes don't matter
                    // But directory changes might mean new files
                    if (std.mem.endsWith(u8, ev.path, "/") or self.isDirectory(ev.path)) {
                        try self.rescanDirectory(ev.path);
                    }
                },
                .renamed => {
                    // Old path is deleted, new path will come as created event
                    self.index.removePath(ev.path);
                },
            }
        }
    }

    fn isDirectory(self: *Sniff, rel_path: []const u8) bool {
        const root = self.root_path orelse return false;
        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, rel_path }) catch return false;
        defer self.allocator.free(full_path);

        const stat = std.fs.cwd().statFile(full_path) catch return false;
        return stat.kind == .directory;
    }

    fn rescanDirectory(self: *Sniff, rel_path: []const u8) !void {
        const root = self.root_path orelse return;
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, rel_path });
        defer self.allocator.free(full_path);

        // Remove old entries with this prefix
        self.index.removePathsWithPrefix(rel_path);

        // Rescan the directory
        var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var scanner = Scanner.init(&self.index, self.config.scan);
        try scanner.scanDir(dir, rel_path, 0);
    }

    pub fn search(self: *Sniff, query_str: []const u8) []SearchResult {
        if (query_str.len == 0) {
            return &.{};
        }

        // Process any pending watch events before searching
        self.processWatchEvents() catch {};

        var query = Query.init(self.allocator, query_str) catch return &.{};
        defer query.deinit(self.allocator);

        self.results = ResultHeap.init();

        for (self.index.entries.items) |*entry| {
            const path = if (query.has_path_sep) entry.path else entry.path[entry.basename_start..];
            const path_lower = if (query.has_path_sep) entry.path_lower else entry.path_lower[entry.basename_start..];

            // Use threshold-based scoring for early termination
            // Once we have MAX_RESULTS, skip entries that can't beat min score
            const threshold = if (self.results.items.len == ResultHeap.MAX_RESULTS)
                self.results.min_score
            else
                std.math.minInt(i32) / 2;

            if (self.scorer.scoreWithThreshold(query.raw, query.lower, path, path_lower, threshold)) |match| {
                if (match.score > threshold) {
                    self.results.insert(.{
                        .entry = entry,
                        .score = match.score,
                        .positions = match.positions.slice(),
                    });
                }
            }
        }

        const sorted = self.results.getSorted();

        // Lazy validation: verify top results still exist on disk
        // This handles stale cache entries for deleted files
        return self.validateResults(sorted);
    }

    /// Validate that result files still exist, removing stale entries
    /// Only checks files we're about to return, not the entire index
    fn validateResults(self: *Sniff, results: []SearchResult) []SearchResult {
        const root = self.root_path orelse return results;

        var stale_paths = std.ArrayList([]const u8).init(self.allocator);
        defer stale_paths.deinit();

        var valid_count: usize = 0;
        for (results) |*result| {
            const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, result.entry.path }) catch {
                // On alloc failure, keep the result
                results[valid_count] = result.*;
                valid_count += 1;
                continue;
            };
            defer self.allocator.free(full_path);

            // Quick existence check via access()
            std.fs.cwd().access(full_path, .{}) catch {
                // File doesn't exist - mark for removal from index
                stale_paths.append(result.entry.path) catch {};
                continue;
            };

            // File exists - keep in results
            results[valid_count] = result.*;
            valid_count += 1;
        }

        // Remove stale entries from index (deferred to avoid iterator invalidation)
        for (stale_paths.items) |path| {
            self.index.removePath(path);
        }

        return results[0..valid_count];
    }

    pub fn clear(self: *Sniff) void {
        self.index.clear();
    }

    pub fn fileCount(self: Sniff) usize {
        return self.index.count();
    }

    pub fn saveCache(self: *Sniff) !void {
        const cache = &(self.cache orelse return error.NoCacheAvailable);
        const root = self.root_path orelse return error.NoRootPath;
        try cache.saveIndex(&self.index, root);
    }

    pub fn clearCache(self: *Sniff) !void {
        const cache = &(self.cache orelse return error.NoCacheAvailable);
        const root = self.root_path orelse return error.NoRootPath;
        try cache.deleteIndex(root);
    }

    pub fn isWatching(self: *const Sniff) bool {
        return self.watcher != null;
    }

    pub fn isCached(self: *const Sniff) bool {
        if (self.cache) |*cache| {
            if (self.root_path) |root| {
                return cache.hasValidIndex(root);
            }
        }
        return false;
    }
};

test "sniff init and deinit" {
    const allocator = std.testing.allocator;

    var sniff = Sniff.init(allocator, .{});
    defer sniff.deinit();

    try std.testing.expect(sniff.fileCount() == 0);
}

test "sniff with cache disabled" {
    const allocator = std.testing.allocator;

    var sniff = Sniff.init(allocator, .{ .use_cache = false, .use_watcher = false });
    defer sniff.deinit();

    try std.testing.expect(sniff.cache == null);
    try std.testing.expect(sniff.watcher == null);
}

test "sniff lazy validation removes stale entries" {
    const allocator = std.testing.allocator;

    var sniff = Sniff.init(allocator, .{ .use_cache = false, .use_watcher = false });
    defer sniff.deinit();

    // Add a path that doesn't exist
    try sniff.index.addPath("nonexistent/file.txt");
    try std.testing.expectEqual(@as(usize, 1), sniff.fileCount());

    // Set root path so validation runs
    sniff.root_path = try allocator.dupe(u8, "/tmp");

    // Search should trigger validation and remove stale entry
    const results = sniff.search("file");
    try std.testing.expectEqual(@as(usize, 0), results.len);

    // Stale entry should be removed from index
    try std.testing.expectEqual(@as(usize, 0), sniff.fileCount());
}
