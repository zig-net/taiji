// ref https://github.com/zigcc/zig-course/blob/main/course/code/12/echo_tcp_server.zig
const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const windows = std.os.windows;
const linux = std.os.linux;
const task_queue = @import("../task_queue.zig");
const Allocator = std.mem.Allocator;

// POLLIN, POLLERR, POLLHUP, POLLNVAL 均是 poll 的事件

/// windows context 定义
const windows_context = struct {
    pub const POLLIN: i16 = 0x0100;
    pub const POLLERR: i16 = 0x0001;
    pub const POLLHUP: i16 = 0x0002;
    pub const POLLNVAL: i16 = 0x0004;
    pub const INVALID_SOCKET = windows.ws2_32.INVALID_SOCKET;
};

/// linux context 定义
const linux_context = struct {
    pub const POLLIN: i16 = 0x0001;
    pub const POLLERR: i16 = 0x0008;
    pub const POLLHUP: i16 = 0x0010;
    pub const POLLNVAL: i16 = 0x0020;
    pub const INVALID_SOCKET = -1;
};

/// macOS context 定义
const macos_context = struct {
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;
    const INVALID_SOCKET = -1;
};

pub const context = switch (builtin.os.tag) {
    .windows => windows_context,
    .linux => linux_context,
    .macos => macos_context,
    else => @compileError("unsupported os"),
};

queue: task_queue,
allocator: Allocator,

pub fn init(allocator: Allocator, queue: task_queue) !@This() {
    return .{
        .queue = queue,
        .allocator = allocator,
    };
}

pub fn accept(self: @This(), server: *std.net.Server) !void {
    // _ = self;
    // #region data
    // 定义最大连接数
    const max_sockets = 1000;
    // 存储 accept 拿到的 connections
    var connections: [max_sockets]?net.Server.Connection = undefined;
    // sockfds 用于存储 pollfd, 用于传递给 poll 函数
    var sockfds: [max_sockets]posix.pollfd = undefined;
    // #endregion data
    for (0..max_sockets) |i| {
        sockfds[i].fd = context.INVALID_SOCKET;
        sockfds[i].events = context.POLLIN;
        connections[i] = null;
    }

    var buffer = std.ArrayList(u8).init(self.allocator);
    defer buffer.deinit();

    // _ = try posix.fcntl(server.stream.handle, posix.F.SETFD, posix.SOCK.NONBLOCK);

    sockfds[0].fd = server.stream.handle;
    // _ = server;
    // 无限循环，等待客户端连接或者已连接的客户端发送数据
    while (true) {
        // std.log.debug("loop start", .{});
        // 调用 poll，nums 是返回的事件数量
        var nums = try std.posix.poll(&sockfds, -1);
        if (nums == 0) {
            continue;
        }
        // 如果返回的事件数量小于0，说明出错了
        // 仅仅在 windows 下会出现这种情况
        if (nums < 0) {
            @panic("An error occurred in poll");
        }

        // NOTE: 值得注意的是，我们使用的模型是先处理已连接的客户端，再处理新连接的客户端

        // #region exist-connections
        // 遍历所有的连接，处理事件
        for (1..max_sockets) |i| {
            // 在windows下，WSApoll允许返回0，超时前没有套接字变成所要查询的状态
            if (nums == 0) {
                break;
            }

            const sockfd = sockfds[i];

            // if (sockfd.revents == 0) {
            //     std.Thread.sleep(10_000_000);
            //     break;
            // }

            // if (sockfd.revents & (context.POLLERR | context.POLLHUP | context.POLLNVAL) != 0) {
            //     sockfds[i].fd = context.INVALID_SOCKET;
            //     connections[i] = null;
            //     continue;
            // }

            // 检查是否是无效的 socket
            if (sockfd.fd == context.INVALID_SOCKET) {
                continue;
            }
            // 由于 windows 针对无效的socket也会触发POLLNVAL
            // 当前 sock 有 IO 事件时，处理完后将 nums 减一
            defer if (sockfd.revents != 0) {
                nums -= 1;
            };
            // 检查是否是 POLLIN 事件，即是否有数据可读
            // self.queue.pushTask(.{
            //     .event_type = .poll,
            //     .fd = 0,
            //     .event_fd = sockfd.fd,
            //     .event = .{ .poll = sockfd },
            // });
            if (sockfd.revents & (context.POLLIN) != 0) {
                var data_len: usize = 0;
                var buf: [1024]u8 = std.mem.zeroes([1024]u8);
                var len = try posix.read(sockfd.fd, &buf);
                if (len == 0) {
                    // 因为有可能是连接没有断开，但是出现了错误
                    // 将 pollfd 和 connection 置为无效
                    sockfds[i].fd = context.INVALID_SOCKET;
                    connections[i] = null;
                    continue;
                }
                while (len == buf.len) {
                    data_len += buf.len;
                    try buffer.appendSlice(&buf);
                    len = try posix.read(sockfd.fd, &buf);
                }
                try buffer.appendSlice(buf[0..len]);
                data_len += len;

                const data_copy = try self.allocator.alloc(u8, data_len);
                std.mem.copyForwards(u8, data_copy, buffer.items);
                // std.log.debug("raw {any} dest {any}", .{ buffer.items, data_copy });
                // 将len置零，并没有释放内存，因为这个buffer需要反复使用
                buffer.clearRetainingCapacity();
                // const c = connections[i];
                // if (c) |connection| {
                //     // buffer 用于存储 client 发过来的数据
                //     var buf: [1024]u8 = std.mem.zeroes([1024]u8);
                //     // const len = try connection.stream.read(&buf);
                //     const len = try posix.read(connection.stream.handle, &buf);
                //     // 如果连接已经断开，那么关闭连接
                //     // 这是因为如果已经 close 的连接，读取的时候会返回0
                //     if (len == 0) {
                //         // 但为了保险起见，我们还是调用 close
                //         // 因为有可能是连接没有断开，但是出现了错误
                //         connection.stream.close();
                //         // 将 pollfd 和 connection 置为无效
                //         sockfds[i].fd = context.INVALID_SOCKET;
                //         std.log.debug("client from {any} close!", .{
                //             connection.address,
                //         });
                //         connections[i] = null;
                //     } else {
                //         // 如果读取到了数据，那么将数据写回去
                //         // 但仅仅这样写一次并不安全
                //         // 最优解应该是使用for循环检测写入的数据大小是否等于buf长度
                //         // 如果不等于就继续写入
                //         // 这是因为 TCP 是一个面向流的协议
                //         // 它并不保证一次 write 调用能够发送所有的数据
                //         // 作为示例，我们不检查是否全部写入
                //         _ = try connection.stream.writeAll(buf[0..len]);
                //     }
                // }
                self.queue.pushTask(.{
                    .event_type = .poll,
                    .fd = 0,
                    .event_fd = sockfd.fd,
                    .event = .{ .poll = sockfd },
                    // 在使用完后释放内存
                    .poll_data = data_copy,
                });
            }
            // 检查是否是 POLLNVAL | POLLERR | POLLHUP 事件，即是否有错误发生，或者连接断开
            else if ((sockfd.revents &
                (context.POLLNVAL | context.POLLERR | context.POLLHUP)) != 0)
            {
                // 将 pollfd 和 connection 置为无效
                sockfds[i].fd = context.INVALID_SOCKET;
                connections[i] = null;
                // posix.close(sockfd.fd);
                std.log.debug("client {} close", .{i});
            }
        }
        // #endregion exist-connections

        // #region new-connection
        // 检查是否有新的连接
        // 这里的 sockfds[0] 是 server 的 pollfd
        // 这里的 nums 检查可有可无，因为我们只关心是否有新的连接，POLLIN 就足够了
        if (sockfds[0].revents & context.POLLIN != 0 and nums > 0) {
            std.log.debug("new client", .{});
            // 如果有新的连接，那么调用 accept
            const client = try server.accept();
            // _ = try posix.fcntl(client.stream.handle, posix.F.SETFD, posix.SOCK.NONBLOCK);
            for (1..max_sockets) |i| {
                // 找到一个空的 pollfd，将新的连接放进去
                if (sockfds[i].fd == context.INVALID_SOCKET) {
                    sockfds[i].fd = client.stream.handle;
                    connections[i] = client;
                    std.log.debug("new client {} comes", .{i});
                    break;
                }
                // 如果没有找到空的 pollfd，那么说明连接数已经达到了最大值
                if (i == max_sockets - 1) {
                    // @panic("too many clients");
                    client.stream.close();
                }
            }
        }
        // #endregion new-connection
    }

    if (builtin.os.tag == .windows) {
        try windows.ws2_32.WSACleanup();
    }
}

pub fn deinit(self: @This()) void {
    _ = self;
}
