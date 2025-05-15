const std = @import("std");
const os = std.os;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic;
const task_queue = @import("task_queue.zig");
const poll = @import("core/poll.zig");
const status = @import("status.zig").Status;
const types = @import("types.zig");

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
    var body_buffer = std.ArrayList(u8).init(allocator);
    defer body_buffer.deinit();
    var header_map = std.StringHashMap([]const u8).init(allocator);
    defer header_map.deinit();
    var cookie_map = std.StringHashMap([]const u8).init(allocator);
    defer cookie_map.deinit();
    while (!shutdown.load(.seq_cst)) {
        // std.log.debug("load loop", .{});
        if (queue.popTask()) |task_data_const| {
            // handleTask(task_proc);
            var task_data = task_data_const;
            defer task_data.free(allocator);

            const ev = task_data.event;

            const ret = checkFd(ev, task_data.event_type);

            // std.log.debug("get task {} checked: {}", .{ task_data.event_fd, ret });

            if (!ret) {
                closeFd(task_data.fd, task_data.event_fd, task_data.event_type) catch |err| {
                    std.log.err("An error occurred closing the file descriptor: {}", .{err});
                };
                // 考虑写回 status.INTERNAL_SERVER_ERROR
                continue;
            }
            // 和request放在同一作用域
            defer header_buffer.clearRetainingCapacity();
            // 构建resquest
            if (task_data.event_type == .poll) {
                const header_end_index = task_data.indexOf("\r\n\r\n");
                // std.log.debug("header end: {?}", .{header_end_index});

                if (header_end_index == null) {
                    // 未检测到header分段
                    closeFd(task_data.fd, task_data.event_fd, task_data.event_type) catch |err| {
                        std.log.err("An error occurred closing the file descriptor: {}", .{err});
                    };
                    // 考虑写回 status.INTERNAL_SERVER_ERROR
                    continue;
                }

                const header_buf_len: usize = header_end_index.? + 4; // 4 为\r\n\r\n的长度，将此处读取完毕剩余的就是body部分
                const header_buf = allocator.alloc(u8, header_buf_len) catch null;
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
                header_buffer.appendSlice(header_buf.?) catch |err| {
                    std.log.err("Header_buffer memory allocation error: {}", .{err});
                    break;
                };
                // std.log.debug("header:\r\n {s}", .{header_buf.?});
            } else {
                var headers_finished = false;
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
                // std.log.debug("header:\r\n {s} {}", .{ header_buffer.items, header_buffer });
            }
            // 读取body部分，因header部分已经读取完成，所以剩下的就是body了，全量读取即可
            var body_len: usize = 0;
            var body_buf: [1024]u8 = undefined;
            body_len = task_data.read(&body_buf) catch 0;
            var body_finished = false;
            while (!body_finished and body_len != 0) {
                body_buffer.appendSlice(&body_buf) catch |err| {
                    std.log.err("body_buffer memory allocation error: {}", .{err});
                    break;
                };

                if (body_len < 1024 or std.mem.endsWith(u8, body_buffer.items, "0\r\n\r\n")) {
                    body_finished = true;
                }

                body_len = task_data.read(&body_buf) catch {
                    break;
                };
            }
            // 开始构建request中的header部分
            // GET /url HTTP/1.1
            // Host: 127.0.0.1:8082
            // User-Agent: curl/7.88.1
            // Accept: */*
            // Accept-encoding: gzip, deflate, br, zstd
            // Cookie: _device_id=3e3309b080ef2d13593f0f5ddfd6e0da; user_session=WI00pCxrOnOeyLKbwevh6eL1AnvguUQCOtoYzqzEdagvLls3;
            // 对于一些服务端需要关注的header需要重点处理，例如Cookie
            // if (std.unicode.utf8ValidateSlice(task_data.data)) {
            //     std.debug.print("Valid UTF-8: {s}\n", .{task_data.data});
            // } else {
            //     std.debug.print("Binary data (hex): {x}\n", .{task_data.data});
            // }
            header_map.clearRetainingCapacity();
            var header_lines = std.mem.splitSequence(u8, header_buffer.items, "\r\n");
            const first = header_lines.first(); // 第一行单独处理
            std.log.debug("line: {s}", .{first});
            var req_info = std.mem.splitSequence(u8, first, " ");
            const method = types.Method.parse(if (req_info.next()) |method| method else "");
            const url: []const u8 = if (req_info.next()) |url| url else "/";
            const version = types.HTTP_Version.parse(if (req_info.next()) |version| version else "");
            std.log.debug("method: {s} url: {s} version: {s}", .{ method.stringify(), url, version.stringify() });
            while (header_lines.next()) |line| {
                const splitKV = std.mem.indexOf(u8, line, ":");
                if (splitKV == null) {
                    continue;
                }
                const key = line[0..splitKV.?];
                // +2 是去除:和其后的一个空格
                const val = line[splitKV.? + 2 .. line.len];
                header_map.put(key, val) catch |err| {
                    std.log.err("header_map memory allocation error: {}", .{err});
                };
                std.log.debug("header line: {s} => key: {s} value: {s}", .{ line, key, val });
            }
            std.log.debug("body: {s}", .{body_buffer.items});
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
