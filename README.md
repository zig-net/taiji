# Taiji - A ZIG-based HTTP Server Framework

## Introduction

Taiji is a cross-platform HTTP server framework written in ZIG. It provides a simple and easy-to-use API, allowing developers to quickly build high-performance web applications.


## example:

```zig
const std = @import("std");
const taiji = @import("taiji");
const http = taiji.http;
const router_t = taiji.router.Router;
const request = taiji.request;
const response = taiji.response;
const method = taiji.method;

pub fn testHandler(req: request, res: *response) !void {
    std.log.info("client: {any}", .{req.getClientAddr()});
    res.write("test");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    const port = 8082;
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var router = try router_t.init(allocator);
    defer router.deinit();
    try router.addRoute(method.GET, "/", testHandler);
    var ser = try http.init(allocator, router);
    defer ser.deinit();
    try ser.ListenAndServer(address, http.ServerOptions.default());
}

```