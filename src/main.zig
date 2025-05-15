const std = @import("std");
const taiji = @import("taiji");
const http = taiji.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    std.log.debug("hi zig", .{});
    const port = 8081;
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    try http.init(allocator).ListenAndServer(address, http.ServerOptions.default());
}
