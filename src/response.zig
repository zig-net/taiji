const std = @import("std");
const Allocator = std.mem.Allocator;
const status_t = @import("status.zig").Status;
const http_version_t = @import("types.zig").HTTP_Version;
const cookie_t = @import("cookie.zig").Cookie;

status_code: status_t,
http_version: http_version_t,
allocator: Allocator,
cookie_map: ?std.ArrayList(cookie_t),
headers: std.StringHashMap([]const u8),
body: []const u8 = "",

pub fn init(allocator: Allocator) @This() {
    return .{
        .status_code = status_t.OK,
        .http_version = .HTTP1_1,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = "",
        .allocator = allocator,
        .cookie_map = null,
    };
}

pub fn setHttpVersion(self: *@This(), version: http_version_t) void {
    self.http_version = version;
}

pub fn setStatus(self: *@This(), status: status_t) void {
    self.status_code = status;
}

pub fn getStatus(self: *@This()) status_t {
    return self.status_code;
}

pub fn setHeader(self: *@This(), key: []const u8, value: []const u8) !void {
    try self.headers.put(key, value);
}

pub fn write(self: *@This(), data: []const u8) void {
    self.body = data;
}

pub fn json(self: *@This(), data: []const u8) !void {
    try self.set_header("Content-Type", "application/json");
    self.write(data);
}

pub fn setCookie(self: *@This(), cookie: cookie_t) !void {
    if (self.cookie_map == null) self.cookie_map = std.ArrayList(cookie_t).init(self.allocator);
    try self.cookie_map.?.append(cookie);
}

pub fn parseResponse(self: *@This()) ![]const u8 {
    var resp = std.ArrayList(u8).init(self.allocator);
    defer resp.deinit();
    try resp.appendSlice(self.http_version.stringify());
    try resp.append(' ');
    try resp.appendSlice(self.status_code.stringify());
    try resp.appendSlice("\r\n");
    // header
    var headers = self.headers.iterator();
    while (headers.next()) |entry| {
        try resp.appendSlice(entry.key_ptr.*);
        try resp.appendSlice(": ");
        try resp.appendSlice(entry.value_ptr.*);
        try resp.appendSlice("\r\n");
    }
    if (self.cookie_map) |cookie| {
        for (cookie.items) |c| {
            try resp.appendSlice(try c.stringify(self.allocator));
            try resp.appendSlice("\r\n");
        }
    }
    try resp.appendSlice("\r\n");
    if (self.body.len > 0) {
        try resp.appendSlice(self.body);
    }
    return try resp.toOwnedSlice();
}

pub fn deinit(self: *@This()) void {
    self.headers.deinit();
    if (self.cookie_map) |cookie| {
        cookie.deinit();
    }
}

test "response test" {
    var res = init(std.testing.allocator);
    defer res.deinit();
    res.set_header("key: []const u8", "value: []const u8") catch |err| {
        std.log.err("set header failed: {}", .{err});
        return;
    };
    res.write("data: []const u8");
    try res.set_cookie(.{
        .name = "test",
        .value = "test val",
    });
}
