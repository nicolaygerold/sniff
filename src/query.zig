const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Query = struct {
    raw: []const u8,
    lower: []const u8,
    has_path_sep: bool,

    pub fn init(allocator: Allocator, raw: []const u8) !Query {
        const lower = try allocator.alloc(u8, raw.len);
        for (raw, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }

        const has_path_sep = std.mem.indexOfAny(u8, raw, "/\\") != null;

        return .{
            .raw = raw,
            .lower = lower,
            .has_path_sep = has_path_sep,
        };
    }

    pub fn deinit(self: *Query, allocator: Allocator) void {
        allocator.free(self.lower);
    }
};

test "Query basic" {
    const allocator = std.testing.allocator;

    var query = try Query.init(allocator, "Main.zig");
    defer query.deinit(allocator);

    try std.testing.expectEqualStrings("Main.zig", query.raw);
    try std.testing.expectEqualStrings("main.zig", query.lower);
    try std.testing.expectEqual(false, query.has_path_sep);
}

test "Query with path separator" {
    const allocator = std.testing.allocator;

    var query = try Query.init(allocator, "src/main");
    defer query.deinit(allocator);

    try std.testing.expectEqual(true, query.has_path_sep);
}

test "Query with backslash" {
    const allocator = std.testing.allocator;

    var query = try Query.init(allocator, "src\\main");
    defer query.deinit(allocator);

    try std.testing.expectEqual(true, query.has_path_sep);
}
