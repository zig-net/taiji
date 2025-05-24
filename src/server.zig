const std = @import("std");
const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const builtin = @import("builtin");
const thread_pool = @import("thread_pool.zig");
const events_t = @import("core/events.zig");
const accept_t = @import("core/accept.zig");
const router_t = @import("router.zig").Router;

allocator: Allocator,
events: events_t,
router: router_t,

pub fn init(allocator: Allocator, router: router_t) !@This() {
    // 这里只监听服务器的accept，所以一个事件即可(对于poll来说)
    const events = try events_t.init(allocator, .{
        .max_events = 1,
    });
    return .{
        .allocator = allocator,
        .events = events,
        .router = router,
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

pub fn deinit(self: *@This()) void {
    self.events.deinit();
}

pub fn ListenAndServer(self: *@This(), address: Address, options: ServerOptions) !void {
    var ser = try address.listen(.{});
    defer ser.deinit();
    // std.log.debug("socket fd: {}", .{ser.stream.handle});
    var th_pool = try thread_pool.initThreadPool(self.allocator, options.worker_num, &self.router);
    const queue = th_pool.get_queue();
    const loop = try accept_t.init(self.events, queue);
    try loop.accept(&ser);
}

test "server" {
    var router = try router_t.init(std.testing.allocator);
    var ser = try init(std.testing.allocator, router);
    defer ser.deinit();
    defer router.deinit();
}
