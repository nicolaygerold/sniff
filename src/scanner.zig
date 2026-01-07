const std = @import("std");
const PathIndex = @import("index.zig").PathIndex;
const FastGitIgnore = @import("fast_gitignore.zig").FastGitIgnore;

pub const ScanConfig = struct {
    max_depth: usize = 20,
    ignore_hidden: bool = true,
    respect_gitignore: bool = true,
    ignore_patterns: []const []const u8 = &.{
        "node_modules",
        ".git",
        "target",
        "build",
        "__pycache__",
        ".venv",
        "vendor",
        "dist",
        ".zig-cache",
        "zig-out",
    },
};

pub const Scanner = struct {
    index: *PathIndex,
    config: ScanConfig,
    root_len: usize,
    gitignore: FastGitIgnore,

    pub fn init(index: *PathIndex, config: ScanConfig) Scanner {
        return .{
            .index = index,
            .config = config,
            .root_len = 0,
            .gitignore = FastGitIgnore.init(index.arena.allocator()),
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.gitignore.deinit();
    }

    pub fn scan(self: *Scanner, root: []const u8) !void {
        self.root_len = root.len;
        if (self.root_len > 0 and root[self.root_len - 1] != '/' and root[self.root_len - 1] != '\\') {
            self.root_len += 1;
        }

        var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
        defer dir.close();

        // Load root .gitignore
        if (self.config.respect_gitignore) {
            try self.gitignore.loadFile(dir);
            try self.gitignore.pushSnapshot(0);
        }

        try self.scanDir(dir, "", 0);
    }

    pub fn scanDir(self: *Scanner, dir: std.fs.Dir, prefix: []const u8, depth: usize) !void {
        if (depth > self.config.max_depth) return;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const is_dir = entry.kind == .directory;
            const name = entry.name;

            // Fast path: check hidden files first (most common filter)
            if (self.config.ignore_hidden and name.len > 0 and name[0] == '.') {
                continue;
            }

            // Fast path: hardcoded ignore patterns
            if (self.shouldIgnoreName(name)) {
                continue;
            }

            // AGGRESSIVE DIRECTORY PRUNING - key optimization
            // Check if we should skip this entire directory BEFORE recursing
            if (is_dir and self.config.respect_gitignore) {
                if (self.gitignore.shouldSkipDir(name)) {
                    continue;
                }
            }

            // Build relative path (only if we're not skipping)
            const rel_path = if (prefix.len == 0)
                try self.index.arena.allocator().dupe(u8, name)
            else
                try std.fmt.allocPrint(self.index.arena.allocator(), "{s}/{s}", .{ prefix, name });

            // Check gitignore for files (dirs already checked above for pruning)
            if (self.config.respect_gitignore and !is_dir) {
                if (self.gitignore.isFileIgnored(name, rel_path, false)) {
                    continue;
                }
            }

            if (is_dir) {
                // Recurse into directory
                var sub_dir = dir.openDir(name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();

                // Load nested .gitignore if present
                if (self.config.respect_gitignore) {
                    try self.gitignore.pushSnapshot(depth + 1);
                    self.gitignore.loadFile(sub_dir) catch {};
                }

                try self.scanDir(sub_dir, rel_path, depth + 1);

                // Pop gitignore patterns when leaving directory
                if (self.config.respect_gitignore) {
                    self.gitignore.popToDepth(depth);
                }
            } else {
                // Add file to index
                try self.index.addPath(rel_path);
            }
        }
    }

    fn shouldIgnoreName(self: *Scanner, name: []const u8) bool {
        for (self.config.ignore_patterns) |pattern| {
            if (std.mem.eql(u8, name, pattern)) {
                return true;
            }
        }
        return false;
    }
};
