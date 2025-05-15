const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList(u8);
const types = @import("types.zig");

allocator: Allocator,

pub fn init(allocator: Allocator) @This() {
    return .{
        .allocator = allocator,
    };
}

pub fn parseRequest(self: @This()) type {
    _ = self;
    return struct {};
}

pub fn deinit(self: @This()) void {
    _ = self;
    return;
}

test "request test" {
    const req = init(std.testing.allocator);
    defer req.deinit();
}
