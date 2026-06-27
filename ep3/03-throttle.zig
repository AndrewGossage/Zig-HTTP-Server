const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try listen(init.io, init.gpa);
}

pub const Throttler = struct {
    gpa: std.mem.Allocator,
    addresses: std.AutoHashMap([4]u8, Listing),
    lock: std.Io.Mutex = .init,
    io: std.Io,
    limit: u32,
    interval: u16 = 10,
    size_limit: usize = 1024,
    pub const Listing = struct {
        first: i64,
        count: u32 = 0,
    };
    pub fn shouldAllow(self: *Throttler, addr: std.Io.net.Ip4Address) !bool {
        try self.lock.lock(self.io);
        defer self.lock.unlock(self.io);
        if (self.addresses.count() > self.size_limit) return false;
        var val = self.addresses.get(addr.bytes) orelse Listing{
            .first = std.Io.Clock.now(.real, self.io).toSeconds(),
        };
        val.count += 1;
        if (val.count > self.limit) return false;
        std.debug.print("{any} {d}\n", .{ addr, val.count });
        try self.addresses.put(addr.bytes, val);
        return true;
    }

    pub fn evictExpired(self: *Throttler) !void {
        const interval = self.interval;
        while (true) {
            try self.io.sleep(std.Io.Duration.fromSeconds(interval), .real);
            try self.lock.lock(self.io);
            defer self.lock.unlock(self.io);

            var free_list: std.ArrayList([4]u8) = .empty;
            defer free_list.deinit(self.gpa);
            var it = self.addresses.iterator();
            var item = it.next();
            const seconds = std.Io.Clock.now(.real, self.io).toSeconds();

            while (item != null) {
                const val = item.?.value_ptr;
                if (val.first + @as(i64, self.interval) < seconds) {
                    free_list.append(self.gpa, item.?.key_ptr.*) catch {
                        _ = self.addresses.remove(item.?.key_ptr.*);
                        break;
                    };
                }
                item = it.next();
            }

            for (free_list.items) |i| {
                _ = self.addresses.remove(i);
            }
        }
    }
};

fn listen(io: std.Io, gpa: std.mem.Allocator) !void {
    var sem: std.Io.Semaphore = .{ .permits = 16 };
    const addr: std.Io.net.IpAddress = try .resolve(io, "127.0.0.1", 8090);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });
    var group = std.Io.Group.init;
    defer group.cancel(io);
    var throttler = Throttler{
        .gpa = gpa,
        .io = io,
        .limit = 10,
        .addresses = .init(gpa),
    };

    try group.concurrent(io, Throttler.evictExpired, .{&throttler});
    while (true) {
        const stream = try tcp_server.accept(io);
        if (try throttler.shouldAllow(stream.socket.address.ip4)) {
            try sem.wait(io);
            try group.concurrent(io, handleConnection, .{ io, &sem, gpa, stream });
        }
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

fn receiveHeadWithTimeout(io: std.Io, server: *std.http.Server) !std.http.Server.Request {
    const HeadOutcome = union(enum) {
        head: std.http.Server.ReceiveHeadError!std.http.Server.Request,
        timeout: std.Io.Cancelable!void,
    };

    var outcome_buffer: [2]HeadOutcome = undefined;
    var select = std.Io.Select(HeadOutcome).init(io, &outcome_buffer);
    defer select.cancelDiscard();

    try select.concurrent(.head, std.http.Server.receiveHead, .{server});
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(1), .real });

    switch (try select.await()) {
        .head => |result| {
            std.debug.print("real request\n", .{});
            return result;
        },
        .timeout => {
            std.debug.print("slow loris\n", .{});
            return error.TimeOut;
        },
    }
}

fn handleConnection(io: std.Io, sem: *std.Io.Semaphore, gpa: std.mem.Allocator, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    defer sem.post(io);
    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = receiveHeadWithTimeout(io, &server) catch return;
    var ctx = Context{ .request = &request, .gpa = gpa };
    std.debug.print("target {s}\n", .{request.head.target});
    for (routes) |route| {
        if (route.method == request.head.method and std.ascii.eqlIgnoreCase(request.head.target, route.path)) {
            route.callback(&ctx) catch |err| std.log.err("{}", .{err});
            return;
        }
    }

    ctx.request.respond("Not Found", .{ .status = .not_found, .keep_alive = false }) catch |err| {
        std.log.err("{}", .{err});
    };
}
