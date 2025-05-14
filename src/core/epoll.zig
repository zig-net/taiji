const std = @import("std");
const os = std.os;
const posix = std.posix;
const task_queue = @import("../task_queue.zig");

epoll_fd: i32,
queue: task_queue,

pub fn init(queue: task_queue) !@This() {
    const fd = try posix.epoll_create1(0);
    return .{
        .epoll_fd = fd,
        .queue = queue,
    };
}

pub fn accept(self: @This(), server: *std.net.Server) !void {
    // 添加服务器套接字到 epoll 监听
    var event = os.linux.epoll_event{
        .events = os.linux.EPOLL.IN | os.linux.EPOLL.ET,
        .data = .{ .fd = server.stream.handle },
    };
    try posix.epoll_ctl(self.epoll_fd, os.linux.EPOLL.CTL_ADD, server.stream.handle, &event);

    // 事件循环
    var events: [1024]os.linux.epoll_event = undefined;
    while (true) {
        // std.log.debug("loop start", .{});
        const num_events = posix.epoll_wait(self.epoll_fd, &events, -1);
        for (events[0..num_events]) |*ev| {
            if (ev.data.fd == server.stream.handle) {
                // 接受新连接
                const client = try server.accept();
                // 将客户端套接字加入 epoll
                var client_event = os.linux.epoll_event{
                    .events = os.linux.EPOLL.IN | os.linux.EPOLL.ET | os.linux.EPOLL.HUP | os.linux.EPOLL.RDHUP | os.linux.EPOLL.ERR,
                    .data = .{ .fd = client.stream.handle },
                };
                try posix.epoll_ctl(self.epoll_fd, os.linux.EPOLL.CTL_ADD, client.stream.handle, &client_event);
            } else {
                std.log.debug("event: {}", .{ev.events});
                // if (ev.events & (os.linux.EPOLL.HUP | os.linux.EPOLL.ERR | os.linux.EPOLL.RDHUP) != 0) {
                //     std.log.debug("event: os.linux.EPOLL.HUP|os.linux.EPOLL.ERR", .{});
                //     try posix.epoll_ctl(self.epoll_fd, os.linux.EPOLL.CTL_DEL, ev.data.fd, null);
                //     posix.close(ev.data.fd); // 连接关闭
                //     continue;
                // }
                // // 处理客户端数据
                // var buf: [1024]u8 = undefined;
                // const len = try posix.read(ev.data.fd, &buf);
                // if (len == 0) {
                //     try posix.epoll_ctl(self.epoll_fd, os.linux.EPOLL.CTL_DEL, ev.data.fd, null);
                //     posix.close(ev.data.fd); // 连接关闭
                // } else {
                //     // 处理请求（例如回显数据）
                //     var index: usize = 0;
                //     while (index < len) {
                //         index += try posix.write(ev.data.fd, buf[0..len]);
                //     }
                // }
                self.queue.pushTask(.{
                    .event_type = .epoll,
                    .fd = self.epoll_fd,
                    .event_fd = ev.data.fd,
                    .event = .{ .epoll = ev },
                    .poll_data = null,
                });
            }
        }
    }
}

pub fn deinit(self: @This()) void {
    posix.close(self.epoll_fd);
}

test "posix socket_addr to align(4)" {
    var addr_storage: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(@TypeOf(addr_storage));
    try posix.getpeername(1, &addr_storage, &addr_len);
    const sockaddr_ptr: *align(4) const posix.sockaddr = @alignCast(&addr_storage);
    const addr = std.net.Address.initPosix(sockaddr_ptr);
    std.log.debug("addr {}", .{addr.getPort()});
}
