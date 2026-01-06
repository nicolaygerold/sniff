const std = @import("std");

pub const Score = struct {
    pub const START_OF_STRING: i32 = 8;
    pub const AFTER_SEPARATOR: i32 = 5;
    pub const AFTER_DOT: i32 = 4;
    pub const CAMEL_CASE: i32 = 2;

    pub const CONSECUTIVE_FIRST3: i32 = 6;
    pub const CONSECUTIVE_REST: i32 = 3;

    pub const EXACT_CASE: i32 = 1;
    pub const BASE_MATCH: i32 = 1;

    pub const MAX_LEN: usize = 128;
};

pub const MatchResult = struct {
    score: i32,
    positions: std.BoundedArray(u16, Score.MAX_LEN),
};

pub fn isPatternInText(pattern: []const u8, text: []const u8) bool {
    var text_idx: usize = 0;
    for (pattern) |p| {
        const p_lower = std.ascii.toLower(p);
        while (text_idx < text.len) : (text_idx += 1) {
            if (std.ascii.toLower(text[text_idx]) == p_lower) {
                text_idx += 1;
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

pub const Scorer = struct {
    matrix: [Score.MAX_LEN][Score.MAX_LEN]i32,
    from: [Score.MAX_LEN][Score.MAX_LEN]u16,

    pub fn init() Scorer {
        return Scorer{
            .matrix = [_][Score.MAX_LEN]i32{[_]i32{0} ** Score.MAX_LEN} ** Score.MAX_LEN,
            .from = [_][Score.MAX_LEN]u16{[_]u16{0} ** Score.MAX_LEN} ** Score.MAX_LEN,
        };
    }

    pub fn score(
        self: *Scorer,
        query: []const u8,
        query_lower: []const u8,
        path: []const u8,
        path_lower: []const u8,
    ) ?MatchResult {
        if (query.len == 0) return null;
        if (path.len == 0) return null;
        if (query.len > path.len) return null;

        const q = if (query.len > Score.MAX_LEN) query[0..Score.MAX_LEN] else query;
        const ql = if (query_lower.len > Score.MAX_LEN) query_lower[0..Score.MAX_LEN] else query_lower;
        const p = if (path.len > Score.MAX_LEN) path[0..Score.MAX_LEN] else path;
        const pl = if (path_lower.len > Score.MAX_LEN) path_lower[0..Score.MAX_LEN] else path_lower;

        if (!isPatternInText(q, p)) return null;

        return self.computeScore(q, ql, p, pl);
    }

    fn getPositionBonus(path: []const u8, pos: usize) i32 {
        if (pos == 0) return Score.START_OF_STRING;

        const prev = path[pos - 1];
        const curr = path[pos];

        if (prev == '/' or prev == '\\' or prev == '-' or prev == '_') {
            return Score.AFTER_SEPARATOR;
        }
        if (prev == '.') {
            return Score.AFTER_DOT;
        }
        if (std.ascii.isLower(prev) and std.ascii.isUpper(curr)) {
            return Score.CAMEL_CASE;
        }

        return 0;
    }

    fn computeScore(
        self: *Scorer,
        query: []const u8,
        query_lower: []const u8,
        path: []const u8,
        path_lower: []const u8,
    ) MatchResult {
        const q_len = query.len;
        const p_len = path.len;

        for (0..q_len) |i| {
            for (0..p_len) |j| {
                self.matrix[i][j] = std.math.minInt(i32) / 2;
                self.from[i][j] = 0;
            }
        }

        for (0..p_len) |j| {
            if (query_lower[0] == path_lower[j]) {
                var s = Score.BASE_MATCH;
                s += getPositionBonus(path, j);
                if (query[0] == path[j]) s += Score.EXACT_CASE;
                self.matrix[0][j] = s;
                self.from[0][j] = @intCast(j);
            }
        }

        for (1..q_len) |i| {
            for (i..p_len) |j| {
                if (query_lower[i] != path_lower[j]) continue;

                var best_score: i32 = std.math.minInt(i32) / 2;
                var best_from: u16 = 0;

                for (0..j) |k| {
                    if (self.matrix[i - 1][k] == std.math.minInt(i32) / 2) continue;

                    var candidate = self.matrix[i - 1][k];

                    if (k + 1 == j) {
                        const consecutive_len = self.getConsecutiveLen(i - 1, k);
                        if (consecutive_len < 3) {
                            candidate += Score.CONSECUTIVE_FIRST3;
                        } else {
                            candidate += Score.CONSECUTIVE_REST;
                        }
                    }

                    if (candidate > best_score) {
                        best_score = candidate;
                        best_from = @intCast(k);
                    }
                }

                if (best_score > std.math.minInt(i32) / 2) {
                    var s = Score.BASE_MATCH;
                    s += getPositionBonus(path, j);
                    if (query[i] == path[j]) s += Score.EXACT_CASE;

                    self.matrix[i][j] = best_score + s;
                    self.from[i][j] = best_from;
                }
            }
        }

        var best_end: usize = 0;
        var best_final_score: i32 = std.math.minInt(i32) / 2;

        for (q_len - 1..p_len) |j| {
            if (self.matrix[q_len - 1][j] > best_final_score) {
                best_final_score = self.matrix[q_len - 1][j];
                best_end = j;
            }
        }

        var positions = std.BoundedArray(u16, Score.MAX_LEN){};
        var pos_stack: [Score.MAX_LEN]u16 = undefined;
        var stack_len: usize = 0;

        var curr_j = best_end;
        var curr_i = q_len;
        while (curr_i > 0) : (curr_i -= 1) {
            pos_stack[stack_len] = @intCast(curr_j);
            stack_len += 1;
            if (curr_i > 1) {
                curr_j = self.from[curr_i - 1][curr_j];
            }
        }

        while (stack_len > 0) {
            stack_len -= 1;
            positions.append(pos_stack[stack_len]) catch break;
        }

        return MatchResult{
            .score = best_final_score,
            .positions = positions,
        };
    }

    fn getConsecutiveLen(self: *Scorer, query_idx: usize, path_idx: usize) usize {
        var len: usize = 1;
        var qi = query_idx;
        var pi = path_idx;

        while (qi > 0 and pi > 0) {
            if (self.from[qi][pi] == pi - 1) {
                len += 1;
                qi -= 1;
                pi -= 1;
            } else {
                break;
            }
        }

        return len;
    }
};

test "isPatternInText" {
    try std.testing.expect(isPatternInText("abc", "aXbXc"));
    try std.testing.expect(isPatternInText("abc", "abc"));
    try std.testing.expect(isPatternInText("ABC", "abc"));
    try std.testing.expect(!isPatternInText("abc", "ab"));
    try std.testing.expect(!isPatternInText("abc", "acb"));
    try std.testing.expect(isPatternInText("", "anything"));
}

test "scorer basic" {
    var s = Scorer.init();

    const result = s.score("abc", "abc", "abc", "abc");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.score > 0);
    try std.testing.expectEqual(@as(usize, 3), result.?.positions.len);
}

test "scorer no match" {
    var s = Scorer.init();

    const result = s.score("xyz", "xyz", "abc", "abc");
    try std.testing.expect(result == null);
}

test "scorer position bonus" {
    var s = Scorer.init();

    const start_result = s.score("a", "a", "abc", "abc");
    const mid_result = s.score("b", "b", "abc", "abc");

    try std.testing.expect(start_result.?.score > mid_result.?.score);
}

test "scorer separator bonus" {
    var s = Scorer.init();

    const sep_result = s.score("b", "b", "a/b", "a/b");
    const no_sep_result = s.score("b", "b", "ab", "ab");

    try std.testing.expect(sep_result.?.score > no_sep_result.?.score);
}

test "scorer camelCase bonus" {
    var s = Scorer.init();

    const camel_result = s.score("B", "b", "aB", "ab");
    const no_camel_result = s.score("b", "b", "ab", "ab");

    try std.testing.expect(camel_result.?.score > no_camel_result.?.score);
}

test "scorer consecutive bonus" {
    var s = Scorer.init();

    const consec_result = s.score("ab", "ab", "ab", "ab");
    const spread_result = s.score("ab", "ab", "aXb", "axb");

    try std.testing.expect(consec_result.?.score > spread_result.?.score);
}
