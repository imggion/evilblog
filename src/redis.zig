// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! Minimal RESP client for the Redis commands used by evilblog.
//!
//! Connections are short-lived by design: this keeps failure handling simple for
//! the MVP and makes connection pooling an explicit future optimization.
const std = @import("std");

const Io = std.Io;
const net = std.Io.net;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    username: []const u8 = "",
    password: []const u8 = "",

    pub fn commandStatus(self: Client, args: []const []const u8) !void {
        var conn: Connection = undefined;
        try conn.init(self);
        defer conn.deinit(self.io);

        try writeCommand(&conn.writer_impl.interface, args);
        try conn.writer_impl.interface.flush();
        try readStatus(&conn.reader_impl.interface);
    }

    pub fn commandInteger(self: Client, args: []const []const u8) !i64 {
        var conn: Connection = undefined;
        try conn.init(self);
        defer conn.deinit(self.io);

        try writeCommand(&conn.writer_impl.interface, args);
        try conn.writer_impl.interface.flush();
        return try readInteger(&conn.reader_impl.interface);
    }

    pub fn commandBulk(self: Client, args: []const []const u8) !?[]u8 {
        var conn: Connection = undefined;
        try conn.init(self);
        defer conn.deinit(self.io);

        try writeCommand(&conn.writer_impl.interface, args);
        try conn.writer_impl.interface.flush();
        return try readBulk(self.allocator, &conn.reader_impl.interface);
    }

    pub fn commandArray(self: Client, args: []const []const u8) ![]?[]u8 {
        var conn: Connection = undefined;
        try conn.init(self);
        defer conn.deinit(self.io);

        try writeCommand(&conn.writer_impl.interface, args);
        try conn.writer_impl.interface.flush();
        return try readArray(self.allocator, &conn.reader_impl.interface);
    }
};

pub const Connection = struct {
    stream: net.Stream,
    reader_impl: net.Stream.Reader,
    writer_impl: net.Stream.Writer,
    read_buffer: [8192]u8,
    write_buffer: [8192]u8,

    pub fn init(self: *Connection, client: Client) !void {
        const address = try net.IpAddress.parse(client.host, client.port);
        self.stream = try net.IpAddress.connect(&address, client.io, .{ .mode = .stream, .protocol = .tcp });
        errdefer self.stream.close(client.io);
        self.reader_impl = self.stream.reader(client.io, &self.read_buffer);
        self.writer_impl = self.stream.writer(client.io, &self.write_buffer);

        if (client.password.len > 0) {
            if (client.username.len > 0) {
                try writeCommand(&self.writer_impl.interface, &.{ "AUTH", client.username, client.password });
            } else {
                try writeCommand(&self.writer_impl.interface, &.{ "AUTH", client.password });
            }
            try self.writer_impl.interface.flush();
            try readStatus(&self.reader_impl.interface);
        }
    }

    pub fn deinit(self: *Connection, io: Io) void {
        self.stream.close(io);
    }
};

pub fn freeArray(allocator: std.mem.Allocator, values: []?[]u8) void {
    for (values) |maybe_value| {
        if (maybe_value) |value| allocator.free(value);
    }
    allocator.free(values);
}

fn writeCommand(writer: *Io.Writer, args: []const []const u8) !void {
    try writer.print("*{d}\r\n", .{args.len});
    for (args) |arg| {
        try writer.print("${d}\r\n{s}\r\n", .{ arg.len, arg });
    }
}

fn readStatus(reader: *Io.Reader) !void {
    const marker = try reader.takeByte();
    switch (marker) {
        '+' => _ = try readLine(reader),
        '-' => return error.RedisError,
        else => return error.UnexpectedRedisResponse,
    }
}

fn readInteger(reader: *Io.Reader) !i64 {
    const marker = try reader.takeByte();
    switch (marker) {
        ':' => return try std.fmt.parseInt(i64, try readLine(reader), 10),
        '-' => return error.RedisError,
        else => return error.UnexpectedRedisResponse,
    }
}

fn readBulk(allocator: std.mem.Allocator, reader: *Io.Reader) !?[]u8 {
    const marker = try reader.takeByte();
    return switch (marker) {
        '$' => try readBulkAfterMarker(allocator, reader),
        '-' => error.RedisError,
        else => error.UnexpectedRedisResponse,
    };
}

fn readArray(allocator: std.mem.Allocator, reader: *Io.Reader) ![]?[]u8 {
    const marker = try reader.takeByte();
    switch (marker) {
        '*' => {},
        '-' => return error.RedisError,
        else => return error.UnexpectedRedisResponse,
    }

    const raw_len = try std.fmt.parseInt(i64, try readLine(reader), 10);
    if (raw_len < 0) return error.UnexpectedRedisResponse;

    const len: usize = @intCast(raw_len);
    const values = try allocator.alloc(?[]u8, len);
    // Keep errdefer safe while the array is only partially populated.
    @memset(values, null);
    errdefer freeArray(allocator, values);

    for (values) |*slot| {
        const item_marker = try reader.takeByte();
        slot.* = switch (item_marker) {
            '$' => try readBulkAfterMarker(allocator, reader),
            ':' => blk: {
                const line = try readLine(reader);
                break :blk try allocator.dupe(u8, line);
            },
            '-' => return error.RedisError,
            else => return error.UnexpectedRedisResponse,
        };
    }
    return values;
}

fn readBulkAfterMarker(allocator: std.mem.Allocator, reader: *Io.Reader) !?[]u8 {
    const raw_len = try std.fmt.parseInt(i64, try readLine(reader), 10);
    if (raw_len < 0) return null;
    const len: usize = @intCast(raw_len);
    const body = try reader.readAlloc(allocator, len);
    errdefer allocator.free(body);

    var crlf: [2]u8 = undefined;
    try reader.readSliceAll(&crlf);
    if (!std.mem.eql(u8, &crlf, "\r\n")) return error.UnexpectedRedisResponse;
    return body;
}

fn readLine(reader: *Io.Reader) ![]const u8 {
    const line = (try reader.takeDelimiter('\n')) orelse return error.UnexpectedRedisResponse;
    return std.mem.trimEnd(u8, line, "\r");
}

test "writeCommand formats RESP arrays" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeCommand(&out.writer, &.{ "AUTH", "user", "secret" });
    try std.testing.expectEqualStrings("*3\r\n$4\r\nAUTH\r\n$4\r\nuser\r\n$6\r\nsecret\r\n", out.written());
}
