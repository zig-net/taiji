const std = @import("std");
const os = std.os;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic;
const task_queue = @import("task_queue.zig");
const poll = @import("core/poll.zig");
const status = @import("status.zig").Status;

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
    var header_buffer = std.ArrayList(u8).init(allocator);
    defer header_buffer.deinit();
    while (!shutdown.load(.seq_cst)) {
        // std.log.debug("load loop", .{});
        if (queue.popTask()) |task_data_const| {
            // handleTask(task_proc);
            var task_data = task_data_const;
            defer task_data.free(allocator);

            const ev = task_data.event;

            const ret = checkFd(ev, task_data.event_type);

            std.log.debug("get task {} checked: {}", .{ task_data.event_fd, ret });

            if (!ret) {
                closeFd(task_data.fd, task_data.event_fd, task_data.event_type) catch |err| {
                    std.log.err("An error occurred closing the file descriptor: {}", .{err});
                };
                // 考虑写回 status.INTERNAL_SERVER_ERROR
                continue;
            }
            // 构建resquest
            if (task_data.event_type == .poll) {
                const header_end_index = task_data.indexOf("\r\n\r\n");
                std.log.debug("header end: {?}", .{header_end_index});

                if (header_end_index == null) {
                    // 未检测到header分段
                    closeFd(task_data.fd, task_data.event_fd, task_data.event_type) catch |err| {
                        std.log.err("An error occurred closing the file descriptor: {}", .{err});
                    };
                    // 考虑写回 status.INTERNAL_SERVER_ERROR
                    continue;
                }

                const header_buf_len: usize = header_end_index.? + 4; // 4 为\r\n\r\n的长度，将此处读取完毕剩余的就是body部分
                const header_buf: ?[]u8 = allocator.alloc(u8, header_buf_len) catch null;
                if (header_buf == null) {
                    std.log.err("Header buffer allocation failure", .{});
                    continue;
                }
                defer allocator.free(header_buf.?);
                const header_read_size = task_data.read(header_buf.?) catch 0;
                if (header_read_size == 0) {
                    std.log.err("Header data reading failed", .{});
                    continue;
                }
                std.log.debug("header:\r\n {s}", .{header_buf.?});
            } else {
                var headers_finished = false;
                defer header_buffer.clearRetainingCapacity();
                var byte: [1]u8 = undefined;
                while (!headers_finished) {
                    const size = task_data.read(&byte) catch 0;
                    if (size == 0) {
                        break;
                    }
                    header_buffer.appendSlice(&byte) catch |err| {
                        std.log.err("Header_buffer memory allocation error: {}", .{err});
                        break;
                    };

                    if (std.mem.indexOf(u8, header_buffer.items, "\r\n\r\n")) |end_index| {
                        _ = end_index;
                        headers_finished = true;
                    }
                }
                if (!headers_finished) {
                    std.log.err("Header data reading failed", .{});
                    continue;
                }
                std.log.debug("header:\r\n {s}", .{header_buffer.items});
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
    self.queue.deinit();
    return;
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

const native_os = builtin.os.tag;

fn closeFd(fd: posix.fd_t, ev_fd: posix.fd_t, event_type: task_queue.EventType) !void {
    // TODO: 会遇到.BADF，这也因该是一种状态，但是zig标准库直接使用了unreachable，很糟糕，也就是说当传入的描述符已被系统关闭或者无效描述符，那么就会导致直接报错
    switch (event_type) {
        .epoll => {
            if (comptime os_tag == .linux) {
                // posix.close(ev_fd);
                // 会因为.BADF导致报错，所以这里不再进行手动关闭，等待系统回收吧
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
            // posix.close(ev_fd);
            // 会因为.BADF导致报错，所以这里不再进行手动关闭，等待系统回收吧
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

fn thread_test() !void {
    try std.testing.expect(false);
}

test "test thread" {
    const handle = try Thread.spawn(.{}, thread_test, .{});
    handle.join();
}
