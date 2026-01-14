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
