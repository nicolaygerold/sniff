# Sniff: Fast Fuzzy File Search in Zig

A VSCode/Zed-inspired in-memory fuzzy file finder implementation.

## Research Summary

### VSCode Approach
- **Ripgrep for file discovery** - glob filtering at OS level reduces candidates dramatically
- **Simple existence check** - `isPatternInWord()` verifies query chars exist in order before scoring
- **Bounded DP matrix** - 128 char max prevents O(n²) explosion
- **Hard limits** - 20K candidates max, only score top 512
- **Multi-tier ranking** - identity → prefix → fuzzy matches
- **Scoring bonuses** - start-of-word (+8), separator (+5), camelCase (+2), consecutive (+6/+3)

### Zed Approach  
- **CharBag** - 64-bit bloom filter for O(1) pre-filtering (deferred - adds complexity)
- **Parallel matching** - segment candidates across CPU cores
- **Memoized recursive scoring** - DP with early termination

### Our Approach
Follow VSCode's simpler model: existence check → bounded scoring → top-K heap

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Sniff                                │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Scanner   │───▶│  Existence  │───▶│   Scorer    │     │
│  │             │    │   Check     │    │  (Bounded)  │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│         │                                      │            │
│         ▼                                      ▼            │
│  ┌─────────────┐                      ┌─────────────┐      │
│  │ Path Store  │                      │  Top-K      │      │
│  │ (Arena)     │                      │  Heap       │      │
│  └─────────────┘                      └─────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: Core Data Structures

#### 1.1 Path Entry
```zig
const PathEntry = struct {
    path: []const u8,           // Pointer into arena
    path_lower: []const u8,     // Lowercased for matching
    basename_start: u16,        // Index where filename starts
    depth: u8,                  // Directory depth
};
```

#### 1.2 Path Index
```zig
const PathIndex = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(PathEntry),
    
    pub fn addPath(self: *PathIndex, path: []const u8) !void { ... }
    pub fn clear(self: *PathIndex) void { ... }
    pub fn count(self: *PathIndex) usize { ... }
};
```

### Phase 2: Directory Scanner

#### 2.1 Recursive Directory Walker
```zig
const Scanner = struct {
    index: *PathIndex,
    config: ScanConfig,
    
    pub fn scan(self: *Scanner, root: []const u8) !void {
        var walker = try std.fs.openDirAbsolute(root, .{});
        defer walker.close();
        
        var iter = walker.walk(self.index.arena.allocator());
        while (try iter.next()) |entry| {
            if (self.shouldInclude(entry)) {
                try self.index.addPath(entry.path);
            }
        }
    }
    
    fn shouldInclude(self: *Scanner, entry: Entry) bool {
        // Skip hidden, ignored patterns, max depth
    }
};
```

#### 2.2 Scan Configuration
```zig
const ScanConfig = struct {
    max_depth: usize = 20,
    ignore_hidden: bool = true,
    ignore_patterns: []const []const u8 = &.{
        "node_modules", ".git", "target", "build", 
        "__pycache__", ".venv", "vendor",
    },
};
```

### Phase 3: Query & Pre-filtering

#### 3.1 Query Preparation
```zig
const Query = struct {
    raw: []const u8,
    lower: []const u8,          // Lowercased
    has_path_sep: bool,         // Contains '/'
    
    pub fn init(allocator: Allocator, raw: []const u8) !Query {
        const lower = try allocator.alloc(u8, raw.len);
        for (raw, 0..) |c, i| {
            lower[i] = std.ascii.toLower(c);
        }
        return .{
            .raw = raw,
            .lower = lower,
            .has_path_sep = std.mem.indexOfScalar(u8, raw, '/') != null,
        };
    }
};
```

#### 3.2 Existence Check (VSCode-style)
Fast O(n) check that all query chars exist in path, in order:

```zig
/// Returns true if all characters in `pattern` appear in `text` in order.
/// This is the key pre-filter before expensive scoring.
fn isPatternInText(pattern: []const u8, text: []const u8) bool {
    var pattern_idx: usize = 0;
    for (text) |c| {
        if (pattern_idx >= pattern.len) break;
        if (c == pattern[pattern_idx]) {
            pattern_idx += 1;
        }
    }
    return pattern_idx == pattern.len;
}
```

### Phase 4: Fuzzy Scorer

#### 4.1 Scoring Constants
```zig
const Score = struct {
    // Position bonuses (VSCode-inspired)
    const START_OF_STRING: i32 = 8;
    const AFTER_SEPARATOR: i32 = 5;     // After /, \, -, _, .
    const CAMEL_CASE: i32 = 2;          // Uppercase after lowercase
    
    // Sequence bonuses
    const CONSECUTIVE_FIRST3: i32 = 6;
    const CONSECUTIVE_REST: i32 = 3;
    
    // Match quality
    const EXACT_CASE: i32 = 1;
    const BASE_MATCH: i32 = 1;
    
    // Limits
    const MAX_PATH_LEN: usize = 128;    // Bound the DP matrix
};
```

#### 4.2 Bounded DP Scoring
```zig
const Scorer = struct {
    // Pre-allocated matrix for reuse (avoid allocation per match)
    matrix: [Score.MAX_PATH_LEN][Score.MAX_PATH_LEN]i32,
    
    pub fn score(
        self: *Scorer,
        query: []const u8,
        query_lower: []const u8,
        path: []const u8,
        path_lower: []const u8,
    ) ?MatchResult {
        // Bound inputs
        const q_len = @min(query.len, Score.MAX_PATH_LEN);
        const p_len = @min(path.len, Score.MAX_PATH_LEN);
        
        // Quick reject: query longer than path
        if (q_len > p_len) return null;
        
        // Existence check first
        if (!isPatternInText(query_lower[0..q_len], path_lower[0..p_len])) {
            return null;
        }
        
        // DP scoring
        return self.computeScore(query[0..q_len], query_lower[0..q_len], 
                                  path[0..p_len], path_lower[0..p_len]);
    }
    
    fn computeScore(
        self: *Scorer,
        query: []const u8,
        query_lower: []const u8,
        path: []const u8,
        path_lower: []const u8,
    ) MatchResult {
        // Initialize matrix
        // For each query char, find best positions in path
        // Apply bonuses for position context
        // Track match positions for highlighting
        ...
    }
    
    fn getPositionBonus(path: []const u8, pos: usize) i32 {
        if (pos == 0) return Score.START_OF_STRING;
        
        const prev = path[pos - 1];
        const curr = path[pos];
        
        if (prev == '/' or prev == '\\' or prev == '-' or prev == '_') {
            return Score.AFTER_SEPARATOR;
        }
        if (prev == '.') {
            return Score.AFTER_SEPARATOR - 1;  // Slightly less than separator
        }
        if (std.ascii.isLower(prev) and std.ascii.isUpper(curr)) {
            return Score.CAMEL_CASE;
        }
        return 0;
    }
};
```

#### 4.3 Match Result
```zig
const MatchResult = struct {
    score: i32,
    positions: std.BoundedArray(u16, Score.MAX_PATH_LEN),
    
    pub fn addPosition(self: *MatchResult, pos: u16) void {
        self.positions.append(pos) catch {};
    }
};
```

### Phase 5: Result Management

#### 5.1 Search Result
```zig
const SearchResult = struct {
    entry: *const PathEntry,
    score: i32,
    positions: []const u16,     // For highlight rendering
};
```

#### 5.2 Top-K Heap
```zig
const ResultHeap = struct {
    const MAX_RESULTS = 512;
    
    items: std.BoundedArray(SearchResult, MAX_RESULTS),
    min_score: i32,
    
    pub fn init() ResultHeap {
        return .{
            .items = .{},
            .min_score = 0,
        };
    }
    
    pub fn insert(self: *ResultHeap, result: SearchResult) void {
        // Quick reject if below threshold and heap is full
        if (self.items.len == MAX_RESULTS and result.score <= self.min_score) {
            return;
        }
        
        if (self.items.len < MAX_RESULTS) {
            self.items.append(result) catch {};
            self.updateMinScore();
        } else {
            // Replace minimum element
            self.replaceMin(result);
        }
    }
    
    pub fn getSorted(self: *ResultHeap) []SearchResult {
        std.sort.pdq(SearchResult, self.items.slice(), {}, compareFn);
        return self.items.slice();
    }
    
    fn compareFn(_: void, a: SearchResult, b: SearchResult) bool {
        // Higher score first
        if (a.score != b.score) return a.score > b.score;
        // Shallower depth first
        if (a.entry.depth != b.entry.depth) return a.entry.depth < b.entry.depth;
        // Shorter basename first
        const a_base = a.entry.path.len - a.entry.basename_start;
        const b_base = b.entry.path.len - b.entry.basename_start;
        if (a_base != b_base) return a_base < b_base;
        // Alphabetical
        return std.mem.lessThan(u8, a.entry.path, b.entry.path);
    }
};
```

### Phase 6: Main Search Engine

#### 6.1 Sniff API
```zig
pub const Sniff = struct {
    allocator: Allocator,
    index: PathIndex,
    scorer: Scorer,
    config: Config,
    
    pub fn init(allocator: Allocator, config: Config) Sniff {
        return .{
            .allocator = allocator,
            .index = PathIndex.init(allocator),
            .scorer = Scorer.init(),
            .config = config,
        };
    }
    
    pub fn deinit(self: *Sniff) void {
        self.index.deinit();
    }
    
    /// Index a directory recursively
    pub fn indexDirectory(self: *Sniff, root: []const u8) !void {
        var scanner = Scanner.init(&self.index, self.config.scan);
        try scanner.scan(root);
    }
    
    /// Search with fuzzy query
    pub fn search(self: *Sniff, query_str: []const u8) ![]SearchResult {
        if (query_str.len == 0) return &[_]SearchResult{};
        
        var query = try Query.init(self.allocator, query_str);
        defer query.deinit(self.allocator);
        
        var heap = ResultHeap.init();
        
        for (self.index.entries.items) |*entry| {
            // Choose what to match against based on query
            const match_target = if (query.has_path_sep) 
                entry.path_lower 
            else 
                entry.path_lower[entry.basename_start..];
            
            if (self.scorer.score(query.lower, match_target)) |result| {
                heap.insert(.{
                    .entry = entry,
                    .score = result.score,
                    .positions = result.positions.slice(),
                });
            }
        }
        
        return heap.getSorted();
    }
    
    /// Clear the index
    pub fn clear(self: *Sniff) void {
        self.index.clear();
    }
    
    /// Get number of indexed files
    pub fn fileCount(self: *Sniff) usize {
        return self.index.entries.items.len;
    }
};
```

#### 6.2 Configuration
```zig
pub const Config = struct {
    scan: ScanConfig = .{},
    max_results: usize = 512,
};
```

### Phase 7: CLI Interface

```zig
// main.zig
const std = @import("std");
const Sniff = @import("sniff.zig").Sniff;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        std.debug.print("Usage: sniff <directory> [query]\n", .{});
        return;
    }
    
    var sniff = Sniff.init(allocator, .{});
    defer sniff.deinit();
    
    // Index
    const start = std.time.milliTimestamp();
    try sniff.indexDirectory(args[1]);
    const index_time = std.time.milliTimestamp() - start;
    
    std.debug.print("Indexed {} files in {}ms\n", .{ sniff.fileCount(), index_time });
    
    // Interactive or single query
    if (args.len >= 3) {
        const results = try sniff.search(args[2]);
        for (results) |r| {
            std.debug.print("{s} (score: {})\n", .{ r.entry.path, r.score });
        }
    } else {
        // TODO: Interactive mode with readline
    }
}
```

## File Structure

```
sniff/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── sniff.zig          # Main API (Sniff struct)
│   ├── index.zig          # PathIndex, PathEntry
│   ├── scanner.zig        # Directory scanner
│   ├── query.zig          # Query preparation
│   ├── scorer.zig         # Fuzzy scoring algorithm
│   └── results.zig        # ResultHeap, SearchResult
├── tests/
│   ├── scorer_test.zig
│   ├── index_test.zig
│   └── integration_test.zig
├── docs/
│   └── IMPLEMENTATION_PLAN.md
├── build.zig
└── README.md
```

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Index 100K files | < 500ms | Single-threaded scan |
| Search 100K files | < 50ms | With existence pre-filter |
| Memory per file | < 150 bytes | Path + lowercase + metadata |
| Result latency | < 20ms | For typical queries |

## Testing Strategy

### Unit Tests
- Existence check: edge cases, unicode
- Scorer: verify bonus calculations, known scores
- Heap: insertion, min tracking, sorting

### Integration Tests
- Index real directory, verify count
- Search queries return expected files
- Large directory performance

### Benchmarks
```zig
// benchmark.zig
test "bench: search 100K files" {
    var sniff = Sniff.init(testing.allocator, .{});
    try sniff.indexDirectory("/large/repo");
    
    var timer = std.time.Timer{};
    timer.reset();
    
    for (0..100) |_| {
        _ = try sniff.search("foo");
    }
    
    const avg_ns = timer.read() / 100;
    std.debug.print("Average search: {}ms\n", .{avg_ns / 1_000_000});
}
```

## Implementation Order

1. **Week 1**: PathEntry, PathIndex, basic scanner
2. **Week 2**: Query preparation, existence check
3. **Week 3**: Bounded DP scorer with bonuses
4. **Week 4**: ResultHeap, ranking logic
5. **Week 5**: CLI interface, polish
6. **Week 6**: Tests, benchmarks, optimization

## Future Enhancements (Post-MVP)

| Feature | Priority | Notes |
|---------|----------|-------|
| Parallel search | High | Segment entries across threads |
| File watcher | Medium | Auto-update on changes |
| Frecency boost | Medium | Recent/frequent files rank higher |
| CharBag filter | Low | Add if profiling shows need |
| Glob patterns | Low | `*.ts`, `src/**/*.zig` |
| C API / FFI | Low | Integration with other tools |

## Key Design Decisions

1. **No CharBag** - Simple existence check is fast enough, less complexity
2. **Bounded matrix** - 128 char limit prevents pathological cases
3. **Arena allocator** - All paths in contiguous memory, cache-friendly
4. **Pre-allocated scorer** - Reuse matrix across searches, zero allocation
5. **Top-K heap** - Only track best 512 results, early rejection
6. **Lowercase pre-computed** - Store both original and lower per path
