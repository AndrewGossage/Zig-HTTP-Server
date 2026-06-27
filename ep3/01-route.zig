const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try listen(init.io, init.gpa);
}

fn listen(io: std.Io, gpa: std.mem.Allocator) !void {
    var sem: std.Io.Semaphore = .{ .permits = 16 };
    const addr: std.Io.net.IpAddress = try .resolve(io, "127.0.0.1", 8090);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });
    var group = std.Io.Group.init;
    defer group.cancel(io);
    while (true) {
        const stream = try tcp_server.accept(io);
        try sem.wait(io);
        try group.concurrent(io, handleConnection, .{ io, &sem, gpa, stream });
    }
}

pub const Context = struct {
    gpa: std.mem.Allocator,
    request: *std.http.Server.Request,
};
pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    callback: *const fn (*Context) anyerror!void,
};

fn index(ctx: *Context) !void {
    try ctx.request.respond("Hello, Zig!\n", .{ .keep_alive = false });
}

fn user(ctx: *Context) !void {
    try ctx.request.respond("{\"user\":\"test_user\"}\n", .{ .keep_alive = false });
}
const routes = [_]Route{
    .{
        .method = .GET,
        .path = "/",
        .callback = index,
    },
    .{
        .method = .GET,
        .path = "/user",
        .callback = user,
    },
};

fn handleConnection(io: std.Io, sem: *std.Io.Semaphore, gpa: std.mem.Allocator, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    defer sem.post(io);
    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = server.receiveHead() catch return;
    var ctx = Context{ .request = &request, .gpa = gpa };
    std.debug.print("target {s}\n", .{request.head.target});
    for (routes) |route| {
        if (route.method == request.head.method and std.ascii.eqlIgnoreCase(request.head.target, route.path)) {
            route.callback(&ctx) catch |err| std.log.err("{}", .{err});
        }
    }

    ctx.request.respond("Not Found", .{ .status = .not_found, .keep_alive = false }) catch |err| {
        std.log.err("{}", .{err});
    };
}
