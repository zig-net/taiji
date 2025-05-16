const std = @import("std");
const posix = std.posix;
const task_queue = @import("../task_queue.zig");

kqueue_fd: i32,
queue: task_queue,

pub fn init(queue: task_queue) !@This() {
    const kq = try posix.kqueue();
    return .{
        .kq = kq,
        .queue = queue,
    };
}

pub fn accept(self: @This(), server: *std.net.Server) !void {
    const server_fd = server.stream.handle;
    // 注册服务器套接字事件
    const kev = posix.Kevent{
        .ident = server_fd,
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    _ = try posix.kevent(self.kqueue_fd, &[_]posix.Kevent{kev}, null, 0);

    // 事件循环
    var events: [1024]posix.Kevent = undefined;
    while (true) {
        // std.log.debug("loop start", .{});
        const num_events = try posix.kevent(self.kqueue_fd, null, &events, -1);
        for (events[0..num_events]) |*ev| {
            if (ev.ident == server_fd) {
                // 处理新连接
                const client = try posix.accept(server_fd, null, null, 0);
                const client_fd = client.stream.handle;
                // defer client.deinit();
                // _ = try posix.fcntl(client_fd, posix.F.SETFD, posix.SOCK.NONBLOCK);
                // 将客户端套接字注册到kqueue
                const client_kev = posix.Kevent{
                    .ident = client_fd,
                    .filter = std.c.EVFILT.READ,
                    .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.EOF | std.c.EV.ERROR,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
                _ = try posix.kevent(self.kqueue_fd, &[_]posix.Kevent{client_kev}, null, 0);
            } else {
                // 处理客户端数据
                // const client_fd = ev.ident;
                // var buf: [1024]u8 = undefined;
                // const len = try posix.read(client_fd, &buf);
                // if (len == 0) {
                //     // 客户端断开连接
                //     posix.close(client_fd);
                //     // 从kqueue中移除该文件描述符
                //     const remove_kev = posix.Kevent{
                //         .ident = client_fd,
                //         .filter = std.c.EVFILT.READ,
                //         .flags = std.c.EV.DELETE,
                //         .fflags = 0,
                //         .data = 0,
                //         .udata = 0,
                //     };
                //     _ = try posix.kevent(self.kqueue_fd, &[_]posix.Kevent{remove_kev}, null, 0);
                // } else {
                //     // 处理接收到的数据
                //     var index: usize = 0;
                //     while (index < len) {
                //         index += try posix.write(ev.data.fd, buf[0..len]);
                //     }
                // }
                self.queue.pushTask(.{
                    .event_type = .kqueue,
                    .fd = self.kqueue_fd,
                    .event_fd = ev.data.fd,
                    .event = .{ .kqueue = ev },
                    .poll_data = null,
                });
            }
        }
    }
}

pub fn deinit(self: @This()) void {
    posix.close(self.kqueue_fd);
}
