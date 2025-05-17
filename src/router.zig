const std = @import("std");
const Allocator = std.mem.Allocator;
const request_t = @import("./request.zig");
const response_t = @import("./response.zig");
const types = @import("types.zig");

// 路由函数签名定义
pub const Handler = *const fn (request: request_t, response: response_t) anyerror!void;
pub const Params = std.StringHashMap([]const u8);

// 编译期确定的节点结构
const Node = struct {
    const Self = @This();

    // 明确指定所有字段类型
    method: types.Method,
    handler: Handler,
    children: std.StringHashMap(*Self),
    param_child: ?*Self,
    param_name: []const u8, // 存储参数名称（如 ":id"）
    wildcard_child: ?*Self,

    pub fn init(allocator: Allocator, method: types.Method, handler: Handler, param_name: []const u8) Self {
        return .{
            .method = method,
            .handler = handler,
            .children = std.StringHashMap(*Self).init(allocator),
            .param_child = null,
            .param_name = param_name,
            .wildcard_child = null,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // 1. 清理普通子节点
        var children_iter = self.children.iterator();
        while (children_iter.next()) |entry| {
            const child: *Node = entry.value_ptr.*;
            child.deinit(allocator); // 递归清理
            allocator.destroy(child); // 释放内存
        }
        self.children.deinit();

        // 2. 清理参数子节点
        if (self.param_child) |param| {
            param.deinit(allocator);
            allocator.destroy(param);
            self.param_child = null;
        }

        // 3. 清理通配符子节点
        if (self.wildcard_child) |wild| {
            wild.deinit(allocator);
            allocator.destroy(wild);
            self.wildcard_child = null;
        }
    }
};

pub const Router = struct {
    const Self = @This();

    allocator: Allocator,
    root: Node,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .root = Node.init(allocator, undefined, // 根节点不存储方法
                undefined, ""),
        };
    }

    pub fn addRoute(self: *Self, comptime method: types.Method, path: []const u8, handler: Handler) !void {
        var parts = try splitPath(self.allocator, path);
        defer parts.deinit();
        try self.insert(method, parts.items, handler);
    }

    fn insert(self: *Self, method: types.Method, parts: [][]const u8, handler: Handler) !void {
        var current = &self.root;
        for (parts) |part| {
            if (part[0] == ':') {
                // 参数节点
                if (current.param_child == null) {
                    current.param_child = try self.createParamNode(method, part);
                }
                current = current.param_child.?;
            } else if (std.mem.eql(u8, part, "*")) {
                // 通配符节点
                if (current.wildcard_child == null) {
                    current.wildcard_child = try self.createWildcardNode(method, handler);
                }
                break;
            } else {
                // 普通节点
                const entry = try current.children.getOrPut(part);
                if (!entry.found_existing) {
                    entry.value_ptr.* = try self.createNormalNode(method, handler);
                }
                current = entry.value_ptr.*;
            }
        }
        current.handler = handler;
    }

    fn createNormalNode(self: *Self, method: types.Method, handler: Handler) !*Node {
        const node = try self.allocator.create(Node);
        node.* = Node.init(self.allocator, method, handler, "");
        return node;
    }

    fn createParamNode(self: *Self, method: types.Method, param_name: []const u8) !*Node {
        const node = try self.allocator.create(Node);
        node.* = Node.init(self.allocator, method, undefined, // 参数节点的处理函数由父节点决定
            param_name);
        return node;
    }

    fn createWildcardNode(self: *Self, method: types.Method, handler: Handler) !*Node {
        const node = try self.allocator.create(Node);
        node.* = Node.init(self.allocator, method, handler, "*");
        return node;
    }

    pub fn match(self: *Self, method: types.Method, path: []const u8) !?struct { handler: Handler, params: Params } {
        var params = Params.init(self.allocator);
        var parts = splitPath(self.allocator, path) catch return null;
        defer parts.deinit();
        if (try self.search(&self.root, method, parts.items, &params)) |handler| {
            return .{ .handler = handler, .params = params };
        }
        return null;
    }

    fn search(self: *Self, current: *Node, method: types.Method, parts: [][]const u8, params: *Params) !?Handler {
        var cur = current;
        for (parts, 0..) |part, i| {
            // 1. 检查精确匹配
            if (cur.children.get(part)) |child| {
                cur = child;
                continue;
            }

            // 2. 检查参数节点
            if (cur.param_child) |param_node| {
                try params.put(param_node.param_name[1..], part);
                if (param_node.method != method) return null;
                cur = param_node;
                continue;
            }

            // 3. 检查通配符
            if (cur.wildcard_child) |wild_node| {
                const remaining = parts[i..];
                var buf = std.ArrayList(u8).init(self.allocator);
                defer buf.deinit();
                for (remaining, 0..) |p, j| {
                    try buf.appendSlice(p);
                    if (j != remaining.len - 1) try buf.append('/');
                }
                try params.put("*", buf.items);
                return wild_node.handler;
            }

            return null;
        }
        return if (cur.method == method) cur.handler else null;
    }

    fn splitPath(allocator: Allocator, path: []const u8) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).init(allocator);
        var it = std.mem.splitSequence(u8, path, "/");
        while (it.next()) |segment| {
            if (segment.len > 0) try list.append(segment);
        }
        return list;
    }

    pub fn deinit(self: *Self) void {
        // 递归清理整个路由树
        self.root.deinit(self.allocator);
    }
};

test "router test" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.addRoute(types.Method.GET, "/user/:id", handler_test);

    var match_ret = try router.match(types.Method.GET, "/user/1");
    try std.testing.expect(match_ret != null);
    try std.testing.expect(match_ret.?.handler == handler_test);
    const id = match_ret.?.params.get("id").?;
    try std.testing.expect(std.mem.eql(u8, id, "1"));
    match_ret.?.params.deinit();
}

fn handler_test(request: request_t, response: response_t) anyerror!void {
    _ = request;
    _ = response;
}
