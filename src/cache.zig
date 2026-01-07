const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const PathIndex = @import("index.zig").PathIndex;

pub const INDEX_MAGIC: u32 = 0x534E4946; // "SNIF"
pub const INDEX_VERSION: u16 = 1;

pub const Cache = struct {
    allocator: Allocator,
    cache_dir: []const u8,

    pub fn init(allocator: Allocator) !Cache {
        const dir = try getCacheDir(allocator);

        // Ensure cache directory exists
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        return .{
            .allocator = allocator,
            .cache_dir = dir,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.cache_dir);
    }

    fn getCacheDir(allocator: Allocator) ![]const u8 {
        switch (builtin.os.tag) {
            .macos => {
                const home = std.posix.getenv("HOME") orelse return error.NoHome;
                return std.fmt.allocPrint(allocator, "{s}/Library/Caches/sniff", .{home});
            },
            .linux => {
                if (std.posix.getenv("XDG_CACHE_HOME")) |xdg| {
                    return std.fmt.allocPrint(allocator, "{s}/sniff", .{xdg});
                }
                const home = std.posix.getenv("HOME") orelse return error.NoHome;
                return std.fmt.allocPrint(allocator, "{s}/.cache/sniff", .{home});
            },
            .windows => {
                const local = std.posix.getenv("LOCALAPPDATA") orelse return error.NoAppData;
                return std.fmt.allocPrint(allocator, "{s}\\sniff", .{local});
            },
            else => return error.UnsupportedOS,
        }
    }

    pub fn getIndexPath(self: *const Cache, root_path: []const u8) ![]const u8 {
        const hash = std.hash.Wyhash.hash(0, root_path);
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        return std.fmt.allocPrint(self.allocator, "{s}{s}{x}.idx", .{ self.cache_dir, sep, hash });
    }

    pub fn saveIndex(self: *const Cache, index: *const PathIndex, root_path: []const u8) !void {
        const index_path = try self.getIndexPath(root_path);
        defer self.allocator.free(index_path);

        const file = try std.fs.createFileAbsolute(index_path, .{});
        defer file.close();

        var buffered = std.io.bufferedWriter(file.writer());
        const writer = buffered.writer();

        // Header
        try writer.writeInt(u32, INDEX_MAGIC, .little);
        try writer.writeInt(u16, INDEX_VERSION, .little);

        // Root path
        try writer.writeInt(u16, @intCast(root_path.len), .little);
        try writer.writeAll(root_path);

        // Index timestamp
        try writer.writeInt(i64, std.time.timestamp(), .little);

        // Entry count
        try writer.writeInt(u32, @intCast(index.entries.items.len), .little);

        // Entries
        for (index.entries.items) |entry| {
            try writer.writeInt(u16, @intCast(entry.path.len), .little);
            try writer.writeAll(entry.path);
        }

        try buffered.flush();
    }

    pub fn loadIndex(self: *const Cache, index: *PathIndex, root_path: []const u8) !i64 {
        const index_path = try self.getIndexPath(root_path);
        defer self.allocator.free(index_path);

        const file = std.fs.openFileAbsolute(index_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return error.IndexNotFound,
            else => return e,
        };
        defer file.close();

        var buffered = std.io.bufferedReader(file.reader());
        const reader = buffered.reader();

        // Validate header
        const magic = try reader.readInt(u32, .little);
        if (magic != INDEX_MAGIC) return error.InvalidIndex;

        const version = try reader.readInt(u16, .little);
        if (version != INDEX_VERSION) return error.UnsupportedVersion;

        // Read and validate root path
        const stored_root_len = try reader.readInt(u16, .little);
        const stored_root = try self.allocator.alloc(u8, stored_root_len);
        defer self.allocator.free(stored_root);
        try reader.readNoEof(stored_root);

        if (!std.mem.eql(u8, stored_root, root_path)) {
            return error.RootMismatch;
        }

        // Read timestamp
        const index_time = try reader.readInt(i64, .little);

        // Read entries
        const entry_count = try reader.readInt(u32, .little);

        index.clear();
        try index.entries.ensureTotalCapacity(entry_count);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const path_len = try reader.readInt(u16, .little);
            const path = try index.arena.allocator().alloc(u8, path_len);
            try reader.readNoEof(path);
            try index.addPath(path);
        }

        return index_time;
    }

    pub fn hasValidIndex(self: *const Cache, root_path: []const u8) bool {
        const index_path = self.getIndexPath(root_path) catch return false;
        defer self.allocator.free(index_path);

        const file = std.fs.openFileAbsolute(index_path, .{}) catch return false;
        defer file.close();

        var reader = file.reader();

        const magic = reader.readInt(u32, .little) catch return false;
        if (magic != INDEX_MAGIC) return false;

        const version = reader.readInt(u16, .little) catch return false;
        if (version != INDEX_VERSION) return false;

        return true;
    }

    pub fn deleteIndex(self: *const Cache, root_path: []const u8) !void {
        const index_path = try self.getIndexPath(root_path);
        defer self.allocator.free(index_path);

        std.fs.deleteFileAbsolute(index_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
};

test "cache directory creation" {
    const allocator = std.testing.allocator;

    var cache = try Cache.init(allocator);
    defer cache.deinit();

    // Verify cache dir was created
    var dir = try std.fs.openDirAbsolute(cache.cache_dir, .{});
    dir.close();
}

test "index path generation" {
    const allocator = std.testing.allocator;

    var cache = try Cache.init(allocator);
    defer cache.deinit();

    const path1 = try cache.getIndexPath("/Users/test/project1");
    defer allocator.free(path1);

    const path2 = try cache.getIndexPath("/Users/test/project2");
    defer allocator.free(path2);

    // Different roots should produce different paths
    try std.testing.expect(!std.mem.eql(u8, path1, path2));

    // Same root should produce same path
    const path1_again = try cache.getIndexPath("/Users/test/project1");
    defer allocator.free(path1_again);
    try std.testing.expectEqualStrings(path1, path1_again);
}
