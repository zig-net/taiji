const std = @import("std");
const os = std.os;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic;
const task_queue = @import("task_queue.zig");
const status = @import("status.zig").Status;
const types = @import("types.zig");
const builtin = @import("builtin");
// const os_tag = builtin.os.tag;
const events_t = @import("./core/events.zig");
const request_t = @import("./request.zig");

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

    var events = events_t.init(allocator, .{}) catch |err| {
        std.log.err("Worker thread startup failed: {}", .{err});
        return;
    };

    defer events.deinit();

    while (!shutdown.load(.seq_cst)) {
        // TODO:要注意的是这里没有对每个线程做专门的负载均衡优化,是一个优化点
        if (queue.popTask()) |task_data| {
            events.addFd(task_data.fd) catch |err| {
                std.log.err("Failed to add file descriptor: {}", .{err});
                queue.pushTask(.{
                    .fd = task_data.fd,
                });
                Thread.sleep(10_000_000);
                // 延迟一下,让给其它工作线程
                continue;
            };
        }
        // 和request放在同一作用域
        defer header_buffer.clearRetainingCapacity();
        const event_nums = events.wait(100) catch 0;

        for (0..if (events_t.event_type == .poll) events.getMaxEvent() else event_nums) |i| {
            const event = events.getEventByIndex(i);
            const ev_fd = events.getEventFd(event);
            if (comptime events_t.event_type == .poll) {
                if (event_nums == 0) {
                    continue;
                }
                // 如果返回的事件数量小于0，说明出错了
                // 仅仅在 windows 下会出现这种情况
                if (event_nums < 0) {
                    @panic("An error occurred in poll");
                }

                if (ev_fd == events_t.context.INVALID_SOCKET) {
                    continue;
                }
            }
            const checked = events.checkFd(event);

            if (!checked) {
                events.delFd(ev_fd) catch |err| {
                    std.log.err("An error occurred closing the file descriptor: {}", .{err});
                };
                continue;
            }
            // 构建resquest
            var headers_finished = false;
            var byte: [1]u8 = undefined;
            while (!headers_finished) {
                const size = events.read(ev_fd, &byte) catch 0;
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
                events.delFd(ev_fd) catch |err| {
                    std.log.err("An error occurred closing the file descriptor: {}", .{err});
                };
                continue;
            }

            var request = request_t.init(allocator);
            defer request.deinit();

            request.parseHeader(header_buffer.items) catch |err| {
                std.log.err("Failed to parse header: {}", .{err});
                events.delFd(ev_fd) catch |errs| {
                    std.log.err("An error occurred closing the file descriptor: {}", .{errs});
                };
                continue;
            };

            // 读取body部分，因header部分已经读取完成，所以剩下的就是body了，全量读取即可
            //检查是否有 body
            defer body_buffer.clearRetainingCapacity();
            if (request.getHeader("Content-Length")) |content_length| {
                const body_len = std.fmt.parseUnsigned(usize, content_length, 0) catch 0;
                if (body_len > 0) {
                    // std.log.debug("body len {}", .{body_len});
                    var body: []u8 = allocator.alloc(u8, body_len + 4) catch |err| {
                        std.log.err("Failed to allocate memory: {}", .{err});
                        events.delFd(ev_fd) catch |errs| {
                            std.log.err("An error occurred closing the file descriptor: {}", .{errs});
                        };
                        continue;
                    }; // +4:\r\n\r\n
                    defer allocator.free(body);

                    var bytes_read: usize = 0;
                    while (bytes_read < body_len) {
                        const n = events.read(ev_fd, body[bytes_read..]) catch |err| {
                            std.log.err("Failed to read body: {}", .{err});
                            events.delFd(ev_fd) catch |errs| {
                                std.log.err("An error occurred closing the file descriptor: {}", .{errs});
                            };
                            break;
                        };
                        bytes_read += n;
                    }
                    if (bytes_read != body_len) {
                        std.log.err("Failed to read all body", .{});
                        continue;
                    }
                    // std.log.debug("body: {s}", .{body[0..bytes_read]});
                    body_buffer.appendSlice(body[0..bytes_read]) catch |err| {
                        std.log.err("Failed to allocate memory: {}", .{err});
                        events.delFd(ev_fd) catch |errs| {
                            std.log.err("An error occurred closing the file descriptor: {}", .{errs});
                        };
                        continue;
                    };
                }
            } else if (request.getHeader("Transfer-Encoding")) |transfer_encoding| {
                if (std.mem.eql(u8, transfer_encoding, "chunked")) {
                    // std.log.debug("chunked", .{});
                    var tmp_buf: [1024]u8 = undefined;
                    while (true) {
                        const line = readLineBlocking(allocator, ev_fd, 512) catch "";
                        defer allocator.free(line);
                        var chunk_size_str_iter = std.mem.splitSequence(u8, line, ";");
                        const chunk_size_str = chunk_size_str_iter.next() orelse "";
                        const chunk_size = std.fmt.parseInt(usize, chunk_size_str, 16) catch 0;
                        if (chunk_size == 0) break;

                        // 读取块数据
                        var bytes_read: usize = 0;
                        while (bytes_read < chunk_size) {
                            const remaining = chunk_size - bytes_read;
                            const read_len = @min(remaining, tmp_buf.len);
                            const n = events.read(ev_fd, tmp_buf[0..read_len]) catch 0;
                            if (n == 0) break;
                            body_buffer.appendSlice(tmp_buf[0..n]) catch |err| {
                                // 处理错误
                                std.log.err("Failed to allocate memory: {}", .{err});
                                break;
                            };
                            bytes_read += n;
                        }

                        // 验证块结束符
                        var crlf_buf: [2]u8 = undefined;
                        _ = posix.read(ev_fd, &crlf_buf) catch 0;
                        if (crlf_buf[0] != '\r' or crlf_buf[1] != '\n') {
                            // 协议错误处理
                            std.log.err("Invalid chunked encoding", .{});
                        }
                    }
                }
            }

            // std.log.debug("body: {s}", .{body_buffer.items});
            request.setBody(body_buffer.items);

            // 获取客户端IP地址
            var addr_storage: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(@TypeOf(addr_storage));
            posix.getpeername(ev_fd, &addr_storage, &addr_len) catch |err| {
                std.log.err("Failed to get client address: {}", .{err});
            };
            const sockaddr_ptr: *align(4) const posix.sockaddr = @alignCast(&addr_storage);
            const addr = std.net.Address.initPosix(sockaddr_ptr);
            request.setClientAddr(addr);
        }
    } else {
        std.time.sleep(10_000_000); // 10ms 休眠
    }
}

pub fn deinit(self: @This()) void {
    self.queue.deinit();
    return;
}

pub fn readLineBlocking(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    max_line_len: usize,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var byte: [1]u8 = undefined;
    while (buf.items.len < max_line_len) {
        const n = try posix.read(fd, &byte);
        if (n == 0) break; // EOF
        switch (byte[0]) {
            '\n' => {
                // 检查是否是 \r\n
                if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\r') {
                    _ = buf.pop(); // 移除 \r
                }
                break; // 行结束
            },
            else => try buf.append(byte[0]),
        }
    }
    return buf.toOwnedSlice();
}

test "test workerThread" {
    const thread_pool = try initThreadPool(std.testing.allocator, 2);
    defer thread_pool.deinit();
    const queue = thread_pool.get_queue();
    defer queue.deinit();
    // var stack_buf: [5]u8 = "Hello".*;
    // const data: []u8 = &stack_buf;
    queue.pushTask(.{
        .fd = 1,
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
