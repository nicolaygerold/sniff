const std = @import("std");
const PathIndex = @import("index.zig").PathIndex;
const GitIgnore = @import("gitignore.zig").GitIgnore;

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
    gitignore: GitIgnore,
    gitignore_stack: std.ArrayList(GitIgnoreEntry),

    const GitIgnoreEntry = struct {
        depth: usize,
        pattern_count: usize, // Number of patterns added at this level
    };

    pub fn init(index: *PathIndex, config: ScanConfig) Scanner {
        return .{
            .index = index,
            .config = config,
            .root_len = 0,
            .gitignore = GitIgnore.init(index.arena.allocator()),
            .gitignore_stack = std.ArrayList(GitIgnoreEntry).init(index.arena.allocator()),
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.gitignore.deinit();
        self.gitignore_stack.deinit();
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
            try self.gitignore_stack.append(.{
                .depth = 0,
                .pattern_count = self.gitignore.patterns.items.len,
            });
        }

        try self.scanDir(dir, "", 0);
    }

    fn scanDir(self: *Scanner, dir: std.fs.Dir, prefix: []const u8, depth: usize) !void {
        if (depth > self.config.max_depth) return;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const is_dir = entry.kind == .directory;
            const name = entry.name;

            // Build relative path
            const rel_path = if (prefix.len == 0)
                try self.index.arena.allocator().dupe(u8, name)
            else
                try std.fmt.allocPrint(self.index.arena.allocator(), "{s}/{s}", .{ prefix, name });

            // Check if should ignore
            if (self.shouldIgnore(rel_path, name, is_dir)) {
                continue;
            }

            if (is_dir) {
                // Recurse into directory
                var sub_dir = dir.openDir(name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();

                // Load nested .gitignore if present
                const prev_pattern_count = self.gitignore.patterns.items.len;
                if (self.config.respect_gitignore) {
                    self.gitignore.loadFile(sub_dir) catch {};
                    const new_count = self.gitignore.patterns.items.len;
                    if (new_count > prev_pattern_count) {
                        try self.gitignore_stack.append(.{
                            .depth = depth + 1,
                            .pattern_count = new_count,
                        });
                    }
                }

                try self.scanDir(sub_dir, rel_path, depth + 1);

                // Pop gitignore patterns when leaving directory
                if (self.config.respect_gitignore) {
                    while (self.gitignore_stack.items.len > 0) {
                        const last = self.gitignore_stack.items[self.gitignore_stack.items.len - 1];
                        if (last.depth > depth) {
                            // Remove patterns added in deeper directories
                            self.gitignore.patterns.shrinkRetainingCapacity(
                                if (self.gitignore_stack.items.len > 1)
                                    self.gitignore_stack.items[self.gitignore_stack.items.len - 2].pattern_count
                                else
                                    0,
                            );
                            _ = self.gitignore_stack.pop();
                        } else {
                            break;
                        }
                    }
                }
            } else {
                // Add file to index
                try self.index.addPath(rel_path);
            }
        }
    }

    fn shouldIgnore(self: *Scanner, path: []const u8, name: []const u8, is_dir: bool) bool {
        // Check hidden files
        if (self.config.ignore_hidden and name.len > 0 and name[0] == '.') {
            return true;
        }

        // Check hardcoded ignore patterns
        for (self.config.ignore_patterns) |pattern| {
            if (std.mem.eql(u8, name, pattern)) {
                return true;
            }
        }

        // Check gitignore
        if (self.config.respect_gitignore) {
            if (self.gitignore.isIgnored(path, is_dir)) {
                return true;
            }
        }

        return false;
    }
};
