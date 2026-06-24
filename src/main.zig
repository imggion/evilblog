//! Process entry point and blocking HTTP accept loop.
//!
//! Socket setup stays here so routing, storage, and rendering remain testable
//! without needing to construct network streams.
const std = @import("std");

const config = @import("config.zig");
const router = @import("router.zig");

const Io = std.Io;
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const cfg = try config.Config.load(init.arena.allocator(), init.io, init.minimal.environ);
    try run(init.io, std.heap.smp_allocator, cfg);
}

fn run(io: Io, allocator: std.mem.Allocator, cfg: config.Config) !void {
    const address = try net.IpAddress.parse(cfg.blog_host, cfg.blog_port);
    var server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("easynews listening on {s}:{d}", .{ cfg.blog_host, cfg.blog_port });
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {}", .{err});
            continue;
        };
        handleConnection(io, allocator, cfg, stream) catch |err| {
            std.log.err("request failed: {}", .{err});
        };
    }
}

fn handleConnection(io: Io, allocator: std.mem.Allocator, cfg: config.Config, stream: net.Stream) !void {
    defer stream.close(io);

    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [16384]u8 = undefined;
    var reader_impl = stream.reader(io, &read_buffer);
    var writer_impl = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader_impl.interface, &writer_impl.interface);

    var request = http_server.receiveHead() catch return;
    try router.handle(allocator, io, cfg, &request);
}
