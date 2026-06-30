//! Process entry point and blocking HTTP accept loop.
//!
//! Socket setup stays here so routing, storage, and rendering remain testable
//! without needing to construct network streams.
const std = @import("std");

pub const std_options = std.Options{
    .log_level = .debug,
};

const build_options = @import("build_options");
const config = @import("config.zig");
const db = @import("db.zig");
const logger = @import("logger.zig");
const post = @import("post.zig");
const router = @import("router.zig");
const user = @import("user.zig");

const Io = std.Io;
const net = std.Io.net;
const startup_logo = std.mem.trimEnd(u8, @embedFile("templates/startup_logo.txt"), " \t\r\n");

pub fn main(init: std.process.Init) !void {
    const cfg = config.Config.load(init.arena.allocator(), init.io, init.minimal.environ) catch |err| switch (err) {
        error.MissingRequiredEnv => {
            std.debug.print("error: SESSION_SECRET is required. Start with: SESSION_SECRET=<32+ byte secret> zig build run\n", .{});
            std.process.exit(1);
        },
        error.SessionSecretTooShort => {
            std.debug.print("error: SESSION_SECRET must be at least 32 bytes. Generate a longer random secret and try again.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    try db.migrate(init.arena.allocator(), cfg);
    try bootstrapAdmin(init.arena.allocator(), init.io, cfg);
    post.refreshRedisCache(init.arena.allocator(), init.io, cfg);
    try run(init.io, std.heap.smp_allocator, cfg);
}

fn bootstrapAdmin(allocator: std.mem.Allocator, io: Io, cfg: config.Config) !void {
    const users: user.Store = .{ .allocator = allocator, .cfg = cfg };
    const now = Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    const password = try users.bootstrapDefaultAdminIfEmpty(io, now) orelse return;

    std.debug.print(
        \\*** DEFAULT ADMIN CREATED ***
        \\username: admin
        \\password: {s}
        \\Change this generated password immediately at /account/password.
        \\
    , .{password});
}

fn run(io: Io, allocator: std.mem.Allocator, cfg: config.Config) !void {
    const address = try net.IpAddress.parse(cfg.blog_host, cfg.blog_port);
    var server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer server.deinit(io);

    const log = logger.Logger.init(cfg.log_level);
    std.debug.print("{s}\ncopyright © imggion\nv{s}\n", .{ startup_logo, build_options.version });
    log.info("server.listening", "host={s} port={d}", .{ cfg.blog_host, cfg.blog_port });
    log.debug("server.config", "sqlite_path={s} redis_host={s} redis_port={d} session_configured={}", .{
        cfg.sqlite_path,
        cfg.redis_host,
        cfg.redis_port,
        cfg.session_secret.len > 0,
    });
    while (true) {
        const stream = server.accept(io) catch |err| {
            log.err("server.accept_failed", "error={s}", .{@errorName(err)});
            continue;
        };
        handleConnection(io, allocator, cfg, stream) catch |err| {
            log.err("request.failed", "error={s}", .{@errorName(err)});
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
