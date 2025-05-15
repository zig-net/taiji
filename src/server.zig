const std = @import("std");
const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const builtin = @import("builtin");
const poll = @import("core/poll.zig");
const epoll = @import("core/epoll.zig");
const kqueue = @import("core/kqueue.zig");
const thread_pool = @import("thread_pool.zig");

allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{
        .allocator = allocator,
    };
}

pub const ServerOptions = struct {
    worker_num: usize = 0,
    pub fn default() @This() {
        return .{
            .worker_num = (std.Thread.getCpuCount() catch 5) - 1,
        };
    }
};

pub fn ListenAndServer(self: @This(), address: Address, options: ServerOptions) !void {
    var ser = try address.listen(.{});
    defer ser.deinit();
    // std.log.debug("socket fd: {}", .{ser.stream.handle});
    const th_pool = try thread_pool.initThreadPool(self.allocator, options.worker_num);
    const queue = th_pool.get_queue();
    const event_loop = switch (builtin.os.tag) {
        .linux => try epoll.init(queue),
        // TODO: 需要mac设备进行测试
        .macos => try kqueue.init(queue),
        else => try poll.init(self.allocator, queue),
    };
    defer event_loop.deinit();
    try event_loop.accept(&ser);
}
