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
// Debounce state for per-path event coalescing
// =============================================================================

pub const DebounceEntry = struct {
    kind: WatchEvent.Kind,
    last_event: i64,
    event_count: u32,
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
                entry.kind = mergeEventKinds(entry.kind, kind);
                entry.last_event = now;
                entry.event_count += 1;
            } else {
                const path_owned = try self.allocator.dupe(u8, path);
                try self.pending.put(path_owned, .{
                    .kind = kind,
                    .last_event = now,
                    .event_count = 1,
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
                _ = self.watched_fds.remove(path);
                _ = self.fd_to_path.remove(fd);
                std.posix.close(fd);
            } else if (ev.fflags & c.NOTE_RENAME != 0) {
                try self.debouncer.recordEvent(path, .renamed);
            } else if (ev.fflags & (c.NOTE_WRITE | c.NOTE_EXTEND) != 0) {
                try self.debouncer.recordEvent(path, .modified);
                try self.watchNewSubdirs(path);
            }
        }

        try self.debouncer.collectReady(&self.events);
        return self.events.items;
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

test "watcher init" {
    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    var watcher = try Watcher.init(allocator, path);
    defer watcher.deinit();

    _ = try watcher.poll();
}
