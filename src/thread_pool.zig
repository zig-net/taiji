const std = @import("std");
const os = std.os;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic;
const task_queue = @import("task_queue.zig");
const poll = @import("core/poll.zig");

var shutdown = Atomic.Value(bool).init(false); // 优雅退出标志

queue: task_queue,
allocator: Allocator,

pub fn initThreadPool(allocator: std.mem.Allocator, num_workers: usize) !@This() {
    const queue = task_queue.init(allocator);
    for (0..num_workers) |_| {
        _ = try Thread.spawn(.{}, workerThread, .{ allocator, queue });
    }
    return .{
        .queue = queue,
        .allocator = allocator,
    };
}

pub fn get_queue(self: @This()) task_queue {
    return self.queue;
}

// 工作线程函数
fn workerThread(allocator: Allocator, queue: task_queue) void {
    while (!shutdown.load(.seq_cst)) {
        // std.log.debug("load loop", .{});
        if (queue.popTask()) |task_data_const| {
            // handleTask(task_proc);
            var task_data = task_data_const;
            defer task_data.free(allocator);
            const ev = task_data.event;

            const ret = checkFd(ev, task_data.event_type);

            std.log.debug("get task {} checked: {}", .{ task_data.event_fd, ret });

            if (ret) {
                var buf: [1024]u8 = std.mem.zeroes([1024]u8);
                var len: usize = 0;
                if (task_data.read(&buf)) |l| {
                    std.log.debug("read len: {}", .{l});
                    len = l;
                    if (len == 0) {
                        closeFd(task_data.fd, task_data.event_fd, task_data.event_type) catch std.log.debug("close fd err", .{});
                    }
                } else |err| {
                    std.log.debug("read err: {}", .{err});
                }
                if (len == 0) {
                    continue;
                }
                if (posix.write(task_data.event_fd, buf[0..len])) |size| {
                    _ = size;
                } else |_| {}
            }
            // if (std.unicode.utf8ValidateSlice(task_data.data)) {
            //     std.debug.print("Valid UTF-8: {s}\n", .{task_data.data});
            // } else {
            //     std.debug.print("Binary data (hex): {x}\n", .{task_data.data});
            // }

        } else {
            std.time.sleep(10_000_000); // 10ms 休眠
        }
    }
}

pub fn deinit(self: @This()) void {
    return self.queue.deinit();
}

const builtin = @import("builtin");
const os_tag = builtin.os.tag;

fn checkFd(ev: task_queue.Event, event_type: task_queue.EventType) bool {
    switch (event_type) {
        .epoll => {
            if (comptime os_tag == .linux) {
                if (ev.epoll.events & (os.linux.EPOLL.HUP | os.linux.EPOLL.ERR | os.linux.EPOLL.RDHUP) != 0) {
                    return false;
                }
            }
        },
        .kqueue => {
            if (comptime std.c.Kevent != void) {
                if (ev.kqueue.flags & (std.c.EV.EOF | std.c.EV.ERROR) != 0) {
                    return false;
                }
            }
        },
        .poll => {
            const context = poll.context;
            if (ev.poll.fd & (context.POLLERR | context.POLLHUP | context.POLLNVAL) != 0) {
                return false;
            }
        },
    }
    return true;
}

fn closeFd(fd: posix.fd_t, ev_fd: posix.fd_t, event_type: task_queue.EventType) !void {
    switch (event_type) {
        .epoll => {
            if (comptime os_tag == .linux) {
                posix.close(ev_fd);
                _ = try posix.epoll_ctl(fd, os.linux.EPOLL.CTL_DEL, ev_fd, null);
            }
        },
        .kqueue => {
            if (comptime std.c.Kevent != void) {
                posix.close(ev_fd);
                const remove_kev = posix.Kevent{
                    .ident = ev_fd,
                    .filter = std.c.EVFILT.READ,
                    .flags = std.c.EV.DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
                _ = try posix.kevent(fd, &[_]posix.Kevent{remove_kev}, null, 0);
            }
        },
        .poll => {
            posix.close(ev_fd);
        },
    }
}

test "test workerThread" {
    const thread_pool = try initThreadPool(std.testing.allocator, 2);
    defer thread_pool.deinit();
    const queue = thread_pool.get_queue();
    // var stack_buf: [5]u8 = "Hello".*;
    // const data: []u8 = &stack_buf;
    queue.pushTask(.{
        .fd = 1,
        .event_type = .epoll,
        .event_fd = 1,
        .event = null,
    });
    std.time.sleep(100_000_000);
}
