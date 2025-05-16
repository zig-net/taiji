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
        // handleTask(task_proc);
        // defer task_data.free(allocator);

        // const ev = task_data.event;

        // const ret = checkFd(ev, task_data.event_type);

        // std.log.debug("get task {} checked: {}", .{ task_data.event_fd, ret });

        // if (!ret) {
        //     closeFd(task_data.fd, task_data.event_fd, task_data.event_type) catch |err| {
        //         std.log.err("An error occurred closing the file descriptor: {}", .{err});
        //     };
        //     // 考虑写回 status.INTERNAL_SERVER_ERROR
        //     continue;
        // }
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
        }

        // 读取body部分，因header部分已经读取完成，所以剩下的就是body了，全量读取即可
        // var body_len: usize = 0;
        // var body_buf: [1024]u8 = undefined;
        // body_len = task_data.read(&body_buf) catch 0;
        // var body_finished = false;
        // std.log.debug("body len {}", .{body_len});
        // while (!body_finished) {
        //     body_buffer.appendSlice(&body_buf) catch |err| {
        //         std.log.err("body_buffer memory allocation error: {}", .{err});
        //         break;
        //     };

        //     if (body_len < 1024 or std.mem.endsWith(u8, body_buffer.items, "0\r\n\r\n")) {
        //         body_finished = true;
        //     }

        //     body_len = task_data.read(&body_buf) catch {
        //         break;
        //     };
        // }
    } else {
        std.time.sleep(10_000_000); // 10ms 休眠
    }
}

pub fn deinit(self: @This()) void {
    self.queue.deinit();
    return;
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
