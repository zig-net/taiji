const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList(u8);
const types = @import("types.zig");

allocator: Allocator,
header_map: std.StringHashMap([]const u8),
cookie_map: std.StringHashMap([]const u8),

pub fn init(allocator: Allocator) @This() {
    return .{
        .allocator = allocator,
        .header_map = std.StringHashMap([]const u8).init(allocator),
        .cookie_map = std.StringHashMap([]const u8).init(allocator),
    };
}

pub fn parseHeader(self: *@This(), header_data: []u8) !void {
    var header_lines = std.mem.splitSequence(u8, header_data, "\r\n");
    const first = header_lines.first(); // 第一行单独处理
    std.log.debug("line: {s}", .{first});
    var req_info = std.mem.splitSequence(u8, first, " ");
    const method = types.Method.parse(if (req_info.next()) |method| method else "");
    const url: []const u8 = if (req_info.next()) |url| url else "/";
    const version = types.HTTP_Version.parse(if (req_info.next()) |version| version else "");
    std.log.debug("method: {s} url: {s} version: {s}", .{ method.stringify(), url, version.stringify() });
    while (header_lines.next()) |line| {
        const splitKV = std.mem.indexOf(u8, line, ":");
        if (splitKV == null) {
            continue;
        }
        const key = line[0..splitKV.?];
        // +2 是去除:和其后的一个空格
        const val = line[splitKV.? + 2 .. line.len];

        // 在这里顺便提取出cookie
        if (std.mem.eql(u8, key, "Cookie") or std.mem.eql(u8, key, "cookie")) {
            try self.parseCookie(val);
        }

        try self.header_map.put(key, val);
        std.log.debug("header line: {s} => key: {s} value: {s}", .{ line, key, val });
    }
    return;
}

fn parseCookie(self: *@This(), cookie_val: []const u8) !void {
    var cookies = std.mem.splitSequence(u8, cookie_val, ";");
    while (cookies.next()) |cookie_kv| {
        var cookie_info = std.mem.splitSequence(u8, cookie_kv, "=");
        const name = cookie_info.next() orelse "";
        const value = cookie_info.next() orelse "";
        try self.cookie_map.put(name, value);
    }
    return;
}

pub fn deinit(self: @This()) void {
    _ = self;
    return;
}

test "request test" {
    const req = init(std.testing.allocator);
    defer req.deinit();
}
