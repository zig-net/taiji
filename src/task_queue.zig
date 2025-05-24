const std = @import("std");
const os = std.os;
const Atomic = std.atomic;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;
const posix = std.posix;
const router_t = @import("router.zig").Router;

allocator: Allocator,
lock: std.Thread.Mutex = .{},
head: ?*Node = null,
tail: ?*Node = null,
// 任务定义
pub const Task = struct {
    fd: fd_t,
};

const Node = struct {
    next: ?*Node = null,
    task: Task,
};

// TODO: 这里优化方向参考go的全局协程队列设计
pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

// 生产者（主线程）
pub fn pushTask(self: *@This(), task: Task) void {
    self.lock.lock();
    defer self.lock.unlock();
    const node = self.allocator.create(Node) catch return;
    // std.log.debug("push task: {*}", .{node});
    node.* = .{ .task = task };
    const current_tail = self.tail;
    while (true) {
        if (current_tail) |t| {
            t.next = node;
            self.tail = node;
            break;
        } else {
            self.head = node;
            self.tail = node;
            break;
        }
    }
}

// 消费者（工作线程）
pub fn popTask(self: *@This()) ?Task {
    if (!self.lock.tryLock()) return null;
    defer self.lock.unlock();
    const current_head = self.head;
    if (current_head) |h| {
        self.head = h.next;
        // 如果队列为空，同时更新tail为null
        if (self.head == null) {
            self.tail = null;
        }
        const task = h.task;
        // std.log.debug("pop task: {*}", .{h});
        // std.log.debug("test: {any}", .{h});
        self.allocator.destroy(h);
        return task;
    }
    return null;
}

pub fn deinit(self: @This()) void {
    while (self.popTask() != null) {}
}

test "task queue" {
    const queue = init(std.testing.allocator);
    defer queue.deinit();
    // var stack_buf: [5]u8 = "Hello".*;
    // const data: []u8 = &stack_buf;
    queue.pushTask(.{
        .fd = 1,
    });
    const task_data = queue.popTask();
    if (task_data) |task_data_info| {
        try std.testing.expect(task_data_info.fd == 1);
    } else {
        try std.testing.expect(false);
    }
}

test "buffer" {
    const buf = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const slice = buf[5..7];
    std.log.warn("test {any}", .{slice});

    const data_copy = try std.testing.allocator.alloc(u8, buf.len);
    std.mem.copyForwards(u8, data_copy, buf[0..buf.len]);

    var task: Task = .{
        .fd = 1,
        .event_type = .epoll,
        .event_fd = 1,
        .event = .{
            .unknown = null,
        },
        .poll_data = data_copy,
    };

    defer task.free(std.testing.allocator);

    const index = task.indexOf(slice);
    std.log.warn("index {?}", .{index});
}
