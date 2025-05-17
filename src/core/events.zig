const std = @import("std");
const os = std.os;
const posix = std.posix;
const builtin = @import("builtin");
const net = std.net;
const windows = std.os.windows;
const linux = std.os.linux;
const task_queue = @import("../task_queue.zig");
const Allocator = std.mem.Allocator;
const SerError = @import("../error.zig").InnerError;

// POLLIN, POLLERR, POLLHUP, POLLNVAL 均是 poll 的事件

/// windows context 定义
const windows_context = struct {
    pub const POLLIN: i16 = 0x0100;
    pub const POLLERR: i16 = 0x0001;
    pub const POLLHUP: i16 = 0x0002;
    pub const POLLNVAL: i16 = 0x0004;
    pub const INVALID_SOCKET = windows.ws2_32.INVALID_SOCKET;
};

/// linux context 定义
const linux_context = struct {
    pub const POLLIN: i16 = 0x0001;
    pub const POLLERR: i16 = 0x0008;
    pub const POLLHUP: i16 = 0x0010;
    pub const POLLNVAL: i16 = 0x0020;
    pub const INVALID_SOCKET = -1;
};

/// macOS context 定义
const macos_context = struct {
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    const INVALID_SOCKET = -1;
};

pub const context = switch (builtin.os.tag) {
    .windows => windows_context,
    .linux => linux_context,
    .macos => macos_context,
    else => @compileError("unsupported os"),
};

pub const eventType = enum { poll, epoll, kqueue };

const os_tag = builtin.os.tag;
pub const event_type: eventType = if (os_tag == .linux) eventType.epoll else if (std.c.Kevent != void) eventType.kqueue else eventType.poll;
const events_type = if (event_type == .epoll) os.linux.epoll_event else if (event_type == .kqueue) posix.Kevent else posix.pollfd;

// comptime event_type: eventType = if (os_tag == .linux) eventType.epoll else if (std.c.Kevent != void) eventType.kqueue else eventType.poll,
events: []events_type,
fd: posix.fd_t = 0,
max_events: usize = 0,
allocator: Allocator,

const Options = struct {
    max_events: usize = 1024,
};

pub fn init(allocator: Allocator, opts: Options) !@This() {
    const fd = switch (event_type) {
        .epoll => try posix.epoll_create1(0),
        .kqueue => try posix.kqueue(),
        .poll => 0,
    };

    const event_list = try allocator.alloc(events_type, opts.max_events);
    // std.log.debug("event_list len: {}", .{event_list.len});
    if (event_type == .poll) {
        for (0..event_list.len) |i| {
            event_list[i].fd = context.INVALID_SOCKET;
            event_list[i].events = context.POLLIN;
        }
    }
    // std.log.debug("event_list: {any}", .{event_list});
    return .{
        .fd = fd,
        .max_events = opts.max_events,
        .events = event_list,
        .allocator = allocator,
    };
}

pub fn wait(self: *@This(), timeout_ms: i32) !usize {
    const event_num = switch (event_type) {
        .epoll => posix.epoll_wait(self.fd, self.events, timeout_ms),
        .kqueue => try posix.kevent(self.fd, null, &self.events, .{ .nsec = timeout_ms * 1000000 }),
        .poll => try posix.poll(self.events, timeout_ms),
    };
    return event_num;
}

pub fn getMaxEvent(self: @This()) usize {
    return self.max_events;
}

pub fn getEventByIndex(self: @This(), index: usize) events_type {
    return self.events[index];
}

pub fn getEventFd(self: @This(), ev: events_type) posix.fd_t {
    _ = self;
    return switch (event_type) {
        .epoll => ev.data.fd,
        .kqueue => ev.ident,
        .poll => ev.fd,
    };
}

pub fn setEventByIndex(self: @This(), index: usize, events: events_type) void {
    self.events[index] = events;
    return;
}

pub fn read(self: @This(), ev_fd: posix.fd_t, buf: []u8) !usize {
    _ = self;
    return posix.read(ev_fd, buf);
}

pub fn write(self: @This(), ev_fd: posix.fd_t, buf: []u8) !usize {
    _ = self;
    return posix.write(ev_fd, buf);
}

pub fn addFd(self: @This(), ev_fd: posix.fd_t) !void {
    switch (event_type) {
        .epoll => {
            var client_event = os.linux.epoll_event{
                .events = os.linux.EPOLL.IN | os.linux.EPOLL.ET | os.linux.EPOLL.HUP | os.linux.EPOLL.RDHUP | os.linux.EPOLL.ERR,
                .data = .{ .fd = ev_fd },
            };
            try posix.epoll_ctl(
                self.fd,
                os.linux.EPOLL.CTL_ADD,
                ev_fd,
                &client_event,
            );
        },
        .kqueue => {
            const add_key = posix.Kevent{
                .ident = ev_fd,
                .filter = std.c.EVFILT.READ,
                .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.EOF | std.c.EV.ERROR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = try posix.kevent(self.fd, &[_]posix.Kevent{add_key}, null, 0);
        },
        .poll => {
            var flag = false;
            for (0..self.events.len) |i| {
                if (self.events[i].fd == context.INVALID_SOCKET) {
                    self.events[i].fd = ev_fd;
                    flag = true;
                    break;
                }
            }
            if (!flag) {
                return SerError.TheEvenLoopIsFull;
            }
        },
    }
}

pub fn delFd(self: @This(), ev_fd: posix.fd_t) !void {
    switch (event_type) {
        .epoll => try posix.epoll_ctl(self.fd, os.linux.EPOLL.CTL_DEL, ev_fd, null),
        .kqueue => {
            const remove_kev = posix.Kevent{
                .ident = ev_fd,
                .filter = std.c.EVFILT.READ,
                .flags = std.c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = try posix.kevent(self.fd, &[_]posix.Kevent{remove_kev}, null, 0);
        },
        .poll => {
            for (0..self.events.len) |i| {
                if (self.events[i].fd == ev_fd) {
                    self.events[i].fd = context.INVALID_SOCKET;
                    break;
                }
            }
        },
    }
}

pub fn checkFd(self: @This(), ev: events_type) bool {
    _ = self;
    switch (event_type) {
        .epoll => {
            if (comptime os_tag == .linux) {
                if (ev.events & (os.linux.EPOLL.HUP | os.linux.EPOLL.ERR | os.linux.EPOLL.RDHUP) != 0) {
                    return false;
                }
            }
        },
        .kqueue => {
            if (comptime std.c.Kevent != void) {
                if (ev.flags & (std.c.EV.EOF | std.c.EV.ERROR) != 0) {
                    return false;
                }
            }
        },
        .poll => {
            if (ev.revents & (context.POLLERR | context.POLLHUP | context.POLLNVAL) != 0) {
                return false;
            }
        },
    }
    return true;
}

pub fn deinit(self: @This()) void {
    self.allocator.free(self.events);
    return;
}
