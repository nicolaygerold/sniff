const std = @import("std");
const PathEntry = @import("index.zig").PathEntry;

pub const SearchResult = struct {
    entry: *const PathEntry,
    score: i32,
    positions: []const u16,
};

pub const ResultHeap = struct {
    pub const MAX_RESULTS = 512;

    items: std.BoundedArray(SearchResult, MAX_RESULTS),
    min_score: i32,

    pub fn init() ResultHeap {
        return .{
            .items = .{},
            .min_score = std.math.minInt(i32),
        };
    }

    pub fn insert(self: *ResultHeap, result: SearchResult) void {
        if (self.items.len == MAX_RESULTS and result.score <= self.min_score) {
            return;
        }

        if (self.items.len < MAX_RESULTS) {
            self.items.append(result) catch {};
            self.updateMinScore();
        } else {
            const min_idx = self.findMinIndex();
            self.items.buffer[min_idx] = result;
            self.updateMinScore();
        }
    }

    pub fn getSorted(self: *ResultHeap) []SearchResult {
        std.sort.pdq(SearchResult, self.items.slice(), {}, compareFn);
        return self.items.slice();
    }

    fn updateMinScore(self: *ResultHeap) void {
        if (self.items.len == 0) {
            self.min_score = std.math.minInt(i32);
            return;
        }
        self.min_score = self.items.buffer[self.findMinIndex()].score;
    }

    fn findMinIndex(self: *ResultHeap) usize {
        if (self.items.len == 0) return 0;

        var min_idx: usize = 0;
        var min_score = self.items.buffer[0].score;

        for (self.items.slice()[1..], 1..) |item, i| {
            if (item.score < min_score) {
                min_score = item.score;
                min_idx = i;
            }
        }
        return min_idx;
    }

    fn compareFn(_: void, a: SearchResult, b: SearchResult) bool {
        if (a.score != b.score) return a.score > b.score;
        if (a.entry.depth != b.entry.depth) return a.entry.depth < b.entry.depth;
        const a_base = a.entry.path.len - a.entry.basename_start;
        const b_base = b.entry.path.len - b.entry.basename_start;
        if (a_base != b_base) return a_base < b_base;
        return std.mem.lessThan(u8, a.entry.path, b.entry.path);
    }
};
