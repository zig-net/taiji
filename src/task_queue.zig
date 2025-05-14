const std = @import("std");
const os = std.os;
const Atomic = std.atomic;
const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;
const posix = std.posix;

pub const EventType = enum {
    epoll,
    kqueue,
    poll,
};

pub const Event = union {
    epoll: *os.linux.epoll_event,
    kqueue: *std.c.Kevent,
    poll: std.c.pollfd,
};

allocator: Allocator,
// 任务定义
pub const Task = struct {
    fd: fd_t,
    event_fd: fd_t,
    event_type: EventType,
    event: Event,
    poll_data: ?[]u8 = null, // 因为poll在缓冲区数据没有被读取完毕时会持续触发
    poll_offset: usize = 0,

    pub fn read(self: *@This(), buf: []u8) !usize {
        if (self.poll_data) |data| {
            const data_len = data.len;
            const buf_len = buf.len;
            if (data_len - self.poll_offset > buf_len) {
                std.mem.copyForwards(u8, buf, data[self.poll_offset .. self.poll_offset + buf.len]);
                self.poll_offset = buf.len;
            } else {
                std.mem.copyForwards(u8, buf, data);
            }
            return data_len - self.poll_offset;
        }
        return posix.read(self.event_fd, buf);
    }

    pub fn free(self: @This(), allocator: Allocator) void {
        if (self.poll_data) |data| {
            allocator.free(data);
        }
    }
};

const Node = struct {
    next: ?*Node = null,
    task: Task,
};

var head = Atomic.Value(?*Node).init(null);
var tail = Atomic.Value(?*Node).init(null);

pub fn init(allocator: Allocator) @This() {
    return .{ .allocator = allocator };
}

// 生产者（主线程）
pub fn pushTask(self: @This(), task: Task) void {
    const node = self.allocator.create(Node) catch return;
    node.* = .{ .task = task };
    const current_tail = tail.load(.monotonic);
    while (true) {
        if (current_tail) |t| {
            t.next = node;
            tail.store(node, .monotonic);
            // std.log.debug("push task: {}", .{task.event_fd});
            break;
        } else {
            head.store(node, .monotonic);
            tail.store(node, .monotonic);
            // std.log.debug("push task 2: {}", .{task.event_fd});
            break;
        }
    }
}

// 消费者（工作线程）
pub fn popTask(self: @This()) ?Task {
    const current_head = head.load(.acquire);
    if (current_head) |h| {
        const next = h.next;
        head.store(next, .monotonic);
        // 如果队列为空，同时更新tail为null
        if (next == null) {
            tail.store(null, .monotonic);
        }
        const task = h.task;
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
        .event_type = .epoll,
        .event_fd = 1,
        .event = .{ .poll = .{} },
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
    const slice = buf[1..2];
    std.log.warn("test {any}", .{slice});
}
