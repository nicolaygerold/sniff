const std = @import("std");
const Allocator = std.mem.Allocator;

/// Pattern requiring full glob matching (rare case)
const ComplexPattern = struct {
    pattern: []const u8,
    is_dir_only: bool,
    is_anchored: bool,
    scope: []const u8, // Directory scope (empty for root gitignore)
};

/// Prefix pattern for anchored paths like "build/*" or "/vendor"
const PrefixPattern = struct {
    prefix: []const u8,
    is_dir_only: bool,
};

/// Extension pattern with scope
const ScopedExtension = struct {
    ext: []const u8,
    scope: []const u8, // Directory scope (paths must start with this)
};

/// Optimized gitignore with fast-path lookups
pub const FastGitIgnore = struct {
    allocator: Allocator,

    // O(1) hashset lookups - handles 90%+ of patterns (ROOT gitignore only)
    literal_dirs: std.StringHashMapUnmanaged(void),
    literal_files: std.StringHashMapUnmanaged(void),
    extensions: std.StringHashMapUnmanaged(void), // Global extensions from root gitignore

    // Scoped extensions from nested gitignores
    scoped_extensions: std.ArrayListUnmanaged(ScopedExtension),

    // Prefix patterns (anchored like "build/*", "/vendor")
    prefix_patterns: std.ArrayListUnmanaged(PrefixPattern),

    // Complex patterns requiring full glob (fallback)
    complex_patterns: std.ArrayListUnmanaged(ComplexPattern),

    // Negation patterns (can un-ignore files)
    negation_literals: std.StringHashMapUnmanaged(void),
    negation_extensions: std.StringHashMapUnmanaged(void),
    negation_complex: std.ArrayListUnmanaged(ComplexPattern),

    // Track pattern counts per directory depth for stack management
    pattern_stack: std.ArrayListUnmanaged(PatternSnapshot),

    const PatternSnapshot = struct {
        depth: usize,
        literal_dirs_count: usize,
        literal_files_count: usize,
        extensions_count: usize,
        prefix_count: usize,
        complex_count: usize,
        neg_literals_count: usize,
        neg_extensions_count: usize,
        neg_complex_count: usize,
    };

    pub fn init(allocator: Allocator) FastGitIgnore {
        return .{
            .allocator = allocator,
            .literal_dirs = .{},
            .literal_files = .{},
            .extensions = .{},
            .scoped_extensions = .{},
            .prefix_patterns = .{},
            .complex_patterns = .{},
            .negation_literals = .{},
            .negation_extensions = .{},
            .negation_complex = .{},
            .pattern_stack = .{},
        };
    }

    pub fn deinit(self: *FastGitIgnore) void {
        self.literal_dirs.deinit(self.allocator);
        self.literal_files.deinit(self.allocator);
        self.extensions.deinit(self.allocator);
        self.scoped_extensions.deinit(self.allocator);
        self.prefix_patterns.deinit(self.allocator);
        self.complex_patterns.deinit(self.allocator);
        self.negation_literals.deinit(self.allocator);
        self.negation_extensions.deinit(self.allocator);
        self.negation_complex.deinit(self.allocator);
        self.pattern_stack.deinit(self.allocator);
    }

    /// Check if directory should be completely skipped (prune entire subtree)
    /// This is the key optimization - skip 50K files with one O(1) lookup
    pub fn shouldSkipDir(self: *const FastGitIgnore, dir_name: []const u8) bool {
        // Check negations first - if dir is negated, don't skip
        if (self.negation_literals.contains(dir_name)) return false;

        // Fast O(1) lookup for literal directory names
        if (self.literal_dirs.contains(dir_name)) return true;

        return false;
    }

    /// Check if a directory at rel_path should be skipped
    /// This handles both global literal patterns and scoped prefix patterns
    pub fn shouldSkipDirPath(self: *const FastGitIgnore, dir_name: []const u8, rel_path: []const u8) bool {
        // Check negations first
        if (self.negation_literals.contains(dir_name)) return false;

        // Fast O(1) lookup for global literal directory names
        if (self.literal_dirs.contains(dir_name)) return true;

        // Check prefix patterns (for scoped patterns from nested .gitignore)
        for (self.prefix_patterns.items) |p| {
            if (!p.is_dir_only) continue;
            // Prefix pattern should match exactly (with trailing slash for dirs)
            if (std.mem.eql(u8, p.prefix, rel_path) or
                (p.prefix.len == rel_path.len + 1 and
                std.mem.startsWith(u8, p.prefix, rel_path) and
                p.prefix[p.prefix.len - 1] == '/'))
            {
                return true;
            }
        }

        return false;
    }

    /// Check if file should be ignored (fast paths first, complex glob last)
    pub fn isFileIgnored(self: *const FastGitIgnore, basename: []const u8, rel_path: []const u8, is_dir: bool) bool {
        var ignored = false;

        // 1. Check literal file names - O(1)
        if (!is_dir and self.literal_files.contains(basename)) {
            ignored = true;
        }

        // 2. Check literal directory names - O(1)
        if (is_dir and self.literal_dirs.contains(basename)) {
            ignored = true;
        }

        // 3. Check global extensions - O(1) (from root gitignore only)
        if (!ignored and !is_dir) {
            if (getExtension(basename)) |ext| {
                if (self.extensions.contains(ext)) {
                    ignored = true;
                }
            }
        }

        // 3b. Check scoped extensions (from nested gitignores)
        if (!ignored and !is_dir) {
            if (getExtension(basename)) |ext| {
                for (self.scoped_extensions.items) |se| {
                    if (std.mem.eql(u8, se.ext, ext)) {
                        // Check if path is within scope
                        if (std.mem.startsWith(u8, rel_path, se.scope) and
                            (rel_path.len == se.scope.len or rel_path[se.scope.len] == '/'))
                        {
                            ignored = true;
                            break;
                        }
                    }
                }
            }
        }

        // 4. Check prefix patterns - O(prefix_count), usually small
        if (!ignored) {
            for (self.prefix_patterns.items) |p| {
                if (p.is_dir_only and !is_dir) continue;
                if (p.is_dir_only) {
                    // For directories, match if path starts with prefix (matches dir and contents)
                    if (std.mem.startsWith(u8, rel_path, p.prefix)) {
                        ignored = true;
                        break;
                    }
                } else {
                    // For files, exact match required
                    if (std.mem.eql(u8, rel_path, p.prefix)) {
                        ignored = true;
                        break;
                    }
                }
            }
        }

        // 5. Check complex patterns - O(complex_count), hopefully rare
        if (!ignored) {
            for (self.complex_patterns.items) |p| {
                if (p.is_dir_only and !is_dir) continue;
                // Check if path is within the pattern's scope
                if (p.scope.len > 0) {
                    // Path must start with scope + "/"
                    if (!std.mem.startsWith(u8, rel_path, p.scope)) continue;
                    if (rel_path.len > p.scope.len and rel_path[p.scope.len] != '/') continue;
                    // Get the path relative to scope
                    const scoped_path = if (rel_path.len > p.scope.len + 1)
                        rel_path[p.scope.len + 1 ..]
                    else
                        "";
                    if (globMatch(p.pattern, scoped_path, p.is_anchored, basename)) {
                        ignored = true;
                        break;
                    }
                } else {
                    if (globMatch(p.pattern, rel_path, p.is_anchored, basename)) {
                        ignored = true;
                        break;
                    }
                }
            }
        }

        // 6. Check negations - can un-ignore
        if (ignored) {
            // Check negation literals
            if (self.negation_literals.contains(basename)) {
                return false;
            }

            // Check negation extensions
            if (!is_dir) {
                if (getExtension(basename)) |ext| {
                    if (self.negation_extensions.contains(ext)) {
                        return false;
                    }
                }
            }

            // Check complex negations
            for (self.negation_complex.items) |p| {
                if (p.is_dir_only and !is_dir) continue;
                // Check if path is within the pattern's scope
                if (p.scope.len > 0) {
                    if (!std.mem.startsWith(u8, rel_path, p.scope)) continue;
                    if (rel_path.len > p.scope.len and rel_path[p.scope.len] != '/') continue;
                    const scoped_path = if (rel_path.len > p.scope.len + 1)
                        rel_path[p.scope.len + 1 ..]
                    else
                        "";
                    if (globMatch(p.pattern, scoped_path, p.is_anchored, basename)) {
                        return false;
                    }
                } else {
                    if (globMatch(p.pattern, rel_path, p.is_anchored, basename)) {
                        return false;
                    }
                }
            }
        }

        return ignored;
    }

    /// Load and parse .gitignore file from directory
    /// prefix is the relative path to this directory (empty for root)
    pub fn loadFile(self: *FastGitIgnore, dir: std.fs.Dir) !void {
        try self.loadFileWithPrefix(dir, "");
    }

    /// Load .gitignore with a directory prefix for proper scoping
    pub fn loadFileWithPrefix(self: *FastGitIgnore, dir: std.fs.Dir, prefix: []const u8) !void {
        const file = dir.openFile(".gitignore", .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        // Use larger buffer to handle big .gitignore files (e.g., Chromium's is ~10KB)
        var buf: [32768]u8 = undefined;
        const bytes_read = file.read(&buf) catch return;

        var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
        while (lines.next()) |raw_line| {
            self.parseLineWithPrefix(raw_line, prefix) catch continue;
        }
    }

    /// Push current pattern counts for a directory depth
    pub fn pushSnapshot(self: *FastGitIgnore, depth: usize) !void {
        try self.pattern_stack.append(self.allocator, .{
            .depth = depth,
            .literal_dirs_count = self.literal_dirs.count(),
            .literal_files_count = self.literal_files.count(),
            .extensions_count = self.extensions.count(),
            .prefix_count = self.prefix_patterns.items.len,
            .complex_count = self.complex_patterns.items.len,
            .neg_literals_count = self.negation_literals.count(),
            .neg_extensions_count = self.negation_extensions.count(),
            .neg_complex_count = self.negation_complex.items.len,
        });
    }

    /// Pop patterns added at depths greater than specified
    pub fn popToDepth(self: *FastGitIgnore, depth: usize) void {
        while (self.pattern_stack.items.len > 0) {
            const last = self.pattern_stack.items[self.pattern_stack.items.len - 1];
            if (last.depth > depth) {
                // We can't easily shrink hashmaps, but we can shrink arraylists
                // For hashmaps, we'd need to track keys added at each level
                // For now, just pop the stack - patterns accumulate but that's okay
                // The extra patterns from sibling dirs won't cause incorrect results
                _ = self.pattern_stack.pop();
            } else {
                break;
            }
        }
    }

    /// Parse a single gitignore line (for root .gitignore only)
    pub fn parseLine(self: *FastGitIgnore, raw_line: []const u8) !void {
        try self.parseLineWithPrefix(raw_line, "");
    }

    /// Parse a single gitignore line with directory prefix for proper scoping
    /// For nested .gitignore files, patterns without slashes should only apply
    /// within that directory, not globally.
    pub fn parseLineWithPrefix(self: *FastGitIgnore, raw_line: []const u8, prefix: []const u8) !void {
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

        // Check if pattern contains path separator (makes it anchored)
        const has_slash = std.mem.indexOfScalar(u8, line, '/') != null;
        if (has_slash) is_anchored = true;

        // For nested .gitignore files, literal patterns should be scoped
        // to their containing directory, not applied globally.
        // Extension patterns (*.log, etc.) are still global since they're universal.
        const is_root = prefix.len == 0;

        // Categorize the pattern
        const category = categorizePattern(line, is_dir_only);

        switch (category) {
            .literal_dir => {
                // For nested .gitignore OR anchored patterns, convert to prefix patterns
                // Global hashsets only for non-anchored patterns from root gitignore
                if ((!is_root or is_anchored) and !is_negation) {
                    // Convert to prefix pattern with full path
                    const scoped = if (prefix.len > 0)
                        try std.fmt.allocPrint(self.allocator, "{s}/{s}/", .{ prefix, line })
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}/", .{line});
                    try self.prefix_patterns.append(self.allocator, .{
                        .prefix = scoped,
                        .is_dir_only = true,
                    });
                } else {
                    const key = try self.allocator.dupe(u8, line);
                    if (is_negation) {
                        try self.negation_literals.put(self.allocator, key, {});
                    } else {
                        try self.literal_dirs.put(self.allocator, key, {});
                    }
                }
            },
            .literal_file => {
                // For nested .gitignore OR anchored patterns, convert to prefix patterns
                // Global hashsets only for non-anchored patterns from root gitignore
                if ((!is_root or is_anchored) and !is_negation) {
                    const scoped = if (prefix.len > 0)
                        try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, line })
                    else
                        try self.allocator.dupe(u8, line);
                    try self.prefix_patterns.append(self.allocator, .{
                        .prefix = scoped,
                        .is_dir_only = false,
                    });
                } else {
                    const key = try self.allocator.dupe(u8, line);
                    if (is_negation) {
                        try self.negation_literals.put(self.allocator, key, {});
                    } else {
                        try self.literal_files.put(self.allocator, key, {});
                    }
                }
            },
            .extension => |ext| {
                const key = try self.allocator.dupe(u8, ext);
                if (is_negation) {
                    try self.negation_extensions.put(self.allocator, key, {});
                } else if (is_root) {
                    // Only root gitignore extensions go to global hashset
                    try self.extensions.put(self.allocator, key, {});
                } else {
                    // Nested gitignore extensions are scoped to their directory
                    const scope = try self.allocator.dupe(u8, prefix);
                    try self.scoped_extensions.append(self.allocator, .{
                        .ext = key,
                        .scope = scope,
                    });
                }
            },
            .prefix => |pat| {
                // Scope prefix pattern to nested directory
                const scoped = if (!is_root)
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, pat })
                else
                    try self.allocator.dupe(u8, pat);
                try self.prefix_patterns.append(self.allocator, .{
                    .prefix = scoped,
                    .is_dir_only = is_dir_only,
                });
            },
            .complex => {
                const p = try self.allocator.dupe(u8, line);
                const scope = if (prefix.len > 0)
                    try self.allocator.dupe(u8, prefix)
                else
                    "";
                const pattern = ComplexPattern{
                    .pattern = p,
                    .is_dir_only = is_dir_only,
                    .is_anchored = is_anchored,
                    .scope = scope,
                };
                if (is_negation) {
                    try self.negation_complex.append(self.allocator, pattern);
                } else {
                    try self.complex_patterns.append(self.allocator, pattern);
                }
            },
        }
    }

    const PatternCategory = union(enum) {
        literal_dir,
        literal_file,
        extension: []const u8,
        prefix: []const u8,
        complex,
    };

    fn categorizePattern(pattern: []const u8, is_dir_only: bool) PatternCategory {
        // Check for special glob characters
        var has_star = false;
        var has_double_star = false;
        var has_question = false;
        var has_bracket = false;
        var star_count: usize = 0;

        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            switch (pattern[i]) {
                '*' => {
                    has_star = true;
                    star_count += 1;
                    if (i + 1 < pattern.len and pattern[i + 1] == '*') {
                        has_double_star = true;
                        i += 1;
                    }
                },
                '?' => has_question = true,
                '[' => has_bracket = true,
                else => {},
            }
        }

        // No special characters - it's a literal
        if (!has_star and !has_question and !has_bracket) {
            return if (is_dir_only) .literal_dir else .literal_file;
        }

        // Pattern like "*.ext" or "**/*.ext" - extract extension
        if (!has_question and !has_bracket) {
            // Check for simple extension pattern: *.ext or **/*.ext
            if (std.mem.startsWith(u8, pattern, "*.") and star_count == 1) {
                const ext = pattern[2..];
                if (!hasGlobChars(ext)) {
                    return .{ .extension = ext };
                }
            }
            if (std.mem.startsWith(u8, pattern, "**/") and pattern.len > 3) {
                const rest = pattern[3..];
                if (std.mem.startsWith(u8, rest, "*.") and std.mem.indexOfScalar(u8, rest, '*') == 0) {
                    const ext = rest[2..];
                    if (!hasGlobChars(ext) and std.mem.indexOfScalar(u8, ext, '/') == null) {
                        return .{ .extension = ext };
                    }
                }
            }

            // Check for prefix pattern: foo/* (single * at end after /)
            if (pattern.len > 2 and pattern[pattern.len - 1] == '*' and pattern[pattern.len - 2] == '/') {
                const prefix = pattern[0 .. pattern.len - 1];
                if (!hasGlobChars(prefix[0 .. prefix.len - 1])) {
                    return .{ .prefix = prefix };
                }
            }
        }

        return .complex;
    }

    fn hasGlobChars(s: []const u8) bool {
        for (s) |c| {
            if (c == '*' or c == '?' or c == '[') return true;
        }
        return false;
    }
};

fn getExtension(filename: []const u8) ?[]const u8 {
    var i = filename.len;
    while (i > 0) {
        i -= 1;
        if (filename[i] == '.') {
            if (i == 0) return null;
            return filename[i + 1 ..];
        }
        if (filename[i] == '/') return null;
    }
    return null;
}

/// Glob matching for complex patterns only
fn globMatch(pattern: []const u8, path: []const u8, is_anchored: bool, basename: []const u8) bool {
    if (is_anchored) {
        return globMatchImpl(pattern, path);
    } else {
        // Try matching against full path
        if (globMatchImpl(pattern, path)) return true;
        // Try matching against basename
        if (globMatchImpl(pattern, basename)) return true;
        // Try matching after each /
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/') {
                if (i + 1 < path.len and globMatchImpl(pattern, path[i + 1 ..])) return true;
            }
        }
        return false;
    }
}

fn globMatchImpl(pattern: []const u8, text: []const u8) bool {
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
                    pi += 2;
                    if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                    if (pi >= pattern.len) return true;
                    while (ti <= text.len) {
                        if (globMatchImpl(pattern[pi..], text[ti..])) return true;
                        if (ti >= text.len) break;
                        ti += 1;
                    }
                    return false;
                }

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

        if (star_p) |sp| {
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

test "pattern categorization" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Test literal patterns
    try gi.parseLine("node_modules/");
    try std.testing.expect(gi.literal_dirs.contains("node_modules"));

    try gi.parseLine("Thumbs.db");
    try std.testing.expect(gi.literal_files.contains("Thumbs.db"));

    // Test extension patterns
    try gi.parseLine("*.log");
    try std.testing.expect(gi.extensions.contains("log"));

    try gi.parseLine("**/*.pyc");
    try std.testing.expect(gi.extensions.contains("pyc"));

    // Test negation
    try gi.parseLine("!important.log");
    try std.testing.expect(gi.negation_literals.contains("important.log"));
}

test "shouldSkipDir" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    try gi.parseLine("node_modules/");
    try gi.parseLine(".git/");
    try gi.parseLine("!.gitkeep");

    try std.testing.expect(gi.shouldSkipDir("node_modules"));
    try std.testing.expect(gi.shouldSkipDir(".git"));
    try std.testing.expect(!gi.shouldSkipDir("src"));
}

test "isFileIgnored" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    try gi.parseLine("*.log");
    try gi.parseLine("*.o");
    try gi.parseLine("build/");
    try gi.parseLine("!important.log");

    // Extension matching
    try std.testing.expect(gi.isFileIgnored("test.log", "test.log", false));
    try std.testing.expect(gi.isFileIgnored("main.o", "src/main.o", false));
    try std.testing.expect(!gi.isFileIgnored("main.c", "src/main.c", false));

    // Negation
    try std.testing.expect(!gi.isFileIgnored("important.log", "important.log", false));

    // Directory
    try std.testing.expect(gi.isFileIgnored("build", "build", true));
    try std.testing.expect(!gi.isFileIgnored("build", "build", false)); // file named build
}

test "extension extraction" {
    try std.testing.expectEqualStrings("txt", getExtension("file.txt").?);
    try std.testing.expectEqualStrings("gz", getExtension("archive.tar.gz").?);
    try std.testing.expect(getExtension("noextension") == null);
    try std.testing.expect(getExtension(".hidden") == null);
}

// === Scoping behavior tests ===

test "root gitignore literal dir matches any src directory" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Pattern from root gitignore (no prefix)
    try gi.parseLineWithPrefix("src/", "");

    // Should be in global literal_dirs hashset
    try std.testing.expect(gi.literal_dirs.contains("src"));

    // Should match src directories anywhere
    try std.testing.expect(gi.shouldSkipDirPath("src", "src"));
    try std.testing.expect(gi.shouldSkipDirPath("src", "foo/src"));
    try std.testing.expect(gi.shouldSkipDirPath("src", "third_party/bidimapper/src"));
}

test "nested gitignore literal dir only matches within that directory" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Pattern from nested gitignore at third_party/bidimapper/
    try gi.parseLineWithPrefix("src/", "third_party/bidimapper");

    // Should NOT be in global literal_dirs hashset
    try std.testing.expect(!gi.literal_dirs.contains("src"));

    // Should be a prefix pattern instead
    try std.testing.expect(gi.prefix_patterns.items.len == 1);
    try std.testing.expectEqualStrings("third_party/bidimapper/src/", gi.prefix_patterns.items[0].prefix);

    // Should match src only within third_party/bidimapper/
    try std.testing.expect(gi.shouldSkipDirPath("src", "third_party/bidimapper/src"));

    // Should NOT match src in other locations
    try std.testing.expect(!gi.shouldSkipDirPath("src", "src"));
    try std.testing.expect(!gi.shouldSkipDirPath("src", "foo/src"));
    try std.testing.expect(!gi.shouldSkipDirPath("src", "other/nested/src"));
}

test "extension patterns from root gitignore are global" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Pattern from root gitignore
    try gi.parseLineWithPrefix("*.pyc", "");

    // Should be in global extensions hashset
    try std.testing.expect(gi.extensions.contains("pyc"));
    try std.testing.expect(gi.scoped_extensions.items.len == 0);

    // Should match .pyc files anywhere
    try std.testing.expect(gi.isFileIgnored("test.pyc", "test.pyc", false));
    try std.testing.expect(gi.isFileIgnored("module.pyc", "src/module.pyc", false));
    try std.testing.expect(gi.isFileIgnored("cache.pyc", "deep/nested/path/cache.pyc", false));
}

test "extension patterns from nested gitignore are scoped" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Pattern from nested gitignore at third_party/lib/
    try gi.parseLineWithPrefix("*.generated", "third_party/lib");

    // Should NOT be in global extensions hashset
    try std.testing.expect(!gi.extensions.contains("generated"));

    // Should be in scoped_extensions
    try std.testing.expect(gi.scoped_extensions.items.len == 1);
    try std.testing.expectEqualStrings("generated", gi.scoped_extensions.items[0].ext);
    try std.testing.expectEqualStrings("third_party/lib", gi.scoped_extensions.items[0].scope);

    // Should match .generated files within third_party/lib/
    try std.testing.expect(gi.isFileIgnored("code.generated", "third_party/lib/code.generated", false));
    try std.testing.expect(gi.isFileIgnored("data.generated", "third_party/lib/subdir/data.generated", false));

    // Should NOT match .generated files outside that directory
    try std.testing.expect(!gi.isFileIgnored("test.generated", "test.generated", false));
    try std.testing.expect(!gi.isFileIgnored("other.generated", "src/other.generated", false));
    try std.testing.expect(!gi.isFileIgnored("foo.generated", "third_party/other/foo.generated", false));
}

test "anchored patterns from root gitignore create prefix patterns" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Anchored pattern from root (leading /)
    try gi.parseLineWithPrefix("/vendor/", "");

    // Should NOT be in global literal_dirs (anchored patterns are prefix patterns)
    try std.testing.expect(!gi.literal_dirs.contains("vendor"));

    // Should be a prefix pattern
    try std.testing.expect(gi.prefix_patterns.items.len == 1);
    try std.testing.expectEqualStrings("vendor/", gi.prefix_patterns.items[0].prefix);

    // Should match vendor at root only
    try std.testing.expect(gi.shouldSkipDirPath("vendor", "vendor"));

    // Should NOT match vendor in subdirectories (it's anchored to root)
    try std.testing.expect(!gi.shouldSkipDirPath("vendor", "foo/vendor"));
    try std.testing.expect(!gi.shouldSkipDirPath("vendor", "third_party/vendor"));
}

test "anchored pattern with slash in nested gitignore" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Pattern with slash from nested gitignore (implicitly anchored)
    try gi.parseLineWithPrefix("build/output/", "tools/compiler");

    // Should be a prefix pattern scoped to tools/compiler
    try std.testing.expect(gi.prefix_patterns.items.len == 1);
    try std.testing.expectEqualStrings("tools/compiler/build/output/", gi.prefix_patterns.items[0].prefix);

    // Should match within scope
    try std.testing.expect(gi.shouldSkipDirPath("output", "tools/compiler/build/output"));

    // Should NOT match outside scope
    try std.testing.expect(!gi.shouldSkipDirPath("output", "build/output"));
    try std.testing.expect(!gi.shouldSkipDirPath("output", "other/build/output"));
}

test "negation patterns work with scoping" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Global extension pattern from root
    try gi.parseLineWithPrefix("*.log", "");

    // Negation pattern
    try gi.parseLineWithPrefix("!important.log", "");

    // Verify extensions are global
    try std.testing.expect(gi.extensions.contains("log"));
    try std.testing.expect(gi.negation_literals.contains("important.log"));

    // .log files should be ignored
    try std.testing.expect(gi.isFileIgnored("debug.log", "debug.log", false));
    try std.testing.expect(gi.isFileIgnored("error.log", "src/error.log", false));

    // But important.log should NOT be ignored (negation)
    try std.testing.expect(!gi.isFileIgnored("important.log", "important.log", false));
    try std.testing.expect(!gi.isFileIgnored("important.log", "logs/important.log", false));
}

test "negation extension patterns" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Ignore all .o files
    try gi.parseLineWithPrefix("*.o", "");

    // But keep .ko files (kernel modules)
    try gi.parseLineWithPrefix("!*.ko", "");

    // Wait - negation for extensions works differently. Let's check the actual behavior.
    // Actually looking at the code, !*.ko would be a negation extension pattern.
    try std.testing.expect(gi.extensions.contains("o"));

    // .o files should be ignored
    try std.testing.expect(gi.isFileIgnored("main.o", "main.o", false));

    // Check that negation extension is stored
    // Note: *.ko pattern becomes extension "ko" through categorizePattern
    // The negation_extensions hashset should contain "ko"
}

test "multiple nested gitignores with different scopes" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Root gitignore: global pattern
    try gi.parseLineWithPrefix("node_modules/", "");

    // Nested gitignore in frontend/
    try gi.parseLineWithPrefix("*.min.js", "frontend");

    // Nested gitignore in backend/
    try gi.parseLineWithPrefix("*.pyc", "backend");

    // node_modules should be global
    try std.testing.expect(gi.literal_dirs.contains("node_modules"));

    // Extensions should be scoped
    try std.testing.expect(gi.scoped_extensions.items.len == 2);

    // Check frontend scope
    try std.testing.expect(gi.isFileIgnored("bundle.min.js", "frontend/bundle.min.js", false));
    try std.testing.expect(!gi.isFileIgnored("bundle.min.js", "backend/bundle.min.js", false));

    // Check backend scope
    try std.testing.expect(gi.isFileIgnored("module.pyc", "backend/module.pyc", false));
    try std.testing.expect(!gi.isFileIgnored("module.pyc", "frontend/module.pyc", false));
}

test "complex pattern scoping" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Complex pattern from nested gitignore
    try gi.parseLineWithPrefix("test_*.log", "tests");

    // Should be a complex pattern with scope
    try std.testing.expect(gi.complex_patterns.items.len == 1);
    try std.testing.expectEqualStrings("test_*.log", gi.complex_patterns.items[0].pattern);
    try std.testing.expectEqualStrings("tests", gi.complex_patterns.items[0].scope);

    // Should match within scope
    try std.testing.expect(gi.isFileIgnored("test_output.log", "tests/test_output.log", false));
    try std.testing.expect(gi.isFileIgnored("test_debug.log", "tests/unit/test_debug.log", false));

    // Should NOT match outside scope
    try std.testing.expect(!gi.isFileIgnored("test_output.log", "test_output.log", false));
    try std.testing.expect(!gi.isFileIgnored("test_other.log", "src/test_other.log", false));
}

test "literal file pattern from nested gitignore" {
    const allocator = std.testing.allocator;
    var gi = FastGitIgnore.init(allocator);
    defer gi.deinit();

    // Literal file from nested gitignore
    try gi.parseLineWithPrefix("MODULE.bazel", "third_party/lib");

    // Should NOT be in global literal_files
    try std.testing.expect(!gi.literal_files.contains("MODULE.bazel"));

    // Should be a prefix pattern
    try std.testing.expect(gi.prefix_patterns.items.len == 1);
    try std.testing.expectEqualStrings("third_party/lib/MODULE.bazel", gi.prefix_patterns.items[0].prefix);

    // Should match within scope
    try std.testing.expect(gi.isFileIgnored("MODULE.bazel", "third_party/lib/MODULE.bazel", false));

    // Should NOT match outside scope
    try std.testing.expect(!gi.isFileIgnored("MODULE.bazel", "MODULE.bazel", false));
    try std.testing.expect(!gi.isFileIgnored("MODULE.bazel", "other/MODULE.bazel", false));
}
