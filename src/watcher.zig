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

    /// Non-blocking: returns events if any, empty slice otherwise
    pub fn poll(self: *Watcher) ![]WatchEvent {
        return switch (self.*) {
            .kqueue => |*w| w.poll(),
            .inotify => |*w| w.poll(),
            .windows => |*w| w.poll(),
            .polling => |*w| w.poll(),
        };
    }

    /// Get the file descriptor for epoll/select integration (if supported)
    pub fn getFd(self: *Watcher) ?std.posix.fd_t {
        switch (self.*) {
            .kqueue => |w| return w.kq,
            .inotify => |w| return w.fd,
            .windows, .polling => return null,
        }
    }
};

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
    pending_changes: std.ArrayList(DirChange),

    const DirChange = struct {
        path: []const u8,
        kind: WatchEvent.Kind,
    };

    pub fn init(allocator: Allocator, root: []const u8) !KqueueWatcher {
        const kq = try std.posix.kqueue();

        var self = KqueueWatcher{
            .allocator = allocator,
            .kq = kq,
            .watched_fds = std.StringHashMap(std.posix.fd_t).init(allocator),
            .fd_to_path = std.AutoHashMap(std.posix.fd_t, []const u8).init(allocator),
            .events = std.ArrayList(WatchEvent).init(allocator),
            .root = try allocator.dupe(u8, root),
            .pending_changes = std.ArrayList(DirChange).init(allocator),
        };

        // Watch root directory recursively
        try self.watchDirRecursive(root, 0);
        return self;
    }

    pub fn deinit(self: *KqueueWatcher) void {
        // Close all watched file descriptors
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
        self.pending_changes.deinit();
        std.posix.close(self.kq);
        self.allocator.free(self.root);
    }

    const MAX_WATCH_DEPTH = 10;

    fn watchDirRecursive(self: *KqueueWatcher, path: []const u8, depth: usize) !void {
        if (depth > MAX_WATCH_DEPTH) return;

        // Skip if already watching
        if (self.watched_fds.contains(path)) return;

        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);

        // Open directory with EVTONLY flag (doesn't prevent unmount)
        const fd = std.posix.open(path_owned, .{ .ACCMODE = .RDONLY }, 0) catch |e| {
            self.allocator.free(path_owned);
            return e;
        };
        errdefer std.posix.close(fd);

        // Register with kqueue
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

        // Recurse into subdirectories
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
        const timeout = std.posix.timespec{ .tv_sec = 0, .tv_nsec = 0 }; // Non-blocking

        const n = std.posix.kevent(self.kq, &.{}, &eventlist, &timeout) catch |e| {
            if (e == error.Interrupted) return self.events.items;
            return e;
        };

        for (eventlist[0..n]) |ev| {
            const fd: std.posix.fd_t = @intCast(ev.ident);
            const path = self.fd_to_path.get(fd) orelse continue;

            if (ev.fflags & c.NOTE_DELETE != 0) {
                try self.events.append(.{ .path = path, .kind = .deleted });
                // Remove from watch list
                _ = self.watched_fds.remove(path);
                _ = self.fd_to_path.remove(fd);
                std.posix.close(fd);
            } else if (ev.fflags & (c.NOTE_WRITE | c.NOTE_EXTEND) != 0) {
                // Directory contents changed - need to scan for specific changes
                try self.scanDirChanges(path);
            }
        }

        return self.events.items;
    }

    fn scanDirChanges(self: *KqueueWatcher, dir_path: []const u8) !void {
        // For kqueue, we just mark the directory as modified
        // The sniff layer will rescan this directory
        try self.events.append(.{
            .path = dir_path,
            .kind = .modified,
        });

        // Try to watch any new subdirectories
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
// Linux - inotify
// =============================================================================

pub const InotifyWatcher = if (builtin.os.tag == .linux) struct {
    allocator: Allocator,
    fd: std.posix.fd_t,
    wd_to_path: std.AutoHashMap(i32, []const u8),
    path_to_wd: std.StringHashMap(i32),
    events: std.ArrayList(WatchEvent),
    root: []const u8,
    buf: [8192]u8 align(@alignOf(std.os.linux.inotify_event)),

    pub fn init(allocator: Allocator, root: []const u8) !InotifyWatcher {
        const fd = try std.posix.inotify_init1(.{ .NONBLOCK = true });

        var self = InotifyWatcher{
            .allocator = allocator,
            .fd = fd,
            .wd_to_path = std.AutoHashMap(i32, []const u8).init(allocator),
            .path_to_wd = std.StringHashMap(i32).init(allocator),
            .events = std.ArrayList(WatchEvent).init(allocator),
            .root = try allocator.dupe(u8, root),
            .buf = undefined,
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
        std.posix.close(self.fd);
        self.allocator.free(self.root);
    }

    const MAX_WATCH_DEPTH = 10;

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
            IN.CREATE | IN.DELETE | IN.MODIFY | IN.MOVED_FROM | IN.MOVED_TO,
        ) catch |e| {
            self.allocator.free(path_owned);
            return e;
        };

        try self.wd_to_path.put(wd, path_owned);
        try self.path_to_wd.put(path_owned, wd);

        // Recurse into subdirs
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

        const len = std.posix.read(self.fd, &self.buf) catch |e| {
            if (e == error.WouldBlock) return self.events.items;
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

                    const IN = std.os.linux.IN;
                    const kind: WatchEvent.Kind = if (event.mask & IN.CREATE != 0)
                        .created
                    else if (event.mask & IN.DELETE != 0)
                        .deleted
                    else if (event.mask & IN.MODIFY != 0)
                        .modified
                    else
                        .renamed;

                    try self.events.append(.{ .path = full_path, .kind = kind });

                    // Watch new directories
                    if (event.mask & IN.CREATE != 0 and event.mask & IN.ISDIR != 0) {
                        self.watchDirRecursive(full_path, 0) catch {};
                    }
                }
            }

            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
        }

        return self.events.items;
    }
} else struct {
    // Stub for non-Linux platforms
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
    // Windows implementation would use ReadDirectoryChangesW
    // For now, fall back to polling on Windows

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
        // TODO: Implement proper Windows watching with ReadDirectoryChangesW
        // For now, return empty - user should use PollWatcher on Windows
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

        // Initial mtime snapshot
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

    const MAX_POLL_DEPTH = 10;

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
            // Directory changed
            try self.events.append(.{ .path = path, .kind = .modified });

            if (old_mtime) |_| {
                // Update mtime
                if (self.dir_mtimes.getEntry(path)) |entry| {
                    entry.value_ptr.* = stat.mtime;
                }
            } else {
                // New directory
                const path_owned = try self.allocator.dupe(u8, path);
                try self.dir_mtimes.put(path_owned, stat.mtime);
            }
        }

        // Recurse
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

test "watcher init" {
    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &buf);

    var watcher = try Watcher.init(allocator, path);
    defer watcher.deinit();

    // Just verify it initializes without error
    _ = try watcher.poll();
}
