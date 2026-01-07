const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PathEntry = struct {
    path: []const u8,
    path_lower: []const u8,
    basename_start: u16,
    depth: u8,
};

pub const PathIndex = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(PathEntry),

    pub fn init(allocator: Allocator) PathIndex {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.ArrayList(PathEntry).init(allocator),
        };
    }

    pub fn deinit(self: *PathIndex) void {
        self.entries.deinit();
        self.arena.deinit();
    }

    pub fn addPath(self: *PathIndex, path: []const u8) !void {
        const arena_alloc = self.arena.allocator();

        const path_copy = try arena_alloc.dupe(u8, path);

        const path_lower = try arena_alloc.alloc(u8, path.len);
        for (path, 0..) |c, i| {
            path_lower[i] = std.ascii.toLower(c);
        }

        var depth: u8 = 0;
        var basename_start: u16 = 0;
        for (path, 0..) |c, i| {
            if (c == '/' or c == '\\') {
                depth +|= 1;
                basename_start = @intCast(i + 1);
            }
        }

        try self.entries.append(.{
            .path = path_copy,
            .path_lower = path_lower,
            .basename_start = basename_start,
            .depth = depth,
        });
    }

    pub fn removePath(self: *PathIndex, path: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].path, path)) {
                _ = self.entries.swapRemove(i);
                // Don't increment i, check the swapped element
            } else {
                i += 1;
            }
        }
    }

    pub fn removePathsWithPrefix(self: *PathIndex, prefix: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.startsWith(u8, self.entries.items[i].path, prefix)) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clear(self: *PathIndex) void {
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn count(self: *const PathIndex) usize {
        return self.entries.items.len;
    }
};
