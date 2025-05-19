const std = @import("std");
const os = std.os;
const posix = std.posix;
const task_queue = @import("../task_queue.zig");
const events_t = @import("./events.zig");
const router_t = @import("../router.zig").Router;

events: events_t,
queue: task_queue,

pub fn init(events: events_t, queue: task_queue) !@This() {
    return .{
        .events = events,
        .queue = queue,
    };
}

pub fn accept(
    self: @This(),
    server: *std.net.Server,
    router: *router_t,
) !void {
    _ = router;
    var event = self.events;
    const server_fd = server.stream.handle;
    try event.addFd(server_fd);
    while (true) {
        var nums = try event.wait(-1);
        if (nums == 0) {
            continue;
        }
        var client_fd: posix.fd_t = 0;
        switch (events_t.event_type) {
            .epoll => {
                const client = try server.accept();
                client_fd = client.stream.handle;
            },
            .kqueue => {
                // 处理新连接
                const client = try posix.accept(server_fd, null, null, 0);
                // defer client.deinit();
                // _ = try posix.fcntl(client_fd, posix.F.SETFD, posix.SOCK.NONBLOCK);
                // 将客户端套接字注册到kqueue
                client_fd = client.stream.handle;
            },
            .poll => {
                // 如果返回的事件数量小于0，说明出错了
                // 仅仅在 windows 下会出现这种情况
                if (nums < 0) {
                    @panic("An error occurred in poll");
                }
                // 遍历所有的连接，处理事件

                // 在windows下，WSApoll允许返回0，超时前没有套接字变成所要查询的状态
                // if (nums == 0) {
                //     return 0;
                // }

                const sockfd = self.events.getEventByIndex(0);

                // std.log.debug("event: {any}", .{sockfd});

                // 检查是否是无效的 socket
                if (sockfd.fd == events_t.context.INVALID_SOCKET) {
                    continue;
                }
                // 由于 windows 针对无效的socket也会触发POLLNVAL
                // 当前 sock 有 IO 事件时，处理完后将 nums 减一
                defer if (sockfd.revents != 0) {
                    nums -= 1;
                };
                if ((sockfd.revents &
                    (events_t.context.POLLNVAL | events_t.context.POLLERR | events_t.context.POLLHUP)) != 0)
                {
                    // 表示服务端sockt退出
                    @panic("server exit");
                    // 将 pollfd 和 connection 置为无效
                    // posix.close(sockfd.fd);
                    // std.log.debug("client {} close", .{i});
                }
                if (sockfd.revents & events_t.context.POLLIN != 0 and nums > 0) {
                    // std.log.debug("new client", .{});
                    // 如果有新的连接，那么调用 accept
                    const client = try server.accept();
                    client_fd = client.stream.handle;
                }
            },
        }

        self.queue.pushTask(.{
            .fd = client_fd,
        });

        std.log.debug("socket client fd: {}", .{client_fd});
    }
}

test "posix socket_addr to align(4)" {
    var addr_storage: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(@TypeOf(addr_storage));
    try posix.getpeername(1, &addr_storage, &addr_len);
    const sockaddr_ptr: *align(4) const posix.sockaddr = @alignCast(&addr_storage);
    const addr = std.net.Address.initPosix(sockaddr_ptr);
    std.log.debug("addr {}", .{addr.getPort()});
}
