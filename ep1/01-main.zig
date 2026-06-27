const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try listen(init.io);
}

fn listen(io: std.Io) !void {
    const addr: std.Io.net.IpAddress = try .resolve(io, "127.0.0.1", 8090);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;
    while (true) {
        const stream = try tcp_server.accept(io);
        defer stream.close(io);
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
        var request = server.receiveHead() catch |err| {
            std.debug.print("{any}", .{err});
            continue;
        };
        request.respond("hello zig", .{ .keep_alive = false }) catch |err| {
            std.debug.print("{any}", .{err});
            continue;
        };
    }
}
