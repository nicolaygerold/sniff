const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const PathIndex = @import("index.zig").PathIndex;
const GitIgnore = @import("gitignore.zig").GitIgnore;
const ScanConfig = @import("scanner.zig").ScanConfig;

/// Work item for parallel scanning
const WorkItem = struct {
    path: []const u8,
    depth: usize,
};

/// Thread-local scanner state
const ThreadScanner = struct {
    allocator: Allocator,
    config: ScanConfig,
    paths: std.ArrayList([]const u8),
    local_queue: std.ArrayList(WorkItem),

    fn init(allocator: Allocator, config: ScanConfig) ThreadScanner {
        return .{
            .allocator = allocator,
            .config = config,
            .paths = std.ArrayList([]const u8).init(allocator),
            .local_queue = std.ArrayList(WorkItem).init(allocator),
        };
    }

    fn deinit(self: *ThreadScanner) void {
        self.paths.deinit();
        self.local_queue.deinit();
    }

    fn processDirectory(self: *ThreadScanner, dir_path: []const u8, depth: usize) void {
        if (depth > self.config.max_depth) return;

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            const name = entry.name;

            // Quick filters - no allocation needed
            if (self.config.ignore_hidden and name.len > 0 and name[0] == '.') continue;
            if (self.shouldIgnoreName(name)) continue;

            if (entry.kind == .directory) {
                // Queue subdirectory for processing
                const subpath = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
                self.local_queue.append(.{ .path = subpath, .depth = depth + 1 }) catch continue;
            } else if (entry.kind == .file or entry.kind == .sym_link) {
                // Collect file path
                const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
                self.paths.append(path) catch continue;
            }
        }
    }

    fn shouldIgnoreName(self: *ThreadScanner, name: []const u8) bool {
        for (self.config.ignore_patterns) |pattern| {
            if (std.mem.eql(u8, name, pattern)) return true;
        }
        return false;
    }
};

/// Parallel directory scanner using work-stealing
pub const ParallelScanner = struct {
    allocator: Allocator,
    config: ScanConfig,
    root_len: usize,

    pub fn init(allocator: Allocator, config: ScanConfig) ParallelScanner {
        return .{
            .allocator = allocator,
            .config = config,
            .root_len = 0,
        };
    }

    pub fn scan(self: *ParallelScanner, index: *PathIndex, root: []const u8) !void {
        self.root_len = root.len;
        if (self.root_len > 0 and root[self.root_len - 1] != '/') {
            self.root_len += 1;
        }

        const num_threads = getThreadCount();

        if (num_threads <= 1) {
            // Fall back to single-threaded for small jobs
            try self.scanSingleThreaded(index, root);
            return;
        }

        // Collect top-level directories first
        var initial_dirs = std.ArrayList(WorkItem).init(self.allocator);
        defer initial_dirs.deinit();

        var root_dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
        defer root_dir.close();

        var iter = root_dir.iterate();
        while (try iter.next()) |entry| {
            const name = entry.name;
            if (self.config.ignore_hidden and name.len > 0 and name[0] == '.') continue;
            if (self.shouldIgnoreName(name)) continue;

            if (entry.kind == .directory) {
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, name });
                try initial_dirs.append(.{ .path = path, .depth = 1 });
            } else if (entry.kind == .file or entry.kind == .sym_link) {
                const rel_path = try self.allocator.dupe(u8, name);
                try index.addPath(rel_path);
            }
        }

        if (initial_dirs.items.len == 0) return;

        // Distribute work across threads
        const threads_to_use = @min(num_threads, initial_dirs.items.len);
        var thread_handles = try self.allocator.alloc(std.Thread, threads_to_use);
        defer self.allocator.free(thread_handles);

        var thread_scanners = try self.allocator.alloc(ThreadScanner, threads_to_use);
        defer self.allocator.free(thread_scanners);

        // Initialize thread scanners and distribute initial work
        for (0..threads_to_use) |i| {
            thread_scanners[i] = ThreadScanner.init(self.allocator, self.config);
        }

        // Round-robin distribute directories to threads
        for (initial_dirs.items, 0..) |item, i| {
            const thread_idx = i % threads_to_use;
            thread_scanners[thread_idx].local_queue.append(item) catch {};
        }

        // Spawn worker threads
        for (0..threads_to_use) |i| {
            thread_handles[i] = try std.Thread.spawn(.{}, workerThread, .{&thread_scanners[i]});
        }

        // Wait for all threads
        for (thread_handles) |handle| {
            handle.join();
        }

        // Collect results from all threads
        for (thread_scanners) |*scanner| {
            for (scanner.paths.items) |full_path| {
                // Convert to relative path
                if (full_path.len > self.root_len) {
                    const rel_path = full_path[self.root_len..];
                    try index.addPath(rel_path);
                }
            }
            scanner.deinit();
        }
    }

    fn workerThread(scanner: *ThreadScanner) void {
        // Process local queue depth-first
        while (scanner.local_queue.popOrNull()) |item| {
            scanner.processDirectory(item.path, item.depth);
        }
    }

    fn scanSingleThreaded(self: *ParallelScanner, index: *PathIndex, root: []const u8) !void {
        var scanner = ThreadScanner.init(self.allocator, self.config);
        defer scanner.deinit();

        scanner.local_queue.append(.{ .path = root, .depth = 0 }) catch return;

        while (scanner.local_queue.popOrNull()) |item| {
            scanner.processDirectory(item.path, item.depth);
        }

        for (scanner.paths.items) |full_path| {
            if (full_path.len > self.root_len) {
                const rel_path = full_path[self.root_len..];
                try index.addPath(rel_path);
            }
        }
    }

    fn shouldIgnoreName(self: *ParallelScanner, name: []const u8) bool {
        for (self.config.ignore_patterns) |pattern| {
            if (std.mem.eql(u8, name, pattern)) return true;
        }
        return false;
    }

    fn getThreadCount() usize {
        // Use number of CPU cores, but cap at reasonable max
        const cpus = std.Thread.getCpuCount() catch 4;
        return @min(cpus, 16);
    }
};

test "parallel scanner basic" {
    const allocator = std.testing.allocator;
    var index = PathIndex.init(allocator);
    defer index.deinit();

    var scanner = ParallelScanner.init(allocator, .{});
    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    try scanner.scan(&index, path);
    try std.testing.expect(index.count() > 0);
}
