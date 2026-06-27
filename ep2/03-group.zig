const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try listen(init.io);
}

fn doSomeWork(io: std.Io) ![]const u8 {
    try io.sleep(std.Io.Duration.fromMilliseconds(1), .real);
    return "success";
}
fn listen(io: std.Io) !void {
    const addr: std.Io.net.IpAddress = try .resolve(io, "127.0.0.1", 8090);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });
    var group = std.Io.Group.init;
    defer group.cancel(io);
    while (true) {
        const stream = try tcp_server.accept(io);
        try group.concurrent(io, handle_connection, .{ io, stream });
    }
}

fn handle_connection(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = server.receiveHead() catch return;
    const result = doSomeWork(io) catch {
        request.respond("internal server error", .{ .keep_alive = false, .status = .internal_server_error }) catch {};
        return;
    };
    request.respond(result, .{
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("{any}", .{err});
        return;
    };
}
