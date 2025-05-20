const std = @import("std");
const Allocator = std.mem.Allocator;

const request_t = @import("./request.zig");
const response_t = @import("./response.zig");
const types = @import("./types.zig");

pub const Handler = *const fn (request: request_t, response: *response_t) anyerror!void;

// NEW PARAMS DEFINITION (Method 1)
pub const Params = struct {
    const Self = @This();

    internal_map: std.StringHashMap([]u8), // Value is owned slice (allocated with self.alloc)
    alloc: Allocator, // Allocator used for the owned slices

    pub fn init(allocator: Allocator) Self {
        return .{
            // The StringHashMap itself uses the provided allocator for its internal structures
            .internal_map = std.StringHashMap([]u8).init(allocator),
            // We store the allocator to be used for duplicating/owning the values
            .alloc = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Iterate and free all owned values stored in the map
        var value_iter = self.internal_map.valueIterator();
        while (value_iter.next()) |owned_slice_ptr| {
            self.alloc.free(owned_slice_ptr.*); // Free the []u8 slice data
        }
        // Deinitialize the StringHashMap structure itself
        self.internal_map.deinit();
    }

    pub fn put(self: *Self, key: []const u8, value_to_copy: []const u8) !void {
        // Duplicate the value_to_copy using self.alloc to take ownership
        const owned_value = try self.alloc.dupe(u8, value_to_copy);
        errdefer self.alloc.free(owned_value); // Clean up if internal_map.put fails

        // Put the owned_value into the map.
        // The key is also a slice; StringHashMap might copy it internally if not const.
        // Our keys are typically string literals or slices of input path, so they are fine.
        try self.internal_map.put(key, owned_value);
    }

    // Returns a const slice, as the caller should not modify the owned data.
    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        if (self.internal_map.get(key)) |owned_value_slice| {
            return owned_value_slice; // Implicitly casts []u8 to []const u8
        }
        return null;
    }

    // Optional: if direct pointer access is needed, e.g. for std.testing.expectEqualSlices
    // This returns a pointer to the owned slice within the map.
    pub fn getPtr(self: *const Self, key: []const u8) ?*const []u8 {
        // StringHashMap.getPtr returns *V, where V is []u8.
        // We need to cast it to *const []u8 if the public API promises const.
        // However, since []u8 can cast to []const u8, a direct get might be fine if the return is ?[]const u8.
        // Let's stick to `get` and if a pointer is truly needed, expose it carefully.
        // For now, `get` should suffice.
        if (self.internal_map.getPtr(key)) |ptr_to_owned_slice| {
            // This is a bit tricky with const correctness.
            // ptr_to_owned_slice is *[]u8.
            // We want to return *const []u8 or similar.
            // Easiest is to just use `get` for now.
            // If direct pointer to slice is needed:
            // return @constCast(ptr_to_owned_slice); // or carefully manage const
            _ = ptr_to_owned_slice; // to avoid unused error if not implemented
        }
        return null; // Placeholder for getPtr if you decide to implement it fully
    }

    pub fn count(self: *const Self) usize {
        return self.internal_map.count();
    }
};
// END NEW PARAMS DEFINITION

const RouterError = error{
    ConflictingParamRouteDefinition,
    WildcardMustBeLastSegment,
    RouteConflict,
    InvalidPath,
};

const Node = struct {
    // ... (Node definition remains the same) ...
    const Self = @This();

    handlers: std.EnumMap(types.Method, ?Handler),
    children: std.StringHashMap(*Self),
    param_child: ?*Self,
    wildcard_child: ?*Self,
    node_identifier_name: []const u8,

    pub fn init(allocator: Allocator, identifier_name: []const u8) Self {
        var h = std.EnumMap(types.Method, ?Handler).init(.{});
        inline for (std.meta.fields(types.Method)) |field| {
            const method_enum_val = @as(types.Method, @enumFromInt(field.value));
            h.put(method_enum_val, null);
        }
        return .{
            .handlers = h,
            .children = std.StringHashMap(*Self).init(allocator),
            .param_child = null,
            .wildcard_child = null,
            .node_identifier_name = identifier_name,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        var children_iter = self.children.iterator();
        while (children_iter.next()) |entry| {
            const child_node: *Node = entry.value_ptr.*;
            child_node.deinit(allocator);
            allocator.destroy(child_node);
        }
        self.children.deinit();
        if (self.param_child) |param_node| {
            param_node.deinit(allocator);
            allocator.destroy(param_node);
            self.param_child = null;
        }
        if (self.wildcard_child) |wild_node| {
            wild_node.deinit(allocator);
            allocator.destroy(wild_node);
            self.wildcard_child = null;
        }
    }
};

pub const Router = struct {
    const Self = @This();

    allocator: Allocator,
    root: *Node,

    pub fn init(allocator: Allocator) !Self {
        const root_node = try allocator.create(Node);
        root_node.* = Node.init(allocator, "");
        return .{
            .allocator = allocator,
            .root = root_node,
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }

    fn createNode(allocator: Allocator, identifier_name: []const u8) !*Node {
        const node = try allocator.create(Node);
        node.* = Node.init(allocator, identifier_name);
        return node;
    }

    pub fn addRoute(self: *Self, comptime http_method: types.Method, path: []const u8, handler: Handler) !void {
        var parts_list = try splitPath(self.allocator, path);
        defer parts_list.deinit();

        var current = self.root;
        const parts = parts_list.items;

        for (parts, 0..) |part, i| {
            if (part.len == 0) continue;
            if (part[0] == ':') {
                const param_name = part[1..];
                if (param_name.len == 0) return RouterError.InvalidPath;
                if (current.wildcard_child != null) return RouterError.RouteConflict;
                if (current.param_child) |existing_param_node| {
                    if (!std.mem.eql(u8, existing_param_node.node_identifier_name, param_name)) {
                        return RouterError.ConflictingParamRouteDefinition;
                    }
                    current = existing_param_node;
                } else {
                    if (current.children.contains(param_name)) return RouterError.RouteConflict;
                    const new_node = try createNode(self.allocator, param_name);
                    current.param_child = new_node;
                    current = new_node;
                }
            } else if (std.mem.eql(u8, part, "*")) {
                if (i != parts.len - 1) return RouterError.WildcardMustBeLastSegment;
                if (current.param_child != null or current.children.count() > 0) return RouterError.RouteConflict;
                if (current.wildcard_child) |existing_wildcard_node| {
                    current = existing_wildcard_node;
                } else {
                    const new_node = try createNode(self.allocator, "*");
                    current.wildcard_child = new_node;
                    current = new_node;
                }
                break;
            } else {
                if (current.param_child != null or current.wildcard_child != null) return RouterError.RouteConflict;
                const gop = try current.children.getOrPut(part); // key is []const u8 (part)
                if (!gop.found_existing) {
                    const new_node = try createNode(self.allocator, part);
                    gop.value_ptr.* = new_node;
                    current = new_node;
                } else {
                    current = gop.value_ptr.*;
                }
            }
        }
        if (current.handlers.get(http_method) != null) {}
        current.handlers.put(http_method, handler);
    }

    // Router.match now returns the new Params type
    pub fn match(self: *const Self, http_method: types.Method, path: []const u8) !?struct { handler: Handler, params: Params } {
        // Initialize with our new Params struct
        var params_map = Params.init(self.allocator);
        var success = false;
        // defer will call the new Params.deinit() which handles owned values
        defer if (!success) params_map.deinit();

        var parts_list = splitPath(self.allocator, path) catch {
            return null;
        };
        defer parts_list.deinit();

        if (try self.search(self.root, http_method, parts_list.items, &params_map)) |found_handler| {
            success = true;
            return .{ .handler = found_handler, .params = params_map };
        }

        return null;
    }

    fn search(
        self: *const Self,
        start_node: *Node,
        http_method: types.Method,
        parts: [][]const u8,
        params_map: *Params, // This is now our new Params struct
    ) !?Handler {
        var current = start_node;
        var path_idx: usize = 0;

        while (path_idx < parts.len) : (path_idx += 1) {
            const part = parts[path_idx];
            if (part.len == 0) continue;

            if (current.children.get(part)) |static_child_node| {
                current = static_child_node;
                continue;
            }

            if (current.param_child) |param_node| {
                // Params.put will now duplicate 'part'
                try params_map.put(param_node.node_identifier_name, part);
                current = param_node;
                continue;
            }

            if (current.wildcard_child) |wild_node| {
                var joined_wildcard_value = std.ArrayList(u8).init(self.allocator);
                defer joined_wildcard_value.deinit();

                for (parts[path_idx..], 0..) |remaining_part, k| {
                    try joined_wildcard_value.appendSlice(remaining_part);
                    if (k < parts[path_idx..].len - 1) {
                        try joined_wildcard_value.append('/');
                    }
                }
                // Params.put will now duplicate 'joined_wildcard_value.items'
                try params_map.put(wild_node.node_identifier_name, joined_wildcard_value.items);
                current = wild_node;
                path_idx = parts.len;
                break;
            }
            return null;
        }
        return current.handlers.get(http_method) orelse null;
    }

    fn splitPath(allocator: Allocator, path: []const u8) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).init(allocator);
        errdefer list.deinit();
        if (path.len == 0) return list;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len > 0) try list.append(segment);
        }
        return list;
    }
};

// --- Test ---
// Test functions (empty_handler, etc.) remain the same.
fn empty_handler(request: request_t, response: *response_t) anyerror!void {
    _ = request;
    _ = response;
    // std.debug.print("Handler called!\n", .{});
}
fn user_id_handler(request: request_t, response: *response_t) anyerror!void {
    _ = request;
    _ = response;
    // std.debug.print("User ID handler called!\n", .{});
}
fn user_post_handler(request: request_t, response: *response_t) anyerror!void {
    _ = request;
    _ = response;
    // std.debug.print("User Post handler called!\n", .{});
}
fn wildcard_handler(request: request_t, response: *response_t) anyerror!void {
    _ = request;
    _ = response;
    // std.debug.print("Wildcard handler called!\n", .{});
}
// Modify the test case to remove the manual free
test "Router basic operations" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute(types.Method.GET, "/user/:id", user_id_handler);
    try router.addRoute(types.Method.POST, "/user/:id/post", user_post_handler);
    try router.addRoute(types.Method.GET, "/static/*", wildcard_handler);
    try router.addRoute(types.Method.GET, "/", empty_handler);

    // Match: /user/123 (GET)
    const match1_opt = try router.match(types.Method.GET, "/user/123");
    try std.testing.expect(match1_opt != null);
    var m1 = match1_opt.?;
    try std.testing.expect(m1.handler == user_id_handler);
    const id_param = m1.params.get("id").?; // .get() returns ?[]const u8
    try std.testing.expect(std.mem.eql(u8, id_param, "123"));
    m1.params.deinit(); // New deinit will free "123"

    // Match: /user/abc/post (POST)
    const match2_opt = try router.match(types.Method.POST, "/user/abc/post");
    try std.testing.expect(match2_opt != null);
    var m2 = match2_opt.?;
    try std.testing.expect(m2.handler == user_post_handler);
    const id_param2 = m2.params.get("id").?;
    try std.testing.expect(std.mem.eql(u8, id_param2, "abc"));
    m2.params.deinit(); // New deinit will free "abc"

    // Match: /static/js/app.js (GET)
    const match3_opt = try router.match(types.Method.GET, "/static/js/app.js");
    try std.testing.expect(match3_opt != null);
    var m3 = match3_opt.?;
    try std.testing.expect(m3.handler == wildcard_handler);
    const wc_param = m3.params.get("*").?;
    try std.testing.expect(std.mem.eql(u8, wc_param, "js/app.js"));
    // NO MORE MANUAL FREE HERE
    m3.params.deinit(); // New deinit will free "js/app.js"

    // Match: / (GET)
    const match4_opt = try router.match(types.Method.GET, "/");
    try std.testing.expect(match4_opt != null);
    var m4 = match4_opt.?;
    try std.testing.expect(m4.handler == empty_handler);
    try std.testing.expectEqual(@as(usize, 0), m4.params.count());
    m4.params.deinit();

    const no_match = try router.match(types.Method.GET, "/nonexistent");
    try std.testing.expect(no_match == null);

    const wrong_method = try router.match(types.Method.POST, "/user/123");
    try std.testing.expect(wrong_method == null);
}

test "Router conflict: different param name at same level" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute(types.Method.GET, "/item/:itemId", empty_handler);
    const err = router.addRoute(types.Method.GET, "/item/:itemName", empty_handler);
    try std.testing.expectError(RouterError.ConflictingParamRouteDefinition, err);
}

test "Router conflict: wildcard not last" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const err = router.addRoute(types.Method.GET, "/assets/*/images", empty_handler);
    try std.testing.expectError(RouterError.WildcardMustBeLastSegment, err);
}

test "Router conflict: static vs param/wildcard" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute(types.Method.GET, "/foo/bar", empty_handler);
    // Adding /foo/:id should be fine if search prioritizes static
    // However, my current insert logic for param has:
    // if (current.children.contains(param_name)) return RouterError.RouteConflict;
    // This is very strict. A more common behavior is to allow static and param at the same level,
    // with static having higher priority in matching.
    // For this test to pass with current strictness:
    // const err = router.addRoute(types.Method.GET, "/foo/:id", empty_handler);
    // try std.testing.expectError(RouterError.RouteConflict, err); // If param name could be "bar"

    // More direct conflict:
    try router.addRoute(types.Method.GET, "/data/:version", empty_handler);
    const err2 = router.addRoute(types.Method.GET, "/data/latest", empty_handler); // adding static where param exists
    try std.testing.expectError(RouterError.RouteConflict, err2);

    var router2 = try Router.init(allocator);
    defer router2.deinit();
    try router2.addRoute(types.Method.GET, "/files/*", empty_handler);
    const err3 = router2.addRoute(types.Method.GET, "/files/specific.txt", empty_handler); // adding static where wildcard exists
    try std.testing.expectError(RouterError.RouteConflict, err3);
}
