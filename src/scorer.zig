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

    // Early termination threshold - if we can't possibly beat this, skip
    pub const MIN_VIABLE: i32 = 0;
};

pub const MatchResult = struct {
    score: i32,
    positions: std.BoundedArray(u16, Score.MAX_LEN),
};

/// Fast check if pattern characters exist in text in order
/// Optimized with early exit on first character mismatch
pub fn isPatternInText(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len > text.len) return false;

    // Fast path: check first character exists
    const first_lower = std.ascii.toLower(pattern[0]);
    var found_first = false;
    var start_idx: usize = 0;
    for (text, 0..) |c, i| {
        if (std.ascii.toLower(c) == first_lower) {
            found_first = true;
            start_idx = i + 1;
            break;
        }
    }
    if (!found_first) return false;

    // Check remaining characters
    var text_idx = start_idx;
    for (pattern[1..]) |p| {
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
    // Use smaller matrices when possible - most queries are short
    matrix: [Score.MAX_LEN][Score.MAX_LEN]i32,
    from: [Score.MAX_LEN][Score.MAX_LEN]u16,
    // Track best score at each query position for pruning
    best_at_row: [Score.MAX_LEN]i32,

    pub fn init() Scorer {
        return Scorer{
            .matrix = [_][Score.MAX_LEN]i32{[_]i32{0} ** Score.MAX_LEN} ** Score.MAX_LEN,
            .from = [_][Score.MAX_LEN]u16{[_]u16{0} ** Score.MAX_LEN} ** Score.MAX_LEN,
            .best_at_row = [_]i32{0} ** Score.MAX_LEN,
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

    /// Score with early termination if result can't beat threshold
    pub fn scoreWithThreshold(
        self: *Scorer,
        query: []const u8,
        query_lower: []const u8,
        path: []const u8,
        path_lower: []const u8,
        threshold: i32,
    ) ?MatchResult {
        if (query.len == 0) return null;
        if (path.len == 0) return null;
        if (query.len > path.len) return null;

        const q = if (query.len > Score.MAX_LEN) query[0..Score.MAX_LEN] else query;
        const ql = if (query_lower.len > Score.MAX_LEN) query_lower[0..Score.MAX_LEN] else query_lower;
        const p = if (path.len > Score.MAX_LEN) path[0..Score.MAX_LEN] else path;
        const pl = if (path_lower.len > Score.MAX_LEN) path_lower[0..Score.MAX_LEN] else path_lower;

        // Early exit: maximum possible score (all bonuses) can't beat threshold
        const max_possible = @as(i32, @intCast(q.len)) * (Score.BASE_MATCH + Score.EXACT_CASE + Score.START_OF_STRING + Score.CONSECUTIVE_FIRST3);
        if (max_possible < threshold) return null;

        if (!isPatternInText(q, p)) return null;

        return self.computeScoreWithThreshold(q, ql, p, pl, threshold);
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
        return self.computeScoreWithThreshold(query, query_lower, path, path_lower, std.math.minInt(i32) / 2);
    }

    fn computeScoreWithThreshold(
        self: *Scorer,
        query: []const u8,
        query_lower: []const u8,
        path: []const u8,
        path_lower: []const u8,
        threshold: i32,
    ) MatchResult {
        const q_len = query.len;
        const p_len = path.len;
        const sentinel: i32 = std.math.minInt(i32) / 2;

        // Initialize only the cells we'll use
        for (0..q_len) |i| {
            self.best_at_row[i] = sentinel;
            for (0..p_len) |j| {
                self.matrix[i][j] = sentinel;
            }
        }

        // First row: find all positions where first query char matches
        for (0..p_len) |j| {
            if (query_lower[0] == path_lower[j]) {
                var s = Score.BASE_MATCH;
                s += getPositionBonus(path, j);
                if (query[0] == path[j]) s += Score.EXACT_CASE;
                self.matrix[0][j] = s;
                self.from[0][j] = @intCast(j);
                if (s > self.best_at_row[0]) self.best_at_row[0] = s;
            }
        }

        // Early exit if first row can't produce good enough score
        if (q_len == 1) {
            // Single char query - find best and return
            var best_j: usize = 0;
            var best_s: i32 = sentinel;
            for (0..p_len) |j| {
                if (self.matrix[0][j] > best_s) {
                    best_s = self.matrix[0][j];
                    best_j = j;
                }
            }
            var positions = std.BoundedArray(u16, Score.MAX_LEN){};
            positions.append(@intCast(best_j)) catch {};
            return MatchResult{ .score = best_s, .positions = positions };
        }

        // Fill rest of matrix with optimizations
        for (1..q_len) |i| {
            const remaining = q_len - i;
            // Maximum additional score we could get from remaining chars
            const max_remaining = @as(i32, @intCast(remaining)) * (Score.BASE_MATCH + Score.EXACT_CASE + Score.START_OF_STRING + Score.CONSECUTIVE_FIRST3);

            for (i..p_len) |j| {
                if (query_lower[i] != path_lower[j]) continue;

                // Find best previous position - only look at valid cells
                var best_score: i32 = sentinel;
                var best_from: u16 = 0;

                // Optimization: start from j-1 and work backwards
                // Most matches come from nearby positions
                var k = j;
                while (k > 0) {
                    k -= 1;
                    const prev = self.matrix[i - 1][k];
                    if (prev == sentinel) continue;

                    var candidate = prev;

                    // Consecutive bonus
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

                    // Early break: if we found a consecutive match and it's the best possible
                    // from this row, stop searching
                    if (k + 1 == j and candidate == self.best_at_row[i - 1] + Score.CONSECUTIVE_FIRST3) {
                        break;
                    }
                }

                if (best_score > sentinel) {
                    var s = Score.BASE_MATCH;
                    s += getPositionBonus(path, j);
                    if (query[i] == path[j]) s += Score.EXACT_CASE;

                    const final_score = best_score + s;
                    self.matrix[i][j] = final_score;
                    self.from[i][j] = best_from;
                    if (final_score > self.best_at_row[i]) self.best_at_row[i] = final_score;
                }
            }

            // Early termination: if best score at this row + max remaining can't beat threshold
            if (self.best_at_row[i] + max_remaining < threshold) {
                // Return a minimal result that won't be selected
                const positions = std.BoundedArray(u16, Score.MAX_LEN){};
                return MatchResult{ .score = sentinel, .positions = positions };
            }
        }

        // Find best ending position
        var best_end: usize = 0;
        var best_final_score: i32 = sentinel;

        for (q_len - 1..p_len) |j| {
            if (self.matrix[q_len - 1][j] > best_final_score) {
                best_final_score = self.matrix[q_len - 1][j];
                best_end = j;
            }
        }

        // Backtrack to find positions
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

test "scorer with threshold" {
    var s = Scorer.init();

    // With high threshold, some results may be filtered
    const result = s.scoreWithThreshold("a", "a", "abc", "abc", 100);
    // Score should be around 10 (START_OF_STRING + BASE_MATCH + EXACT_CASE)
    try std.testing.expect(result == null);

    // With low threshold, should get result
    const result2 = s.scoreWithThreshold("a", "a", "abc", "abc", 0);
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.?.score > 0);
}
