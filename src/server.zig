const std = @import("std");
const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const builtin = @import("builtin");
const thread_pool = @import("thread_pool.zig");
const events_t = @import("core/events.zig");
const accept_t = @import("core/accept.zig");

allocator: Allocator,
events: events_t,

pub fn init(allocator: Allocator) !@This() {
    // 这里只监听服务器的accept，所以一个事件即可(对于poll来说)
    const events = try events_t.init(allocator, .{
        .max_events = 1,
    });
    return .{
        .allocator = allocator,
        .events = events,
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
    defer self.events.deinit();
    var ser = try address.listen(.{});
    defer ser.deinit();
    // std.log.debug("socket fd: {}", .{ser.stream.handle});
    const th_pool = try thread_pool.initThreadPool(self.allocator, options.worker_num);
    const queue = th_pool.get_queue();
    const loop = try accept_t.init(self.events, queue);
    try loop.accept(&ser);
}
