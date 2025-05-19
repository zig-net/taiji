const std = @import("std");
const taiji = @import("taiji");
const http = taiji.http;
const router_t = taiji.router.Router;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    std.log.debug("hi zig", .{});
    const port = 8082;
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var router = try router_t.init(allocator);
    defer router.deinit();
    var ser = try http.init(allocator, router);
    defer ser.deinit();
    try ser.ListenAndServer(address, http.ServerOptions.default());
}
