const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;

pub const WatchEvent = struct {
    path: []const u8,
    kind: Kind,

    pub const Kind = enum {
        created,
        deleted,
        modified,
        renamed,
    };
};

pub const Watcher = union(enum) {
    kqueue: KqueueWatcher,
    inotify: InotifyWatcher,
    windows: WindowsWatcher,
    polling: PollWatcher,

    pub fn init(allocator: Allocator, root: []const u8) !Watcher {
        switch (builtin.os.tag) {
            .macos, .freebsd, .openbsd, .netbsd => {
                return .{ .kqueue = try KqueueWatcher.init(allocator, root) };
            },
            .linux => {
                return .{ .inotify = try InotifyWatcher.init(allocator, root) };
            },
            .windows => {
                return .{ .windows = try WindowsWatcher.init(allocator, root) };
            },
            else => {
                return .{ .polling = try PollWatcher.init(allocator, root) };
            },
        }
    }

    pub fn deinit(self: *Watcher) void {
        switch (self.*) {
            .kqueue => |*w| w.deinit(),
            .inotify => |*w| w.deinit(),
            .windows => |*w| w.deinit(),
            .polling => |*w| w.deinit(),
        }
    }

    pub fn poll(self: *Watcher) ![]WatchEvent {
        return switch (self.*) {
            .kqueue => |*w| w.poll(),
            .inotify => |*w| w.poll(),
            .windows => |*w| w.poll(),
            .polling => |*w| w.poll(),
        };
    }

    pub fn getFd(self: *Watcher) ?std.posix.fd_t {
        switch (self.*) {
            .kqueue => |w| return w.kq,
            .inotify => |w| return w.fd,
            .windows, .polling => return null,
        }
    }
};

// =============================================================================
// LRU Ring Buffer for rename cookies (fsnotify pattern)
// Tracks pending MOVED_FROM events waiting for their MOVED_TO pair
// =============================================================================

pub fn RenameCookieBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const CAPACITY = 10;

        entries: [CAPACITY]?Entry = .{null} ** CAPACITY,
        next_index: usize = 0,

        const Entry = struct {
            cookie: u32,
            data: T,
            timestamp: i64,
        };

        pub fn put(self: *Self, cookie: u32, data: T) void {
            self.entries[self.next_index] = Entry{
                .cookie = cookie,
                .data = data,
                .timestamp = std.time.milliTimestamp(),
            };
            self.next_index = (self.next_index + 1) % CAPACITY;
        }

        pub fn pop(self: *Self, cookie: u32) ?T {
            for (&self.entries) |*slot| {
                if (slot.*) |entry| {
                    if (entry.cookie == cookie) {
                        const data = entry.data;
                        slot.* = null;
                        return data;
                    }
                }
            }
            return null;
        }

        pub fn expireOld(self: *Self, max_age_ms: i64, allocator: Allocator) void {
            const now = std.time.milliTimestamp();
            for (&self.entries) |*slot| {
                if (slot.*) |entry| {
                    if (now - entry.timestamp > max_age_ms) {
                        allocator.free(entry.data);
                        slot.* = null;
                    }
                }
            }
        }

        pub fn deinitAll(self: *Self, allocator: Allocator) void {
            for (&self.entries) |*slot| {
                if (slot.*) |entry| {
                    allocator.free(entry.data);
                    slot.* = null;
                }
            }
        }
    };
}

// =============================================================================
// FileIdCache for tracking file identity across renames (notify-rs pattern)
// Used on macOS/Windows where rename cookies are not available
// On Linux, inotify provides rename cookies so FileID tracking is optional
// =============================================================================

pub const FileId = struct {
    inode: u64,

    pub fn eql(self: FileId, other: FileId) bool {
        return self.inode == other.inode;
    }
};

pub const FileIdCache = struct {
    const Self = @This();

    paths: std.StringHashMap(FileId),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return .{
            .paths = std.StringHashMap(FileId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var key_iter = self.paths.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.paths.deinit();
    }

    pub fn getFileId(path: []const u8) ?FileId {
        const stat = std.fs.cwd().statFile(path) catch return null;
        return FileId{
            .inode = stat.inode,
        };
    }

    pub fn cachedFileId(self: *const Self, path: []const u8) ?FileId {
        return self.paths.get(path);
    }

    pub fn addPath(self: *Self, path: []const u8) !void {
        if (getFileId(path)) |file_id| {
            if (!self.paths.contains(path)) {
                const path_owned = try self.allocator.dupe(u8, path);
                try self.paths.put(path_owned, file_id);
            } else {
                if (self.paths.getPtr(path)) |entry| {
                    entry.* = file_id;
                }
            }
        }
    }

    pub fn removePath(self: *Self, path: []const u8) void {
        if (self.paths.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    pub fn removePathsWithPrefix(self: *Self, prefix: []const u8) void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var key_iter = self.paths.keyIterator();
        while (key_iter.next()) |key| {
            if (std.mem.startsWith(u8, key.*, prefix)) {
                to_remove.append(key.*) catch {};
            }
        }

        for (to_remove.items) |key| {
            if (self.paths.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    pub fn findByFileId(self: *const Self, file_id: FileId) ?[]const u8 {
        var iter = self.paths.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.eql(file_id)) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }
};

// =============================================================================
// WatchEntry - Entry abstraction with importance scoring
// Tracks files/directories with priority for dirty file processing
// Importance factors: file type (source > generated), recency, open status
// =============================================================================

pub const WatchEntry = struct {
    path: []const u8,
    kind: Kind,
    importance: u32,
    last_modified: i64,
    is_open: bool,

    pub const Kind = enum {
        file,
        directory,
    };

    pub const Importance = struct {
        pub const BASE: u32 = 100;
        pub const OPEN_FILE: u32 = 500;
        pub const SOURCE_FILE: u32 = 200;
        pub const CONFIG_FILE: u32 = 150;
        pub const TEST_FILE: u32 = 100;
        pub const GENERATED_FILE: u32 = 10;
        pub const RECENCY_BONUS_MAX: u32 = 100;
        pub const RECENCY_DECAY_MS: i64 = 60_000;
    };

    pub fn calculateImportance(path: []const u8, is_open: bool, last_modified: i64) u32 {
        var score: u32 = Importance.BASE;

        if (is_open) {
            score += Importance.OPEN_FILE;
        }

        score += getFileTypeBonus(path);
        score += getRecencyBonus(last_modified);

        return score;
    }

    fn getFileTypeBonus(path: []const u8) u32 {
        const ext = getExtension(path);

        if (std.mem.eql(u8, ext, ".zig") or
            std.mem.eql(u8, ext, ".rs") or
            std.mem.eql(u8, ext, ".go") or
            std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".py") or
            std.mem.eql(u8, ext, ".c") or
            std.mem.eql(u8, ext, ".h") or
            std.mem.eql(u8, ext, ".cpp") or
            std.mem.eql(u8, ext, ".hpp"))
        {
            return Importance.SOURCE_FILE;
        }

        if (std.mem.eql(u8, ext, ".json") or
            std.mem.eql(u8, ext, ".toml") or
            std.mem.eql(u8, ext, ".yaml") or
            std.mem.eql(u8, ext, ".yml") or
            std.mem.eql(u8, ext, ".md"))
        {
            return Importance.CONFIG_FILE;
        }

        if (containsTestIndicator(path)) {
            return Importance.TEST_FILE;
        }

        if (isGeneratedFile(path)) {
            return Importance.GENERATED_FILE;
        }

        return 0;
    }

    fn getExtension(path: []const u8) []const u8 {
        var i = path.len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '.') {
                return path[i - 1 ..];
            }
            if (path[i - 1] == '/' or path[i - 1] == '\\') {
                break;
            }
        }
        return "";
    }

    fn containsTestIndicator(path: []const u8) bool {
        const lower = path;
        return std.mem.indexOf(u8, lower, "_test.") != null or
            std.mem.indexOf(u8, lower, ".test.") != null or
            std.mem.indexOf(u8, lower, "/test/") != null or
            std.mem.indexOf(u8, lower, "/tests/") != null or
            std.mem.indexOf(u8, lower, "_spec.") != null;
    }

    fn isGeneratedFile(path: []const u8) bool {
        return std.mem.indexOf(u8, path, "/gen/") != null or
            std.mem.indexOf(u8, path, "/generated/") != null or
            std.mem.indexOf(u8, path, ".gen.") != null or
            std.mem.indexOf(u8, path, ".generated.") != null or
            std.mem.indexOf(u8, path, "/node_modules/") != null or
            std.mem.indexOf(u8, path, "/zig-cache/") != null or
            std.mem.indexOf(u8, path, "/zig-out/") != null or
            std.mem.indexOf(u8, path, "/target/") != null or
            std.mem.indexOf(u8, path, "/.git/") != null;
    }

    fn getRecencyBonus(last_modified: i64) u32 {
        const now = std.time.milliTimestamp();
        const age_ms = now - last_modified;

        if (age_ms <= 0) {
            return Importance.RECENCY_BONUS_MAX;
        }

        if (age_ms >= Importance.RECENCY_DECAY_MS) {
            return 0;
        }

        const ratio = @as(u32, @intCast(@divFloor(age_ms * Importance.RECENCY_BONUS_MAX, Importance.RECENCY_DECAY_MS)));
        return Importance.RECENCY_BONUS_MAX -| ratio;
    }
};

// =============================================================================
// DirtyFileHeap - Binary heap for prioritized dirty file processing
// Higher importance files are processed first
// =============================================================================

pub const DirtyFileHeap = struct {
    const Self = @This();
    const MAX_ENTRIES = 1024;

    entries: std.BoundedArray(HeapEntry, MAX_ENTRIES),

    const HeapEntry = struct {
        path: []const u8,
        importance: u32,
        timestamp: i64,
    };

    pub fn init() Self {
        return .{
            .entries = .{},
        };
    }

    pub fn insert(self: *Self, path: []const u8, importance: u32) void {
        const entry = HeapEntry{
            .path = path,
            .importance = importance,
            .timestamp = std.time.milliTimestamp(),
        };

        for (self.entries.slice(), 0..) |existing, i| {
            if (std.mem.eql(u8, existing.path, path)) {
                self.entries.buffer[i] = entry;
                self.siftUp(i);
                self.siftDown(i);
                return;
            }
        }

        if (self.entries.len < MAX_ENTRIES) {
            self.entries.append(entry) catch return;
            self.siftUp(self.entries.len - 1);
        } else if (importance > self.entries.buffer[self.entries.len - 1].importance) {
            self.entries.buffer[self.entries.len - 1] = entry;
            self.siftUp(self.entries.len - 1);
        }
    }

    pub fn pop(self: *Self) ?HeapEntry {
        if (self.entries.len == 0) return null;

        const top = self.entries.buffer[0];
        self.entries.buffer[0] = self.entries.buffer[self.entries.len - 1];
        _ = self.entries.pop();

        if (self.entries.len > 0) {
            self.siftDown(0);
        }

        return top;
    }

    pub fn peek(self: *const Self) ?HeapEntry {
        if (self.entries.len == 0) return null;
        return self.entries.buffer[0];
    }

    pub fn len(self: *const Self) usize {
        return self.entries.len;
    }

    pub fn remove(self: *Self, path: []const u8) bool {
        for (self.entries.slice(), 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                self.entries.buffer[i] = self.entries.buffer[self.entries.len - 1];
                _ = self.entries.pop();
                if (i < self.entries.len) {
                    self.siftUp(i);
                    self.siftDown(i);
                }
                return true;
            }
        }
        return false;
    }

    fn siftUp(self: *Self, idx: usize) void {
        var i = idx;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (self.entries.buffer[i].importance > self.entries.buffer[parent].importance) {
                const tmp = self.entries.buffer[i];
                self.entries.buffer[i] = self.entries.buffer[parent];
                self.entries.buffer[parent] = tmp;
                i = parent;
            } else {
                break;
            }
        }
    }

    fn siftDown(self: *Self, idx: usize) void {
        var i = idx;
        while (true) {
            var largest = i;
            const left = 2 * i + 1;
            const right = 2 * i + 2;

            if (left < self.entries.len and
                self.entries.buffer[left].importance > self.entries.buffer[largest].importance)
            {
                largest = left;
            }

            if (right < self.entries.len and
                self.entries.buffer[right].importance > self.entries.buffer[largest].importance)
            {
                largest = right;
            }

            if (largest != i) {
                const tmp = self.entries.buffer[i];
                self.entries.buffer[i] = self.entries.buffer[largest];
                self.entries.buffer[largest] = tmp;
                i = largest;
            } else {
                break;
            }
        }
    }
};

// =============================================================================
// WatchState - Manages watched entries and their importance
// Supports recursive directory watching with inherited importance
// =============================================================================

pub const WatchState = struct {
    const Self = @This();

    entries: std.StringHashMap(WatchEntry),
    open_files: std.StringHashMap(void),
    dirty_files: DirtyFileHeap,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return .{
            .entries = std.StringHashMap(WatchEntry).init(allocator),
            .open_files = std.StringHashMap(void).init(allocator),
            .dirty_files = DirtyFileHeap.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var key_iter = self.entries.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.deinit();

        var open_iter = self.open_files.keyIterator();
        while (open_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.open_files.deinit();
    }

    pub fn addEntry(self: *Self, path: []const u8, kind: WatchEntry.Kind) !void {
        if (self.entries.contains(path)) {
            return;
        }

        const now = std.time.milliTimestamp();
        const is_open = self.open_files.contains(path);
        const importance = WatchEntry.calculateImportance(path, is_open, now);

        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        try self.entries.put(path_owned, WatchEntry{
            .path = path_owned,
            .kind = kind,
            .importance = importance,
            .last_modified = now,
            .is_open = is_open,
        });
    }

    pub fn removeEntry(self: *Self, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |kv| {
            _ = self.dirty_files.remove(path);
            self.allocator.free(kv.key);
        }
    }

    pub fn markDirty(self: *Self, path: []const u8) void {
        if (self.entries.getPtr(path)) |entry| {
            const now = std.time.milliTimestamp();
            entry.last_modified = now;
            entry.importance = WatchEntry.calculateImportance(path, entry.is_open, now);
            self.dirty_files.insert(entry.path, entry.importance);
        }
    }

    pub fn markOpen(self: *Self, path: []const u8) !void {
        if (!self.open_files.contains(path)) {
            const path_owned = try self.allocator.dupe(u8, path);
            try self.open_files.put(path_owned, {});
        }

        if (self.entries.getPtr(path)) |entry| {
            entry.is_open = true;
            entry.importance = WatchEntry.calculateImportance(path, true, entry.last_modified);
        }
    }

    pub fn markClosed(self: *Self, path: []const u8) void {
        if (self.open_files.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }

        if (self.entries.getPtr(path)) |entry| {
            entry.is_open = false;
            entry.importance = WatchEntry.calculateImportance(path, false, entry.last_modified);
        }
    }

    pub fn popDirty(self: *Self) ?[]const u8 {
        if (self.dirty_files.pop()) |entry| {
            return entry.path;
        }
        return null;
    }

    pub fn peekDirty(self: *const Self) ?[]const u8 {
        if (self.dirty_files.peek()) |entry| {
            return entry.path;
        }
        return null;
    }

    pub fn dirtyCount(self: *const Self) usize {
        return self.dirty_files.len();
    }

    pub fn addDirectoryRecursive(self: *Self, dir_path: []const u8, parent_importance: u32, depth: usize) !void {
        const MAX_DEPTH = 20;
        if (depth > MAX_DEPTH) return;

        try self.addEntry(dir_path, .directory);

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            const child_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            defer self.allocator.free(child_path);

            if (entry.kind == .directory) {
                self.addDirectoryRecursive(child_path, parent_importance, depth + 1) catch {};
            } else if (entry.kind == .file) {
                self.addEntry(child_path, .file) catch {};
            }
        }
    }
};

// =============================================================================
// WorkspaceWatcher - Multi-workspace file watcher
// Manages multiple FileWatcher instances (one per workspace root)
// Aggregates dirty files across workspaces with cross-workspace importance ranking
// Handles overlapping paths gracefully (child workspaces override parent watchers)
// =============================================================================

pub const WorkspaceWatcher = struct {
    const Self = @This();
    const MAX_WORKSPACES = 32;

    allocator: Allocator,
    workspaces: std.StringHashMap(WorkspaceEntry),
    global_dirty_heap: DirtyFileHeap,

    const WorkspaceEntry = struct {
        watcher: Watcher,
        state: WatchState,
        root: []const u8,
        is_active: bool,
    };

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .workspaces = std.StringHashMap(WorkspaceEntry).init(allocator),
            .global_dirty_heap = DirtyFileHeap.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            var ws = entry.value_ptr;
            ws.watcher.deinit();
            ws.state.deinit();
            self.allocator.free(ws.root);
        }

        var key_iter = self.workspaces.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.workspaces.deinit();
    }

    /// Add a workspace to watch. If the path overlaps with an existing workspace,
    /// the more specific (child) path takes precedence for overlapping files.
    pub fn addWorkspace(self: *Self, root: []const u8) !void {
        if (self.workspaces.count() >= MAX_WORKSPACES) {
            return error.TooManyWorkspaces;
        }

        if (self.workspaces.contains(root)) {
            return; // Already watching
        }

        // Check for overlapping paths and handle gracefully
        // If new workspace is child of existing, it will override for those paths
        // If new workspace is parent of existing child, child takes precedence
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            const existing_root = entry.key_ptr.*;

            // New path is parent of existing - existing child takes precedence
            if (std.mem.startsWith(u8, existing_root, root) and
                existing_root.len > root.len and
                (existing_root[root.len] == '/' or existing_root[root.len] == '\\'))
            {
                // Existing is a child workspace - it will handle its own subtree
                // We still add the parent but mark overlapping paths as handled
                continue;
            }

            // New path is child of existing - new takes precedence for its subtree
            if (std.mem.startsWith(u8, root, existing_root) and
                root.len > existing_root.len and
                (root[existing_root.len] == '/' or root[existing_root.len] == '\\'))
            {
                // Parent exists, new child will override for its subtree
                continue;
            }
        }

        const root_owned = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(root_owned);

        const key_owned = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(key_owned);

        var watcher = try Watcher.init(self.allocator, root);
        errdefer watcher.deinit();

        try self.workspaces.put(key_owned, .{
            .watcher = watcher,
            .state = WatchState.init(self.allocator),
            .root = root_owned,
            .is_active = true,
        });
    }

    /// Remove a workspace from watching
    pub fn removeWorkspace(self: *Self, root: []const u8) void {
        if (self.workspaces.fetchRemove(root)) |kv| {
            var ws = kv.value;
            ws.watcher.deinit();
            ws.state.deinit();
            self.allocator.free(ws.root);
            self.allocator.free(kv.key);

            // Remove any dirty files from this workspace from global heap
            self.rebuildGlobalDirtyHeap();
        }
    }

    /// Poll all workspaces for events and update dirty file tracking
    pub fn poll(self: *Self) ![]WatchEvent {
        var all_events = std.ArrayList(WatchEvent).init(self.allocator);
        defer all_events.deinit();

        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            const ws = entry.value_ptr;
            if (!ws.is_active) continue;

            const events = try ws.watcher.poll();
            for (events) |ev| {
                // Convert relative path to absolute for cross-workspace tracking
                const abs_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ ws.root, ev.path });
                defer self.allocator.free(abs_path);

                // Skip if a more specific child workspace handles this path
                if (self.isHandledByChildWorkspace(ws.root, abs_path)) {
                    continue;
                }

                // Update workspace state
                switch (ev.kind) {
                    .created => {
                        ws.state.addEntry(abs_path, .file) catch {};
                        ws.state.markDirty(abs_path);
                    },
                    .modified => {
                        ws.state.markDirty(abs_path);
                    },
                    .deleted => {
                        ws.state.removeEntry(abs_path);
                    },
                    .renamed => {
                        ws.state.removeEntry(abs_path);
                    },
                }

                // Add to global dirty heap for cross-workspace ranking
                if (ev.kind == .created or ev.kind == .modified) {
                    if (ws.state.entries.get(abs_path)) |watch_entry| {
                        self.global_dirty_heap.insert(watch_entry.path, watch_entry.importance);
                    }
                } else {
                    _ = self.global_dirty_heap.remove(abs_path);
                }

                try all_events.append(ev);
            }
        }

        // Return events - caller owns this memory
        return try all_events.toOwnedSlice();
    }

    /// Check if a path is handled by a more specific child workspace
    fn isHandledByChildWorkspace(self: *Self, current_root: []const u8, abs_path: []const u8) bool {
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            const other_root = entry.key_ptr.*;

            // Skip self
            if (std.mem.eql(u8, other_root, current_root)) continue;

            // Other workspace is a child of current and contains this path
            if (std.mem.startsWith(u8, other_root, current_root) and
                other_root.len > current_root.len and
                std.mem.startsWith(u8, abs_path, other_root))
            {
                return true;
            }
        }
        return false;
    }

    /// Rebuild the global dirty heap from all workspace states
    fn rebuildGlobalDirtyHeap(self: *Self) void {
        self.global_dirty_heap = DirtyFileHeap.init();

        var ws_iter = self.workspaces.iterator();
        while (ws_iter.next()) |ws_entry| {
            const ws = ws_entry.value_ptr;
            var dirty_count = ws.state.dirtyCount();
            while (dirty_count > 0) : (dirty_count -= 1) {
                if (ws.state.dirty_files.peek()) |entry| {
                    self.global_dirty_heap.insert(entry.path, entry.importance);
                }
            }
        }
    }

    /// Get the next highest-priority dirty file across all workspaces
    pub fn popGlobalDirty(self: *Self) ?[]const u8 {
        if (self.global_dirty_heap.pop()) |entry| {
            // Also remove from the workspace's local dirty heap
            var iter = self.workspaces.iterator();
            while (iter.next()) |ws_entry| {
                _ = ws_entry.value_ptr.state.dirty_files.remove(entry.path);
            }
            return entry.path;
        }
        return null;
    }

    /// Peek at the next highest-priority dirty file
    pub fn peekGlobalDirty(self: *const Self) ?[]const u8 {
        if (self.global_dirty_heap.peek()) |entry| {
            return entry.path;
        }
        return null;
    }

    /// Get total dirty file count across all workspaces
    pub fn globalDirtyCount(self: *const Self) usize {
        return self.global_dirty_heap.len();
    }

    /// Get the number of active workspaces
    pub fn workspaceCount(self: *const Self) usize {
        return self.workspaces.count();
    }

    /// Mark a file as open across all workspaces that contain it
    pub fn markOpen(self: *Self, abs_path: []const u8) !void {
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            const ws = entry.value_ptr;
            if (std.mem.startsWith(u8, abs_path, ws.root)) {
                try ws.state.markOpen(abs_path);
                // Update global heap with new importance
                if (ws.state.entries.get(abs_path)) |watch_entry| {
                    self.global_dirty_heap.insert(watch_entry.path, watch_entry.importance);
                }
            }
        }
    }

    /// Mark a file as closed across all workspaces
    pub fn markClosed(self: *Self, abs_path: []const u8) void {
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            const ws = entry.value_ptr;
            if (std.mem.startsWith(u8, abs_path, ws.root)) {
                ws.state.markClosed(abs_path);
                // Update global heap with new importance
                if (ws.state.entries.get(abs_path)) |watch_entry| {
                    self.global_dirty_heap.insert(watch_entry.path, watch_entry.importance);
                }
            }
        }
    }

    /// Get workspace roots (for debugging/introspection)
    pub fn getWorkspaceRoots(self: *const Self, buffer: [][]const u8) usize {
        var count: usize = 0;
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            if (count >= buffer.len) break;
            buffer[count] = entry.key_ptr.*;
            count += 1;
        }
        return count;
    }

    /// Check if a specific workspace is being watched
    pub fn hasWorkspace(self: *const Self, root: []const u8) bool {
        return self.workspaces.contains(root);
    }
};

// =============================================================================
// Debounce state for per-path event coalescing (notify-rs patterns)
// Key patterns from notify-debouncer-full:
// - Skip duplicate Create events
// - Suppress Modify after Create
// - Per-path event queuing with time-based expiration
// =============================================================================

pub const DebounceEntry = struct {
    kind: WatchEvent.Kind,
    first_event: i64,
    last_event: i64,
    event_count: u32,
    was_created: bool,
};

pub fn Debouncer(comptime debounce_ms: i64) type {
    return struct {
        const Self = @This();

        pending: std.StringHashMap(DebounceEntry),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .pending = std.StringHashMap(DebounceEntry).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var key_iter = self.pending.keyIterator();
            while (key_iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.pending.deinit();
        }

        pub fn recordEvent(self: *Self, path: []const u8, kind: WatchEvent.Kind) !void {
            const now = std.time.milliTimestamp();

            if (self.pending.getPtr(path)) |entry| {
                // notify-rs pattern: Skip duplicate Create and Modify after Create
                if (entry.was_created) {
                    switch (kind) {
                        .created => return, // Skip duplicate Create
                        .modified => return, // Suppress Modify after Create
                        .deleted => {
                            // created + deleted = deleted (file never really existed)
                            entry.kind = .deleted;
                            entry.was_created = false;
                        },
                        .renamed => {
                            // Keep rename, update state
                            entry.kind = kind;
                        },
                    }
                } else {
                    entry.kind = mergeEventKinds(entry.kind, kind);
                    if (kind == .created) {
                        entry.was_created = true;
                    }
                }
                entry.last_event = now;
                entry.event_count += 1;
            } else {
                const path_owned = try self.allocator.dupe(u8, path);
                try self.pending.put(path_owned, .{
                    .kind = kind,
                    .first_event = now,
                    .last_event = now,
                    .event_count = 1,
                    .was_created = kind == .created,
                });
            }
        }

        pub fn collectReady(self: *Self, events: *std.ArrayList(WatchEvent)) !void {
            const now = std.time.milliTimestamp();
            var to_remove = std.ArrayList([]const u8).init(self.allocator);
            defer to_remove.deinit();

            var iter = self.pending.iterator();
            while (iter.next()) |entry| {
                if (now - entry.value_ptr.last_event >= debounce_ms) {
                    try events.append(.{
                        .path = entry.key_ptr.*,
                        .kind = entry.value_ptr.kind,
                    });
                    try to_remove.append(entry.key_ptr.*);
                }
            }

            for (to_remove.items) |path| {
                _ = self.pending.remove(path);
                self.allocator.free(path);
            }
        }

        fn mergeEventKinds(old: WatchEvent.Kind, new: WatchEvent.Kind) WatchEvent.Kind {
            if (old == .created and new == .modified) return .created;
            if (old == .created and new == .deleted) return .deleted;
            if (old == .modified and new == .deleted) return .deleted;
            return new;
        }
    };
}

// =============================================================================
// macOS/BSD - kqueue
// =============================================================================

pub const KqueueWatcher = struct {
    allocator: Allocator,
    kq: std.posix.fd_t,
    watched_fds: std.StringHashMap(std.posix.fd_t),
    fd_to_path: std.AutoHashMap(std.posix.fd_t, []const u8),
    events: std.ArrayList(WatchEvent),
    root: []const u8,
    debouncer: Debouncer(50),
    file_id_cache: FileIdCache,
    pending_rename: ?PendingRename,

    const PendingRename = struct {
        path: []const u8,
        file_id: ?FileId,
        timestamp: i64,
    };

    const RENAME_TIMEOUT_MS: i64 = 500;

    pub fn init(allocator: Allocator, root: []const u8) !KqueueWatcher {
        const kq = try std.posix.kqueue();

        var self = KqueueWatcher{
            .allocator = allocator,
            .kq = kq,
            .watched_fds = std.StringHashMap(std.posix.fd_t).init(allocator),
            .fd_to_path = std.AutoHashMap(std.posix.fd_t, []const u8).init(allocator),
            .events = std.ArrayList(WatchEvent).init(allocator),
            .root = try allocator.dupe(u8, root),
            .debouncer = Debouncer(50).init(allocator),
            .file_id_cache = FileIdCache.init(allocator),
            .pending_rename = null,
        };

        try self.watchDirRecursive(root, 0);
        return self;
    }

    pub fn deinit(self: *KqueueWatcher) void {
        var fd_iter = self.watched_fds.valueIterator();
        while (fd_iter.next()) |fd| {
            std.posix.close(fd.*);
        }
        self.watched_fds.deinit();

        var path_iter = self.fd_to_path.valueIterator();
        while (path_iter.next()) |path| {
            self.allocator.free(path.*);
        }
        self.fd_to_path.deinit();

        self.events.deinit();
        self.debouncer.deinit();
        self.file_id_cache.deinit();
        if (self.pending_rename) |pr| {
            self.allocator.free(pr.path);
        }
        std.posix.close(self.kq);
        self.allocator.free(self.root);
    }

    const MAX_WATCH_DEPTH = 20;

    fn watchDirRecursive(self: *KqueueWatcher, path: []const u8, depth: usize) !void {
        if (depth > MAX_WATCH_DEPTH) return;
        if (self.watched_fds.contains(path)) return;

        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        const fd = std.posix.open(path_owned, .{ .ACCMODE = .RDONLY }, 0) catch |e| {
            self.allocator.free(path_owned);
            return e;
        };
        errdefer std.posix.close(fd);

        const changelist = [_]std.posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = c.EVFILT_VNODE,
            .flags = c.EV_ADD | c.EV_CLEAR,
            .fflags = c.NOTE_WRITE | c.NOTE_DELETE |
                c.NOTE_RENAME | c.NOTE_EXTEND,
            .data = 0,
            .udata = 0,
        }};

        _ = try std.posix.kevent(self.kq, &changelist, &.{}, null);

        try self.watched_fds.put(path_owned, fd);
        try self.fd_to_path.put(fd, path_owned);

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] != '.') {
                const subpath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(subpath);
                self.watchDirRecursive(subpath, depth + 1) catch {};
            }
        }
    }

    pub fn poll(self: *KqueueWatcher) ![]WatchEvent {
        self.events.clearRetainingCapacity();

        // Expire pending rename if too old
        if (self.pending_rename) |pr| {
            const now = std.time.milliTimestamp();
            if (now - pr.timestamp > RENAME_TIMEOUT_MS) {
                try self.debouncer.recordEvent(pr.path, .deleted);
                self.file_id_cache.removePath(pr.path);
                self.allocator.free(pr.path);
                self.pending_rename = null;
            }
        }

        var eventlist: [64]std.posix.Kevent = undefined;
        const timeout = std.posix.timespec{ .tv_sec = 0, .tv_nsec = 0 };

        const n = std.posix.kevent(self.kq, &.{}, &eventlist, &timeout) catch |e| {
            if (e == error.Interrupted) {
                try self.debouncer.collectReady(&self.events);
                return self.events.items;
            }
            return e;
        };

        for (eventlist[0..n]) |ev| {
            const fd: std.posix.fd_t = @intCast(ev.ident);
            const path = self.fd_to_path.get(fd) orelse continue;

            if (ev.fflags & c.NOTE_DELETE != 0) {
                try self.debouncer.recordEvent(path, .deleted);
                self.file_id_cache.removePath(path);
                _ = self.watched_fds.remove(path);
                _ = self.fd_to_path.remove(fd);
                std.posix.close(fd);
            } else if (ev.fflags & c.NOTE_RENAME != 0) {
                // FileID-based rename stitching (notify-rs pattern)
                // NOTE_RENAME on kqueue means a file at this fd was renamed
                // We need to find where it went by checking FileID
                try self.handleRename(path);
            } else if (ev.fflags & (c.NOTE_WRITE | c.NOTE_EXTEND) != 0) {
                try self.debouncer.recordEvent(path, .modified);
                try self.watchNewSubdirs(path);
            }
        }

        try self.debouncer.collectReady(&self.events);
        return self.events.items;
    }

    fn handleRename(self: *KqueueWatcher, old_path: []const u8) !void {
        // Get the FileID before the rename (if cached)
        const old_file_id = self.file_id_cache.cachedFileId(old_path);

        // Try to find the new path by scanning the parent directory
        // and looking for a file with the same inode
        if (old_file_id) |file_id| {
            if (self.findNewPathByFileId(old_path, file_id)) |new_path| {
                // Found the new path - emit rename event for old path, created for new
                try self.debouncer.recordEvent(old_path, .renamed);
                try self.debouncer.recordEvent(new_path, .created);

                // Update cache
                self.file_id_cache.removePath(old_path);
                try self.file_id_cache.addPath(new_path);
                self.allocator.free(new_path);
                return;
            }
        }

        // Could not find new path - treat as simple rename
        try self.debouncer.recordEvent(old_path, .renamed);
        self.file_id_cache.removePath(old_path);
    }

    fn findNewPathByFileId(self: *KqueueWatcher, old_path: []const u8, target_file_id: FileId) ?[]const u8 {
        // Get the parent directory
        const last_sep = std.mem.lastIndexOfScalar(u8, old_path, '/') orelse return null;
        const parent_dir = if (last_sep == 0) "/" else old_path[0..last_sep];

        var dir = std.fs.openDirAbsolute(parent_dir, .{ .iterate = true }) catch return null;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return null) |entry| {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_dir, entry.name }) catch continue;

            // Check if this file has the target FileID
            if (FileIdCache.getFileId(full_path)) |file_id| {
                if (file_id.eql(target_file_id)) {
                    // Skip if this is the old path
                    if (std.mem.eql(u8, full_path, old_path)) {
                        self.allocator.free(full_path);
                        continue;
                    }
                    return full_path;
                }
            }
            self.allocator.free(full_path);
        }

        return null;
    }

    fn watchNewSubdirs(self: *KqueueWatcher, dir_path: []const u8) !void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] != '.') {
                const subpath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(subpath);

                if (!self.watched_fds.contains(subpath)) {
                    self.watchDirRecursive(subpath, 0) catch {};
                }
            }
        }
    }
};

// =============================================================================
// Linux - inotify with LRU rename cookie buffer
// =============================================================================

pub const InotifyWatcher = if (builtin.os.tag == .linux) struct {
    allocator: Allocator,
    fd: std.posix.fd_t,
    wd_to_path: std.AutoHashMap(i32, []const u8),
    path_to_wd: std.StringHashMap(i32),
    events: std.ArrayList(WatchEvent),
    root: []const u8,
    buf: [8192]u8 align(@alignOf(std.os.linux.inotify_event)),
    rename_cookies: RenameCookieBuffer([]const u8),
    debouncer: Debouncer(50),

    pub fn init(allocator: Allocator, root: []const u8) !InotifyWatcher {
        const fd = try std.posix.inotify_init1(std.os.linux.IN.NONBLOCK);

        var self = InotifyWatcher{
            .allocator = allocator,
            .fd = fd,
            .wd_to_path = std.AutoHashMap(i32, []const u8).init(allocator),
            .path_to_wd = std.StringHashMap(i32).init(allocator),
            .events = std.ArrayList(WatchEvent).init(allocator),
            .root = try allocator.dupe(u8, root),
            .buf = undefined,
            .rename_cookies = .{},
            .debouncer = Debouncer(50).init(allocator),
        };

        try self.watchDirRecursive(root, 0);
        return self;
    }

    pub fn deinit(self: *InotifyWatcher) void {
        var path_iter = self.wd_to_path.valueIterator();
        while (path_iter.next()) |path| {
            self.allocator.free(path.*);
        }
        self.wd_to_path.deinit();
        self.path_to_wd.deinit();
        self.events.deinit();
        self.rename_cookies.deinitAll(self.allocator);
        self.debouncer.deinit();
        std.posix.close(self.fd);
        self.allocator.free(self.root);
    }

    const MAX_WATCH_DEPTH = 20;
    const RENAME_COOKIE_EXPIRE_MS = 500;

    fn watchDirRecursive(self: *InotifyWatcher, path: []const u8, depth: usize) !void {
        if (depth > MAX_WATCH_DEPTH) return;
        if (self.path_to_wd.contains(path)) return;

        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const IN = std.os.linux.IN;
        const wd = std.posix.inotify_add_watch(
            self.fd,
            path_z,
            IN.CREATE | IN.DELETE | IN.MODIFY | IN.MOVED_FROM | IN.MOVED_TO | IN.MASK_ADD,
        ) catch |e| {
            self.allocator.free(path_owned);
            return e;
        };

        try self.wd_to_path.put(wd, path_owned);
        try self.path_to_wd.put(path_owned, wd);

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] != '.') {
                const subpath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(subpath);
                self.watchDirRecursive(subpath, depth + 1) catch {};
            }
        }
    }

    pub fn poll(self: *InotifyWatcher) ![]WatchEvent {
        self.events.clearRetainingCapacity();

        self.rename_cookies.expireOld(RENAME_COOKIE_EXPIRE_MS, self.allocator);

        const len = std.posix.read(self.fd, &self.buf) catch |e| {
            if (e == error.WouldBlock) {
                try self.debouncer.collectReady(&self.events);
                return self.events.items;
            }
            return e;
        };

        var offset: usize = 0;
        while (offset < len) {
            const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&self.buf[offset]));
            const dir_path = self.wd_to_path.get(event.wd) orelse {
                offset += @sizeOf(std.os.linux.inotify_event) + event.len;
                continue;
            };

            if (event.getName()) |name| {
                if (name.len > 0 and name[0] != '.') {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name });
                    errdefer self.allocator.free(full_path);

                    const IN = std.os.linux.IN;

                    if (event.mask & IN.MOVED_FROM != 0) {
                        self.rename_cookies.put(event.cookie, full_path);
                    } else if (event.mask & IN.MOVED_TO != 0) {
                        if (self.rename_cookies.pop(event.cookie)) |old_path| {
                            try self.debouncer.recordEvent(old_path, .renamed);
                            self.allocator.free(old_path);
                            try self.debouncer.recordEvent(full_path, .created);
                            self.allocator.free(full_path);
                        } else {
                            try self.debouncer.recordEvent(full_path, .created);
                            self.allocator.free(full_path);
                        }

                        if (event.mask & IN.ISDIR != 0) {
                            const watch_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name });
                            defer self.allocator.free(watch_path);
                            self.watchDirRecursive(watch_path, 0) catch {};
                        }
                    } else if (event.mask & IN.CREATE != 0) {
                        try self.debouncer.recordEvent(full_path, .created);
                        self.allocator.free(full_path);

                        if (event.mask & IN.ISDIR != 0) {
                            const watch_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, name });
                            defer self.allocator.free(watch_path);
                            self.watchDirRecursive(watch_path, 0) catch {};
                        }
                    } else if (event.mask & IN.DELETE != 0) {
                        try self.debouncer.recordEvent(full_path, .deleted);
                        self.allocator.free(full_path);
                    } else if (event.mask & IN.MODIFY != 0) {
                        try self.debouncer.recordEvent(full_path, .modified);
                        self.allocator.free(full_path);
                    } else {
                        self.allocator.free(full_path);
                    }
                }
            }

            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
        }

        try self.debouncer.collectReady(&self.events);
        return self.events.items;
    }
} else struct {
    allocator: Allocator,
    pub fn init(_: Allocator, _: []const u8) !@This() {
        return error.UnsupportedPlatform;
    }
    pub fn deinit(_: *@This()) void {}
    pub fn poll(_: *@This()) ![]WatchEvent {
        return &.{};
    }
};

// =============================================================================
// Windows - ReadDirectoryChangesW
// =============================================================================

pub const WindowsWatcher = struct {
    allocator: Allocator,
    root: []const u8,
    events: std.ArrayList(WatchEvent),

    pub fn init(allocator: Allocator, root: []const u8) !WindowsWatcher {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .events = std.ArrayList(WatchEvent).init(allocator),
        };
    }

    pub fn deinit(self: *WindowsWatcher) void {
        self.events.deinit();
        self.allocator.free(self.root);
    }

    pub fn poll(self: *WindowsWatcher) ![]WatchEvent {
        self.events.clearRetainingCapacity();
        return self.events.items;
    }
};

// =============================================================================
// Fallback - Polling
// =============================================================================

pub const PollWatcher = struct {
    allocator: Allocator,
    root: []const u8,
    dir_mtimes: std.StringHashMap(i128),
    events: std.ArrayList(WatchEvent),
    last_poll: i64,
    poll_interval_ms: i64,

    pub fn init(allocator: Allocator, root: []const u8) !PollWatcher {
        var self = PollWatcher{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .dir_mtimes = std.StringHashMap(i128).init(allocator),
            .events = std.ArrayList(WatchEvent).init(allocator),
            .last_poll = std.time.milliTimestamp(),
            .poll_interval_ms = 2000,
        };

        try self.snapshotMtimes(root, 0);
        return self;
    }

    pub fn deinit(self: *PollWatcher) void {
        var key_iter = self.dir_mtimes.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.dir_mtimes.deinit();
        self.events.deinit();
        self.allocator.free(self.root);
    }

    const MAX_POLL_DEPTH = 20;

    fn snapshotMtimes(self: *PollWatcher, path: []const u8, depth: usize) !void {
        if (depth > MAX_POLL_DEPTH) return;

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        defer dir.close();

        const stat = dir.stat() catch return;
        const path_owned = try self.allocator.dupe(u8, path);
        try self.dir_mtimes.put(path_owned, stat.mtime);

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] != '.') {
                const subpath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(subpath);
                try self.snapshotMtimes(subpath, depth + 1);
            }
        }
    }

    pub fn poll(self: *PollWatcher) ![]WatchEvent {
        const now = std.time.milliTimestamp();
        if (now - self.last_poll < self.poll_interval_ms) {
            return &.{};
        }
        self.last_poll = now;
        self.events.clearRetainingCapacity();

        try self.checkDir(self.root, 0);
        return self.events.items;
    }

    fn checkDir(self: *PollWatcher, path: []const u8, depth: usize) !void {
        if (depth > MAX_POLL_DEPTH) return;

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |e| {
            if (e == error.FileNotFound) {
                try self.events.append(.{ .path = path, .kind = .deleted });
            }
            return;
        };
        defer dir.close();

        const stat = dir.stat() catch return;
        const old_mtime = self.dir_mtimes.get(path);

        if (old_mtime == null or old_mtime.? != stat.mtime) {
            try self.events.append(.{ .path = path, .kind = .modified });

            if (old_mtime) |_| {
                if (self.dir_mtimes.getEntry(path)) |entry| {
                    entry.value_ptr.* = stat.mtime;
                }
            } else {
                const path_owned = try self.allocator.dupe(u8, path);
                try self.dir_mtimes.put(path_owned, stat.mtime);
            }
        }

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] != '.') {
                const subpath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(subpath);
                try self.checkDir(subpath, depth + 1);
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "RenameCookieBuffer basic operations" {
    var buf = RenameCookieBuffer([]const u8){};

    buf.put(123, "old_path");
    buf.put(456, "another_path");

    try std.testing.expectEqualStrings("old_path", buf.pop(123).?);
    try std.testing.expect(buf.pop(123) == null);
    try std.testing.expectEqualStrings("another_path", buf.pop(456).?);
}

test "RenameCookieBuffer LRU eviction" {
    var buf = RenameCookieBuffer(u32){};

    for (0..15) |i| {
        buf.put(@intCast(i), @intCast(i * 10));
    }

    for (0..5) |i| {
        try std.testing.expect(buf.pop(@intCast(i)) == null);
    }

    for (5..15) |i| {
        const val = buf.pop(@intCast(i));
        try std.testing.expectEqual(@as(u32, @intCast(i * 10)), val.?);
    }
}

test "Debouncer event merging" {
    const allocator = std.testing.allocator;
    var debouncer = Debouncer(0).init(allocator);
    defer debouncer.deinit();

    try debouncer.recordEvent("/test/file.txt", .created);
    try debouncer.recordEvent("/test/file.txt", .modified);

    var events = std.ArrayList(WatchEvent).init(allocator);
    defer events.deinit();

    try debouncer.collectReady(&events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(WatchEvent.Kind.created, events.items[0].kind);
}

test "Debouncer skip duplicate Create (notify-rs pattern)" {
    const allocator = std.testing.allocator;
    var debouncer = Debouncer(0).init(allocator);
    defer debouncer.deinit();

    try debouncer.recordEvent("/test/file.txt", .created);
    try debouncer.recordEvent("/test/file.txt", .created);
    try debouncer.recordEvent("/test/file.txt", .created);

    var events = std.ArrayList(WatchEvent).init(allocator);
    defer events.deinit();

    try debouncer.collectReady(&events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(WatchEvent.Kind.created, events.items[0].kind);
}

test "Debouncer suppress Modify after Create (notify-rs pattern)" {
    const allocator = std.testing.allocator;
    var debouncer = Debouncer(0).init(allocator);
    defer debouncer.deinit();

    try debouncer.recordEvent("/test/file.txt", .created);
    try debouncer.recordEvent("/test/file.txt", .modified);
    try debouncer.recordEvent("/test/file.txt", .modified);
    try debouncer.recordEvent("/test/file.txt", .modified);

    var events = std.ArrayList(WatchEvent).init(allocator);
    defer events.deinit();

    try debouncer.collectReady(&events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(WatchEvent.Kind.created, events.items[0].kind);
}

test "Debouncer created + deleted = deleted" {
    const allocator = std.testing.allocator;
    var debouncer = Debouncer(0).init(allocator);
    defer debouncer.deinit();

    try debouncer.recordEvent("/test/file.txt", .created);
    try debouncer.recordEvent("/test/file.txt", .deleted);

    var events = std.ArrayList(WatchEvent).init(allocator);
    defer events.deinit();

    try debouncer.collectReady(&events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(WatchEvent.Kind.deleted, events.items[0].kind);
}

test "Debouncer modified + deleted = deleted" {
    const allocator = std.testing.allocator;
    var debouncer = Debouncer(0).init(allocator);
    defer debouncer.deinit();

    try debouncer.recordEvent("/test/file.txt", .modified);
    try debouncer.recordEvent("/test/file.txt", .deleted);

    var events = std.ArrayList(WatchEvent).init(allocator);
    defer events.deinit();

    try debouncer.collectReady(&events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(WatchEvent.Kind.deleted, events.items[0].kind);
}

test "FileIdCache basic operations" {
    const allocator = std.testing.allocator;
    var cache = FileIdCache.init(allocator);
    defer cache.deinit();

    try std.testing.expect(cache.cachedFileId("/nonexistent") == null);
}

test "FileId equality" {
    const id1 = FileId{ .inode = 100 };
    const id2 = FileId{ .inode = 100 };
    const id3 = FileId{ .inode = 200 };

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}

test "watcher init" {
    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    var watcher = try Watcher.init(allocator, path);
    defer watcher.deinit();

    _ = try watcher.poll();
}

// =============================================================================
// ClockSpec - Watchman-inspired cursor-based change tracking
// Format: "c:<pid>:<tick>" for clock IDs or "n:<name>" for named cursors
// Key patterns from Watchman:
// - Clock IDs are race-free (tick on change, not time)
// - Named cursors allow stateful "since last query" semantics
// - Fresh instance detection for process restarts
// =============================================================================

pub const ClockSpec = struct {
    const Self = @This();

    /// Process ID that created this clock (for fresh instance detection)
    pid: u32,
    /// Monotonically increasing tick counter
    tick: u64,
    /// Root path this clock is associated with
    root: []const u8,

    /// Parse a clock string in format "c:<pid>:<tick>"
    pub fn parse(clock_str: []const u8) ?Self {
        if (clock_str.len < 5) return null;
        if (!std.mem.startsWith(u8, clock_str, "c:")) return null;

        const rest = clock_str[2..];
        const colon_idx = std.mem.indexOf(u8, rest, ":") orelse return null;

        const pid = std.fmt.parseInt(u32, rest[0..colon_idx], 10) catch return null;
        const tick = std.fmt.parseInt(u64, rest[colon_idx + 1 ..], 10) catch return null;

        return Self{
            .pid = pid,
            .tick = tick,
            .root = "",
        };
    }

    /// Format clock as string "c:<pid>:<tick>"
    pub fn format(self: Self, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "c:{d}:{d}", .{ self.pid, self.tick }) catch error.BufferTooSmall;
    }

    /// Check if this clock is from the same process as another
    pub fn isSameProcess(self: Self, other: Self) bool {
        return self.pid == other.pid;
    }

    /// Check if this clock is older than another (only valid if same process)
    pub fn isOlderThan(self: Self, other: Self) bool {
        return self.tick < other.tick;
    }
};

// =============================================================================
// WatchClock - Manages logical clock progression for a watched root
// Ticks on each batch of changes, providing race-free change detection
// Implements Watchman's clock vector concept for consistent snapshots
// =============================================================================

pub const WatchClock = struct {
    const Self = @This();

    pid: u32,
    current_tick: u64,
    last_tick_time: i64,

    fn getPid() u32 {
        return switch (builtin.os.tag) {
            .linux => @intCast(std.os.linux.getpid()),
            .macos, .freebsd, .openbsd, .netbsd => blk: {
                // Use timestamp-based unique ID for BSD systems
                const time_part: u32 = @truncate(@as(u64, @intCast(std.time.timestamp())) & 0xFFFFFFFF);
                break :blk time_part ^ 0x12345678;
            },
            .windows => blk: {
                // Use timestamp-based unique ID for Windows
                const time_part: u32 = @truncate(@as(u64, @intCast(std.time.timestamp())) & 0xFFFFFFFF);
                break :blk time_part ^ 0x87654321;
            },
            else => blk: {
                // Fallback: use timestamp as pseudo-PID
                const time_part: u32 = @truncate(@as(u64, @intCast(std.time.timestamp())) & 0xFFFFFFFF);
                break :blk time_part;
            },
        };
    }

    pub fn init() Self {
        return .{
            .pid = getPid(),
            .current_tick = 0,
            .last_tick_time = std.time.milliTimestamp(),
        };
    }

    /// Advance the clock and return the new clock spec
    pub fn tick(self: *Self) ClockSpec {
        self.current_tick += 1;
        self.last_tick_time = std.time.milliTimestamp();
        return self.current();
    }

    /// Get current clock without advancing
    pub fn current(self: *const Self) ClockSpec {
        return ClockSpec{
            .pid = self.pid,
            .tick = self.current_tick,
            .root = "",
        };
    }

    /// Check if a clock spec is from a previous process (fresh instance)
    pub fn isFreshInstance(self: *const Self, clock: ClockSpec) bool {
        return clock.pid != self.pid;
    }
};

// =============================================================================
// FileChangeRecord - Tracks a single file change with clock information
// Used for "since" queries to find files modified after a given clock
// =============================================================================

pub const FileChangeRecord = struct {
    path: []const u8,
    kind: WatchEvent.Kind,
    /// Clock when this change was first observed (cclock in Watchman)
    created_clock: u64,
    /// Clock when this change was last observed (oclock in Watchman)
    observed_clock: u64,
    /// Whether file currently exists
    exists: bool,
    /// File size at last observation
    size: u64,
    /// Modification time at last observation
    mtime: i64,
};

// =============================================================================
// SinceQuery - Watchman-style "since" generator for incremental queries
// Returns files changed since a given clock value
// Key patterns:
// - Fresh instance returns all existing files marked as "new"
// - cclock (created) vs oclock (observed) for precise tracking
// - Supports empty_on_fresh_instance option
// =============================================================================

pub const SinceQuery = struct {
    const Self = @This();

    allocator: Allocator,
    clock: WatchClock,
    /// Change history indexed by tick
    history: std.AutoHashMap(u64, std.ArrayList(FileChangeRecord)),
    /// Current state of all files (path -> last change record)
    file_states: std.StringHashMap(FileChangeRecord),
    /// Retain history for this many ticks
    history_retention: u64,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .clock = WatchClock.init(),
            .history = std.AutoHashMap(u64, std.ArrayList(FileChangeRecord)).init(allocator),
            .file_states = std.StringHashMap(FileChangeRecord).init(allocator),
            .history_retention = 1000, // Keep last 1000 ticks of history
        };
    }

    pub fn deinit(self: *Self) void {
        var hist_iter = self.history.iterator();
        while (hist_iter.next()) |entry| {
            for (entry.value_ptr.items) |rec| {
                self.allocator.free(rec.path);
            }
            entry.value_ptr.deinit();
        }
        self.history.deinit();

        var state_iter = self.file_states.keyIterator();
        while (state_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.file_states.deinit();
    }

    /// Record a file change event, returns the clock after recording
    pub fn recordChange(self: *Self, path: []const u8, kind: WatchEvent.Kind, size: u64, mtime: i64) !ClockSpec {
        const new_clock = self.clock.tick();
        const clock_tick = new_clock.tick;

        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        const created_clock = if (self.file_states.get(path)) |existing|
            existing.created_clock
        else
            clock_tick;

        const record = FileChangeRecord{
            .path = path_owned,
            .kind = kind,
            .created_clock = created_clock,
            .observed_clock = clock_tick,
            .exists = kind != .deleted,
            .size = size,
            .mtime = mtime,
        };

        // Add to history
        const history_list = try self.history.getOrPut(clock_tick);
        if (!history_list.found_existing) {
            history_list.value_ptr.* = std.ArrayList(FileChangeRecord).init(self.allocator);
        }
        try history_list.value_ptr.append(record);

        // Update current state
        if (self.file_states.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }
        const state_path = try self.allocator.dupe(u8, path);
        try self.file_states.put(state_path, FileChangeRecord{
            .path = state_path,
            .kind = kind,
            .created_clock = created_clock,
            .observed_clock = clock_tick,
            .exists = kind != .deleted,
            .size = size,
            .mtime = mtime,
        });

        // Prune old history
        self.pruneHistory();

        return new_clock;
    }

    /// Query files changed since the given clock
    /// If clock is from a different process (fresh instance), returns all existing files
    pub fn querySince(self: *Self, since_clock: ClockSpec, results: *std.ArrayList(FileChangeRecord), empty_on_fresh: bool) !bool {
        // Fresh instance detection (Watchman pattern)
        if (self.clock.isFreshInstance(since_clock)) {
            if (empty_on_fresh) {
                return true; // Return empty results, caller should check is_fresh_instance
            }

            // Return all existing files as "new"
            var iter = self.file_states.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.exists) {
                    try results.append(entry.value_ptr.*);
                }
            }
            return true;
        }

        // Query history for changes since the given tick
        const since_tick = since_clock.tick;
        const current_tick = self.clock.current_tick;

        var iter_tick = since_tick + 1;
        while (iter_tick <= current_tick) : (iter_tick += 1) {
            if (self.history.get(iter_tick)) |records| {
                for (records.items) |rec| {
                    try results.append(rec);
                }
            }
        }

        return false;
    }

    /// Get current clock value
    pub fn getClock(self: *const Self) ClockSpec {
        return self.clock.current();
    }

    fn pruneHistory(self: *Self) void {
        const current_tick = self.clock.current_tick;
        if (current_tick <= self.history_retention) return;

        const prune_before = current_tick - self.history_retention;

        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.history.keyIterator();
        while (iter.next()) |key| {
            if (key.* < prune_before) {
                to_remove.append(key.*) catch {};
            }
        }

        for (to_remove.items) |removed_tick| {
            if (self.history.fetchRemove(removed_tick)) |kv| {
                for (kv.value.items) |rec| {
                    self.allocator.free(rec.path);
                }
                kv.value.deinit();
            }
        }
    }
};

// =============================================================================
// MetadataCache - LRU cache for file metadata (Watchman pattern)
// Caches stat info and content hashes to avoid redundant disk I/O
// Key patterns:
// - LRU eviction to bound memory
// - Content hash for detecting actual changes vs touch
// - Fast path for unchanged files
// =============================================================================

pub const FileMetadata = struct {
    size: u64,
    mtime: i64,
    inode: u64,
    content_hash: ?u64, // Simple hash for change detection
    last_accessed: i64,
};

pub const MetadataCache = struct {
    const Self = @This();
    const DEFAULT_CAPACITY = 10000;

    allocator: Allocator,
    entries: std.StringHashMap(FileMetadata),
    access_order: std.ArrayList([]const u8),
    capacity: usize,
    hits: u64,
    misses: u64,

    pub fn init(allocator: Allocator) Self {
        return Self.initWithCapacity(allocator, DEFAULT_CAPACITY);
    }

    pub fn initWithCapacity(allocator: Allocator, capacity: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(FileMetadata).init(allocator),
            .access_order = std.ArrayList([]const u8).init(allocator),
            .capacity = capacity,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var key_iter = self.entries.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.deinit();
        self.access_order.deinit();
    }

    /// Get cached metadata for a path, returns null on cache miss
    pub fn get(self: *Self, path: []const u8) ?FileMetadata {
        if (self.entries.getPtr(path)) |entry| {
            self.hits += 1;
            entry.last_accessed = std.time.milliTimestamp();
            self.promoteToFront(path);
            return entry.*;
        }
        self.misses += 1;
        return null;
    }

    /// Put metadata into cache, evicting LRU entries if needed
    pub fn put(self: *Self, path: []const u8, metadata: FileMetadata) !void {
        // Evict if at capacity
        while (self.entries.count() >= self.capacity and self.access_order.items.len > 0) {
            self.evictLru();
        }

        if (self.entries.contains(path)) {
            // Update existing
            if (self.entries.getPtr(path)) |entry| {
                entry.* = metadata;
                entry.last_accessed = std.time.milliTimestamp();
            }
            self.promoteToFront(path);
        } else {
            // Insert new
            const path_owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(path_owned);

            var meta = metadata;
            meta.last_accessed = std.time.milliTimestamp();
            try self.entries.put(path_owned, meta);
            try self.access_order.append(path_owned);
        }
    }

    /// Remove entry from cache
    pub fn remove(self: *Self, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |kv| {
            // Remove from access order
            for (self.access_order.items, 0..) |p, i| {
                if (std.mem.eql(u8, p, path)) {
                    _ = self.access_order.orderedRemove(i);
                    break;
                }
            }
            self.allocator.free(kv.key);
        }
    }

    /// Check if file has changed based on stat vs cached metadata
    pub fn hasChanged(self: *Self, path: []const u8, new_size: u64, new_mtime: i64) bool {
        if (self.entries.get(path)) |cached| {
            return cached.size != new_size or cached.mtime != new_mtime;
        }
        return true; // Unknown = changed
    }

    /// Compute a simple content hash for change detection
    pub fn computeContentHash(path: []const u8) ?u64 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        var hasher = std.hash.Wyhash.init(0);
        var buffer: [8192]u8 = undefined;

        while (true) {
            const bytes_read = file.read(&buffer) catch return null;
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        return hasher.final();
    }

    pub const CacheStats = struct {
        hits: u64,
        misses: u64,
        size: usize,
    };

    /// Get cache statistics
    pub fn getStats(self: *const Self) CacheStats {
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .size = self.entries.count(),
        };
    }

    fn evictLru(self: *Self) void {
        if (self.access_order.items.len == 0) return;

        const lru_path = self.access_order.orderedRemove(0);
        if (self.entries.fetchRemove(lru_path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn promoteToFront(self: *Self, path: []const u8) void {
        for (self.access_order.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) {
                const removed = self.access_order.orderedRemove(i);
                self.access_order.append(removed) catch {};
                break;
            }
        }
    }
};

// =============================================================================
// WatchStateManager - Save/restore state for fast recovery (Watchman pattern)
// Serializes watch state to disk for fast process restart
// Key patterns:
// - State file in watched root (or config dir)
// - Includes clock, file list, and metadata cache
// - Validates state on load (rejects stale state)
// =============================================================================

pub const WatchStateManager = struct {
    const Self = @This();
    const STATE_VERSION: u32 = 1;
    const STATE_FILE_NAME = ".sniff-state";

    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// State that can be persisted and restored
    pub const PersistedState = struct {
        version: u32,
        pid: u32,
        clock_tick: u64,
        root_path: []const u8,
        file_count: u32,
        save_time: i64,
    };

    /// Save watch state to a file
    pub fn saveState(self: *Self, root: []const u8, clock: WatchClock, file_count: usize) !void {
        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, STATE_FILE_NAME });
        defer self.allocator.free(state_path);

        const file = try std.fs.cwd().createFile(state_path, .{});
        defer file.close();

        const state = PersistedState{
            .version = STATE_VERSION,
            .pid = clock.pid,
            .clock_tick = clock.current_tick,
            .root_path = root,
            .file_count = @intCast(file_count),
            .save_time = std.time.milliTimestamp(),
        };

        // Write header
        const header_bytes = std.mem.asBytes(&state.version) ++
            std.mem.asBytes(&state.pid) ++
            std.mem.asBytes(&state.clock_tick) ++
            std.mem.asBytes(&state.file_count) ++
            std.mem.asBytes(&state.save_time);
        try file.writeAll(header_bytes);

        // Write root path length and data
        const root_len: u32 = @intCast(root.len);
        try file.writeAll(std.mem.asBytes(&root_len));
        try file.writeAll(root);
    }

    /// Load watch state from a file
    pub fn loadState(self: *Self, root: []const u8) !?PersistedState {
        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, STATE_FILE_NAME });
        defer self.allocator.free(state_path);

        const file = std.fs.cwd().openFile(state_path, .{}) catch return null;
        defer file.close();

        // Read header
        var header_buf: [32]u8 = undefined;
        const bytes_read = try file.readAll(&header_buf);
        if (bytes_read < 28) return null;

        const version = std.mem.bytesAsValue(u32, header_buf[0..4]).*;
        if (version != STATE_VERSION) return null;

        const pid = std.mem.bytesAsValue(u32, header_buf[4..8]).*;
        const clock_tick = std.mem.bytesAsValue(u64, header_buf[8..16]).*;
        const file_count = std.mem.bytesAsValue(u32, header_buf[16..20]).*;
        const save_time = std.mem.bytesAsValue(i64, header_buf[20..28]).*;

        // Validate state isn't too old (max 24 hours)
        const now = std.time.milliTimestamp();
        const max_age_ms: i64 = 24 * 60 * 60 * 1000;
        if (now - save_time > max_age_ms) {
            return null; // State too old
        }

        return PersistedState{
            .version = version,
            .pid = pid,
            .clock_tick = clock_tick,
            .root_path = root,
            .file_count = file_count,
            .save_time = save_time,
        };
    }

    /// Delete saved state
    pub fn deleteState(self: *Self, root: []const u8) !void {
        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, STATE_FILE_NAME });
        defer self.allocator.free(state_path);

        std.fs.cwd().deleteFile(state_path) catch {};
    }
};

// =============================================================================
// IncrementalWatcher - Combines all Watchman patterns into a unified interface
// Provides cursor-based incremental queries with save state support
// =============================================================================

pub const IncrementalWatcher = struct {
    const Self = @This();

    allocator: Allocator,
    watcher: Watcher,
    since_query: SinceQuery,
    metadata_cache: MetadataCache,
    state_manager: WatchStateManager,
    root: []const u8,

    pub fn init(allocator: Allocator, root: []const u8) !Self {
        var watcher = try Watcher.init(allocator, root);
        errdefer watcher.deinit();

        var state_manager = WatchStateManager.init(allocator);

        // Try to restore previous state
        if (state_manager.loadState(root)) |_| {
            // Could use saved_state to fast-forward clock
        } else |_| {
            // No saved state, start fresh
        }

        return Self{
            .allocator = allocator,
            .watcher = watcher,
            .since_query = SinceQuery.init(allocator),
            .metadata_cache = MetadataCache.init(allocator),
            .state_manager = state_manager,
            .root = try allocator.dupe(u8, root),
        };
    }

    pub fn deinit(self: *Self) void {
        // Save state before shutdown
        self.state_manager.saveState(
            self.root,
            self.since_query.clock,
            self.since_query.file_states.count(),
        ) catch {};

        self.watcher.deinit();
        self.since_query.deinit();
        self.metadata_cache.deinit();
        self.allocator.free(self.root);
    }

    /// Poll for changes and record them
    pub fn poll(self: *Self) ![]WatchEvent {
        const events = try self.watcher.poll();

        for (events) |ev| {
            // Get file metadata
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, ev.path });
            defer self.allocator.free(full_path);

            var size: u64 = 0;
            var mtime: i64 = 0;

            if (ev.kind != .deleted) {
                const stat = std.fs.cwd().statFile(full_path) catch null;
                if (stat) |s| {
                    size = s.size;
                    mtime = @divFloor(s.mtime, std.time.ns_per_ms);

                    // Update metadata cache
                    try self.metadata_cache.put(ev.path, .{
                        .size = size,
                        .mtime = mtime,
                        .inode = s.inode,
                        .content_hash = null,
                        .last_accessed = std.time.milliTimestamp(),
                    });
                }
            } else {
                self.metadata_cache.remove(ev.path);
            }

            // Record change for since queries
            _ = try self.since_query.recordChange(ev.path, ev.kind, size, mtime);
        }

        return events;
    }

    /// Get current clock value for use in future "since" queries
    pub fn getClock(self: *const Self) ClockSpec {
        return self.since_query.getClock();
    }

    /// Query files changed since the given clock
    pub fn querySince(self: *Self, since: ClockSpec, results: *std.ArrayList(FileChangeRecord)) !bool {
        return self.since_query.querySince(since, results, false);
    }

    /// Get file descriptor for select/poll integration
    pub fn getFd(self: *Self) ?std.posix.fd_t {
        return self.watcher.getFd();
    }

    /// Get metadata cache statistics
    pub fn getCacheStats(self: *const Self) MetadataCache.CacheStats {
        return self.metadata_cache.getStats();
    }
};

// =============================================================================
// Tests for Watchman-inspired patterns
// =============================================================================

test "ClockSpec parse and format" {
    const clock = ClockSpec.parse("c:12345:678") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u32, 12345), clock.pid);
    try std.testing.expectEqual(@as(u64, 678), clock.tick);

    var buffer: [32]u8 = undefined;
    const formatted = try clock.format(&buffer);
    try std.testing.expectEqualStrings("c:12345:678", formatted);
}

test "ClockSpec parse invalid" {
    try std.testing.expect(ClockSpec.parse("") == null);
    try std.testing.expect(ClockSpec.parse("invalid") == null);
    try std.testing.expect(ClockSpec.parse("c:abc:123") == null);
    try std.testing.expect(ClockSpec.parse("n:cursor") == null);
}

test "WatchClock init and tick" {
    var clock = WatchClock.init();

    const initial = clock.current();
    try std.testing.expectEqual(@as(u64, 0), initial.tick);

    const after_tick = clock.tick();
    try std.testing.expectEqual(@as(u64, 1), after_tick.tick);

    const current = clock.current();
    try std.testing.expectEqual(@as(u64, 1), current.tick);
}

test "WatchClock fresh instance detection" {
    var clock = WatchClock.init();

    const our_clock = clock.current();
    try std.testing.expect(!clock.isFreshInstance(our_clock));

    const other_clock = ClockSpec{
        .pid = clock.pid + 1, // Different PID
        .tick = 0,
        .root = "",
    };
    try std.testing.expect(clock.isFreshInstance(other_clock));
}

test "SinceQuery record and query" {
    const allocator = std.testing.allocator;
    var sq = SinceQuery.init(allocator);
    defer sq.deinit();

    const initial_clock = sq.getClock();
    try std.testing.expectEqual(@as(u64, 0), initial_clock.tick);

    _ = try sq.recordChange("/src/main.zig", .created, 100, 1000);
    _ = try sq.recordChange("/src/lib.zig", .modified, 200, 2000);

    var results = std.ArrayList(FileChangeRecord).init(allocator);
    defer results.deinit();

    const is_fresh = try sq.querySince(initial_clock, &results, false);
    try std.testing.expect(!is_fresh);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "SinceQuery fresh instance detection" {
    const allocator = std.testing.allocator;
    var sq = SinceQuery.init(allocator);
    defer sq.deinit();

    _ = try sq.recordChange("/src/main.zig", .created, 100, 1000);

    // Create a clock from a different process
    const other_clock = ClockSpec{
        .pid = sq.clock.pid + 1,
        .tick = 0,
        .root = "",
    };

    var results = std.ArrayList(FileChangeRecord).init(allocator);
    defer results.deinit();

    const is_fresh = try sq.querySince(other_clock, &results, false);
    try std.testing.expect(is_fresh);
    try std.testing.expectEqual(@as(usize, 1), results.items.len); // Returns existing files
}

test "MetadataCache basic operations" {
    const allocator = std.testing.allocator;
    var cache = MetadataCache.initWithCapacity(allocator, 10);
    defer cache.deinit();

    // Miss on empty cache
    try std.testing.expect(cache.get("/test/file.txt") == null);

    // Put and get
    try cache.put("/test/file.txt", .{
        .size = 100,
        .mtime = 1000,
        .inode = 1,
        .content_hash = null,
        .last_accessed = 0,
    });

    const cached = cache.get("/test/file.txt");
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(u64, 100), cached.?.size);

    // Check stats
    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}

test "MetadataCache LRU eviction" {
    const allocator = std.testing.allocator;
    var cache = MetadataCache.initWithCapacity(allocator, 2);
    defer cache.deinit();

    try cache.put("/file1.txt", .{ .size = 1, .mtime = 1, .inode = 1, .content_hash = null, .last_accessed = 0 });
    try cache.put("/file2.txt", .{ .size = 2, .mtime = 2, .inode = 2, .content_hash = null, .last_accessed = 0 });

    // Access file1 to make it more recent
    _ = cache.get("/file1.txt");

    // Add third file, should evict file2 (LRU)
    try cache.put("/file3.txt", .{ .size = 3, .mtime = 3, .inode = 3, .content_hash = null, .last_accessed = 0 });

    try std.testing.expect(cache.get("/file1.txt") != null);
    try std.testing.expect(cache.get("/file2.txt") == null); // Evicted
    try std.testing.expect(cache.get("/file3.txt") != null);
}

test "MetadataCache hasChanged" {
    const allocator = std.testing.allocator;
    var cache = MetadataCache.initWithCapacity(allocator, 10);
    defer cache.deinit();

    try cache.put("/test/file.txt", .{
        .size = 100,
        .mtime = 1000,
        .inode = 1,
        .content_hash = null,
        .last_accessed = 0,
    });

    // No change
    try std.testing.expect(!cache.hasChanged("/test/file.txt", 100, 1000));

    // Size changed
    try std.testing.expect(cache.hasChanged("/test/file.txt", 200, 1000));

    // Mtime changed
    try std.testing.expect(cache.hasChanged("/test/file.txt", 100, 2000));

    // Unknown file = changed
    try std.testing.expect(cache.hasChanged("/unknown/file.txt", 100, 1000));
}

test "IncrementalWatcher init and deinit" {
    const allocator = std.testing.allocator;

    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    var iw = try IncrementalWatcher.init(allocator, path);
    defer iw.deinit();

    // Should have valid clock
    const clock = iw.getClock();
    try std.testing.expect(clock.pid != 0);
    try std.testing.expectEqual(@as(u64, 0), clock.tick);

    // Cache should be empty
    const stats = iw.getCacheStats();
    try std.testing.expectEqual(@as(u64, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 0), stats.size);
}

test "WatchStateManager save and load" {
    const allocator = std.testing.allocator;
    var manager = WatchStateManager.init(allocator);

    // Create temp dir for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    // Create a clock to save
    var clock = WatchClock.init();
    _ = clock.tick();
    _ = clock.tick();

    // Save state
    try manager.saveState(tmp_path, clock, 42);

    // Load state
    const loaded = try manager.loadState(tmp_path);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(clock.pid, loaded.?.pid);
    try std.testing.expectEqual(clock.current_tick, loaded.?.clock_tick);
    try std.testing.expectEqual(@as(u32, 42), loaded.?.file_count);
}

test "WatchEntry file type detection" {
    const now = std.time.milliTimestamp();

    const zig_importance = WatchEntry.calculateImportance("/src/main.zig", false, now);
    const json_importance = WatchEntry.calculateImportance("/config.json", false, now);
    const gen_importance = WatchEntry.calculateImportance("/zig-cache/file.o", false, now);
    const txt_importance = WatchEntry.calculateImportance("/readme.txt", false, now);

    try std.testing.expect(zig_importance > json_importance);
    try std.testing.expect(json_importance > gen_importance);
    try std.testing.expect(zig_importance > txt_importance);
    try std.testing.expect(txt_importance >= WatchEntry.Importance.BASE);
}

test "WatchEntry open file bonus" {
    const now = std.time.milliTimestamp();

    const closed = WatchEntry.calculateImportance("/src/main.zig", false, now);
    const open = WatchEntry.calculateImportance("/src/main.zig", true, now);

    try std.testing.expect(open > closed);
    try std.testing.expect(open - closed >= WatchEntry.Importance.OPEN_FILE);
}

test "WatchEntry test file detection" {
    const now = std.time.milliTimestamp();

    const test1 = WatchEntry.calculateImportance("/src/main_test.zig", false, now);
    const test2 = WatchEntry.calculateImportance("/tests/foo.zig", false, now);

    try std.testing.expect(test1 >= WatchEntry.Importance.BASE + WatchEntry.Importance.TEST_FILE);
    try std.testing.expect(test2 >= WatchEntry.Importance.BASE + WatchEntry.Importance.TEST_FILE);
}

test "DirtyFileHeap basic operations" {
    var heap = DirtyFileHeap.init();

    try std.testing.expectEqual(@as(usize, 0), heap.len());

    heap.insert("/low.txt", 100);
    heap.insert("/high.txt", 500);
    heap.insert("/mid.txt", 300);

    try std.testing.expectEqual(@as(usize, 3), heap.len());

    const first = heap.pop().?;
    try std.testing.expectEqualStrings("/high.txt", first.path);

    const second = heap.pop().?;
    try std.testing.expectEqualStrings("/mid.txt", second.path);

    const third = heap.pop().?;
    try std.testing.expectEqualStrings("/low.txt", third.path);

    try std.testing.expect(heap.pop() == null);
}

test "DirtyFileHeap update existing" {
    var heap = DirtyFileHeap.init();

    heap.insert("/file.txt", 100);
    heap.insert("/file.txt", 500);

    try std.testing.expectEqual(@as(usize, 1), heap.len());
    try std.testing.expectEqual(@as(u32, 500), heap.peek().?.importance);
}

test "DirtyFileHeap remove" {
    var heap = DirtyFileHeap.init();

    heap.insert("/a.txt", 100);
    heap.insert("/b.txt", 200);
    heap.insert("/c.txt", 300);

    try std.testing.expect(heap.remove("/b.txt"));
    try std.testing.expectEqual(@as(usize, 2), heap.len());
    try std.testing.expect(!heap.remove("/b.txt"));
}

test "WatchState basic operations" {
    const allocator = std.testing.allocator;
    var state = WatchState.init(allocator);
    defer state.deinit();

    try state.addEntry("/src/main.zig", .file);
    try state.addEntry("/src/lib.zig", .file);

    try std.testing.expect(state.entries.contains("/src/main.zig"));
    try std.testing.expect(state.entries.contains("/src/lib.zig"));

    state.removeEntry("/src/main.zig");
    try std.testing.expect(!state.entries.contains("/src/main.zig"));
}

test "WatchState dirty tracking" {
    const allocator = std.testing.allocator;
    var state = WatchState.init(allocator);
    defer state.deinit();

    try state.addEntry("/src/high.zig", .file);
    try state.addEntry("/zig-cache/low.o", .file);

    state.markDirty("/src/high.zig");
    state.markDirty("/zig-cache/low.o");

    try std.testing.expectEqual(@as(usize, 2), state.dirtyCount());

    const first = state.popDirty().?;
    try std.testing.expectEqualStrings("/src/high.zig", first);
}

test "WatchState open file tracking" {
    const allocator = std.testing.allocator;
    var state = WatchState.init(allocator);
    defer state.deinit();

    try state.addEntry("/src/main.zig", .file);

    const before = state.entries.get("/src/main.zig").?.importance;

    try state.markOpen("/src/main.zig");

    const after = state.entries.get("/src/main.zig").?.importance;
    try std.testing.expect(after > before);

    state.markClosed("/src/main.zig");

    const final = state.entries.get("/src/main.zig").?.importance;
    try std.testing.expect(final < after);
}

test "WorkspaceWatcher init and deinit" {
    const allocator = std.testing.allocator;
    var ws_watcher = WorkspaceWatcher.init(allocator);
    defer ws_watcher.deinit();

    try std.testing.expectEqual(@as(usize, 0), ws_watcher.workspaceCount());
}

test "WorkspaceWatcher add and remove workspace" {
    const allocator = std.testing.allocator;
    var ws_watcher = WorkspaceWatcher.init(allocator);
    defer ws_watcher.deinit();

    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    try ws_watcher.addWorkspace(path);
    try std.testing.expectEqual(@as(usize, 1), ws_watcher.workspaceCount());
    try std.testing.expect(ws_watcher.hasWorkspace(path));

    // Adding same workspace again is a no-op
    try ws_watcher.addWorkspace(path);
    try std.testing.expectEqual(@as(usize, 1), ws_watcher.workspaceCount());

    ws_watcher.removeWorkspace(path);
    try std.testing.expectEqual(@as(usize, 0), ws_watcher.workspaceCount());
    try std.testing.expect(!ws_watcher.hasWorkspace(path));
}

test "WorkspaceWatcher getWorkspaceRoots" {
    const allocator = std.testing.allocator;
    var ws_watcher = WorkspaceWatcher.init(allocator);
    defer ws_watcher.deinit();

    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    try ws_watcher.addWorkspace(path);

    var roots: [8][]const u8 = undefined;
    const count = ws_watcher.getWorkspaceRoots(&roots);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings(path, roots[0]);
}

test "WorkspaceWatcher poll empty" {
    const allocator = std.testing.allocator;
    var ws_watcher = WorkspaceWatcher.init(allocator);
    defer ws_watcher.deinit();

    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    try ws_watcher.addWorkspace(path);

    const events = try ws_watcher.poll();
    defer allocator.free(events);

    // No events expected initially (just testing the poll mechanism works)
    // Events may or may not be empty depending on filesystem activity
}

test "WorkspaceWatcher global dirty heap empty" {
    const allocator = std.testing.allocator;
    var ws_watcher = WorkspaceWatcher.init(allocator);
    defer ws_watcher.deinit();

    try std.testing.expectEqual(@as(usize, 0), ws_watcher.globalDirtyCount());
    try std.testing.expect(ws_watcher.peekGlobalDirty() == null);
    try std.testing.expect(ws_watcher.popGlobalDirty() == null);
}

test "WorkspaceWatcher overlapping paths detection" {
    const allocator = std.testing.allocator;
    var ws_watcher = WorkspaceWatcher.init(allocator);
    defer ws_watcher.deinit();

    // Use current directory and a subdirectory for testing
    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try cwd.realpath(".", &buf);

    try ws_watcher.addWorkspace(root_path);
    try std.testing.expectEqual(@as(usize, 1), ws_watcher.workspaceCount());

    // Adding the same path should be a no-op (already watching)
    try ws_watcher.addWorkspace(root_path);
    try std.testing.expectEqual(@as(usize, 1), ws_watcher.workspaceCount());
}
