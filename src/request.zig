const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList(u8);
const types = @import("types.zig");

allocator: Allocator,
header_map: std.StringHashMap([]const u8),
cookie_map: std.StringHashMap([]const u8),
query_map: std.StringHashMap([]const u8),
method: types.Method = types.Method.UNKNOWN,
url: []const u8 = "",
version: types.HTTP_Version = types.HTTP_Version.HTTP1_1,
body: []const u8 = "",
client_addr: std.net.Address = std.net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0),

pub fn init(allocator: Allocator) @This() {
    return .{
        .allocator = allocator,
        .header_map = std.StringHashMap([]const u8).init(allocator),
        .cookie_map = std.StringHashMap([]const u8).init(allocator),
        .query_map = std.StringHashMap([]const u8).init(allocator),
    };
}

pub fn parseHeader(self: *@This(), header_data: []u8) !void {
    var header_lines = std.mem.splitSequence(u8, header_data, "\r\n");
    const first = header_lines.first(); // 第一行单独处理
    // std.log.debug("line: {s}", .{first});
    var req_info = std.mem.splitSequence(u8, first, " ");
    const method = types.Method.parse(if (req_info.next()) |method| method else "");
    const url: []const u8 = if (req_info.next()) |url| url else "/";
    self.parseQuery(url) catch |err| {
        std.log.err("parse query error: {}", .{err});
    };
    const version = types.HTTP_Version.parse(if (req_info.next()) |version| version else "");

    self.method = method;
    // 去除query参数，方便进行路由匹配
    self.url = url[0 .. std.mem.indexOf(u8, url, "?") orelse url.len];
    self.version = version;
    // std.log.debug("method: {s} url: {s} version: {s}", .{ method.stringify(), url, version.stringify() });
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
        // std.log.debug("header line: {s} => key: {s} value: {s}", .{ line, key, val });
    }
    return;
}

fn parseQuery(self: *@This(), url: []const u8) !void {
    const query = std.mem.indexOf(u8, url, "?");
    if (query == null) {
        return;
    }
    const query_str = url[query.? + 1 .. url.len];
    var queries = std.mem.splitSequence(u8, query_str, "&");
    while (queries.next()) |query_kv| {
        var query_info = std.mem.splitSequence(u8, query_kv, "=");
        const name = query_info.next() orelse "";
        const value = query_info.next() orelse "";
        try self.query_map.put(name, value);
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

pub fn getBody(self: @This()) []const u8 {
    return self.body;
}

pub fn setBody(self: *@This(), body: []const u8) void {
    self.body = body;
}

pub fn getClientAddr(self: @This()) std.net.Address {
    return self.client_addr;
}

pub fn setClientAddr(self: *@This(), addr: std.net.Address) void {
    self.client_addr = addr;
}

pub fn getHeader(self: @This(), key: []const u8) ?[]const u8 {
    return self.header_map.get(key);
}

pub fn getCookie(self: @This(), key: []const u8) ?[]const u8 {
    return self.cookie_map.get(key);
}

pub fn getMethod(self: @This()) types.Method {
    return self.method;
}

pub fn getUrl(self: @This()) []const u8 {
    return self.url;
}

pub fn getVersion(self: @This()) types.HTTP_Version {
    return self.version;
}

pub fn deinit(self: @This()) void {
    _ = self;
    return;
}

test "request test" {
    const req = init(std.testing.allocator);
    defer req.deinit();
}
