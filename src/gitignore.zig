const std = @import("std");
const Allocator = std.mem.Allocator;

/// A compiled gitignore pattern
pub const Pattern = struct {
    pattern: []const u8,
    is_negation: bool,
    is_dir_only: bool,
    is_anchored: bool,

    pub fn matches(self: Pattern, path: []const u8, is_dir: bool) bool {
        if (self.is_dir_only and !is_dir) return false;

        if (self.is_anchored) {
            return globMatch(self.pattern, path);
        } else {
            // Match against basename or any path suffix
            if (globMatch(self.pattern, path)) return true;
            if (globMatch(self.pattern, basename(path))) return true;

            // Also try matching after each /
            var i: usize = 0;
            while (i < path.len) : (i += 1) {
                if (path[i] == '/') {
                    if (globMatch(self.pattern, path[i + 1 ..])) return true;
                }
            }
            return false;
        }
    }
};

/// A set of gitignore rules
pub const GitIgnore = struct {
    patterns: std.ArrayList(Pattern),
    allocator: Allocator,

    pub fn init(allocator: Allocator) GitIgnore {
        return .{
            .patterns = std.ArrayList(Pattern).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitIgnore) void {
        for (self.patterns.items) |p| {
            self.allocator.free(p.pattern);
        }
        self.patterns.deinit();
    }

    pub fn loadFile(self: *GitIgnore, dir: std.fs.Dir) !void {
        const file = dir.openFile(".gitignore", .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        var buf: [8192]u8 = undefined;
        const bytes_read = file.read(&buf) catch return;

        var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
        while (lines.next()) |raw_line| {
            self.parseLine(raw_line) catch continue;
        }
    }

    pub fn parseLine(self: *GitIgnore, raw_line: []const u8) !void {
        var line = std.mem.trim(u8, raw_line, "\r \t");

        if (line.len == 0 or line[0] == '#') return;

        var is_negation = false;
        if (line[0] == '!') {
            is_negation = true;
            line = line[1..];
            if (line.len == 0) return;
        }

        var is_dir_only = false;
        if (line[line.len - 1] == '/') {
            is_dir_only = true;
            line = line[0 .. line.len - 1];
            if (line.len == 0) return;
        }

        var is_anchored = false;
        if (line[0] == '/') {
            is_anchored = true;
            line = line[1..];
            if (line.len == 0) return;
        }

        // Pattern with / is anchored
        if (!is_anchored) {
            for (line) |c| {
                if (c == '/') {
                    is_anchored = true;
                    break;
                }
            }
        }

        const pattern_copy = try self.allocator.dupe(u8, line);
        try self.patterns.append(.{
            .pattern = pattern_copy,
            .is_negation = is_negation,
            .is_dir_only = is_dir_only,
            .is_anchored = is_anchored,
        });
    }

    pub fn isIgnored(self: *const GitIgnore, path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.patterns.items) |pattern| {
            if (pattern.matches(path, is_dir)) {
                ignored = !pattern.is_negation;
            }
        }
        return ignored;
    }
};

/// Simple glob matching - iterative, no recursion
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];

            if (pc == '*') {
                // Check for **
                if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                    // ** matches everything including /
                    pi += 2;
                    if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                    if (pi >= pattern.len) return true; // ** at end
                    // Try to find where rest of pattern matches
                    while (ti <= text.len) {
                        if (globMatch(pattern[pi..], text[ti..])) return true;
                        if (ti >= text.len) break;
                        ti += 1;
                    }
                    return false;
                }

                // Single * - save position for backtracking
                star_p = pi;
                star_t = ti;
                pi += 1;
                continue;
            }

            if (ti < text.len) {
                if (pc == '?') {
                    if (text[ti] != '/') {
                        pi += 1;
                        ti += 1;
                        continue;
                    }
                } else if (pc == text[ti]) {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            }
        }

        // Mismatch - try backtracking to last *
        if (star_p) |sp| {
            // * cannot match /
            if (star_t < text.len and text[star_t] != '/') {
                star_t += 1;
                ti = star_t;
                pi = sp + 1;
                continue;
            }
        }

        return false;
    }

    return true;
}

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

test "glob matching" {
    const testing = std.testing;

    try testing.expect(globMatch("foo", "foo"));
    try testing.expect(!globMatch("foo", "bar"));
    try testing.expect(globMatch("*.txt", "file.txt"));
    try testing.expect(globMatch("foo*", "foobar"));
    try testing.expect(!globMatch("*.txt", "dir/file.txt"));
    try testing.expect(globMatch("**/foo", "foo"));
    try testing.expect(globMatch("**/foo", "bar/foo"));
}

test "gitignore patterns" {
    const testing = std.testing;
    var gi = GitIgnore.init(testing.allocator);
    defer gi.deinit();

    try gi.parseLine("*.log");
    try gi.parseLine("build/");
    try gi.parseLine("!important.log");

    try testing.expect(gi.isIgnored("test.log", false));
    try testing.expect(!gi.isIgnored("important.log", false));
    try testing.expect(gi.isIgnored("build", true));
    try testing.expect(!gi.isIgnored("build", false));
}
