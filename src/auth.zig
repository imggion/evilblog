// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! Cookie-session helpers and viewer roles.
//!
//! Sessions are signed with SESSION_SECRET and revalidated against SQLite users.
const std = @import("std");
const Config = @import("config.zig").Config;
const db = @import("db.zig");
const user = @import("user.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const session_cookie_name = "evilblog_session";

pub const Role = enum { admin, member };

pub const Viewer = struct {
    username: []u8,
    role: Role,
    must_change_password: bool,

    pub fn deinit(self: *Viewer, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

pub fn sessionViewer(allocator: std.mem.Allocator, cfg: Config, users: user.Store, head_buffer: []const u8) !?Viewer {
    const token = cookieValue(head_buffer, session_cookie_name) orelse return null;
    const username = tokenUsername(allocator, cfg, token) catch return null;
    errdefer allocator.free(username);

    var info = (try users.sessionInfo(username)) orelse {
        allocator.free(username);
        return null;
    };
    defer info.deinit(allocator);

    const role = roleFromName(info.role) orelse {
        allocator.free(username);
        return null;
    };

    return .{
        .username = username,
        .role = role,
        .must_change_password = info.must_change_password,
    };
}

fn tokenUsername(allocator: std.mem.Allocator, cfg: Config, token: []const u8) ![]u8 {
    const encoded_username = encodedUsernameFromToken(token) orelse return error.InvalidToken;
    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded_username);
    const username = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(username);
    try std.base64.url_safe_no_pad.Decoder.decode(username, encoded_username);

    const expected = try tokenFor(allocator, cfg, username);
    defer allocator.free(expected);
    if (!constantTimeEqual(token, expected)) return error.InvalidToken;
    return username;
}

pub fn isAdmin(viewer: Viewer) bool {
    return viewer.role == .admin;
}

pub fn roleFromName(name: []const u8) ?Role {
    return std.meta.stringToEnum(Role, name);
}

pub fn authenticate(allocator: std.mem.Allocator, users: user.Store, username: []const u8, password: []const u8, now_seconds: i64, io: std.Io) !?Viewer {
    var login = (try users.authenticate(username, password, now_seconds, io)) orelse return null;
    defer login.deinit(allocator);

    const role = roleFromName(login.role) orelse return null;
    return .{
        .username = try allocator.dupe(u8, login.username),
        .role = role,
        .must_change_password = login.must_change_password,
    };
}

pub fn loginCookie(allocator: std.mem.Allocator, cfg: Config, username: []const u8) ![]u8 {
    const token = try tokenFor(allocator, cfg, username);
    defer allocator.free(token);
    return try std.fmt.allocPrint(
        allocator,
        "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000",
        .{ session_cookie_name, token },
    );
}

pub fn clearCookie(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
        .{session_cookie_name},
    );
}

fn tokenFor(allocator: std.mem.Allocator, cfg: Config, username: []const u8) ![]u8 {
    const message = try std.fmt.allocPrint(allocator, "evilblog-session:v2:{s}", .{username});
    defer allocator.free(message);

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, message, cfg.session_secret);

    const encoded_user_len = std.base64.url_safe_no_pad.Encoder.calcSize(username.len);
    const encoded_mac_len = std.base64.url_safe_no_pad.Encoder.calcSize(mac.len);
    const token = try allocator.alloc(u8, "v2.".len + encoded_user_len + 1 + encoded_mac_len);
    var offset: usize = 0;
    @memcpy(token[offset..][0.."v2.".len], "v2.");
    offset += "v2.".len;
    offset += std.base64.url_safe_no_pad.Encoder.encode(token[offset..][0..encoded_user_len], username).len;
    token[offset] = '.';
    offset += 1;
    offset += std.base64.url_safe_no_pad.Encoder.encode(token[offset..][0..encoded_mac_len], &mac).len;
    return token[0..offset];
}

fn encodedUsernameFromToken(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, "v2.")) return null;
    const username_start = "v2.".len;
    const username_end = std.mem.indexOfScalarPos(u8, token, username_start, '.') orelse return null;
    if (username_end == username_start) return null;
    if (username_end + 1 >= token.len) return null;
    return token[username_start..username_end];
}

pub fn headerValue(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head_buffer, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const header_name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(header_name, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn cookieValue(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    const cookie = headerValue(head_buffer, "cookie") orelse return null;
    var parts = std.mem.splitScalar(u8, cookie, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const equals = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..equals], name)) return trimmed[equals + 1 ..];
    }
    return null;
}

fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var diff: u8 = 0;
    for (left, right) |left_byte, right_byte| {
        diff |= left_byte ^ right_byte;
    }
    return diff == 0;
}

test "header lookup ignores case" {
    const value = headerValue("GET / HTTP/1.1\r\nX-Test: abc\r\n\r\n", "x-test").?;
    try std.testing.expectEqualStrings("abc", value);
}

test "cookie lookup trims cookie pairs" {
    const value = cookieValue("GET / HTTP/1.1\r\nCookie: foo=1; evilblog_session=abc; theme=dark\r\n\r\n", session_cookie_name).?;
    try std.testing.expectEqualStrings("abc", value);
}

test "session token validates configured admin viewer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg: Config = .{
        .blog_host = "127.0.0.1",
        .blog_port = 8080,
        .log_level = .info,
        .sqlite_path = db_path,
        .redis_host = "127.0.0.1",
        .redis_port = 6379,
        .session_secret = "0123456789abcdef0123456789abcdef",
        .api_gateway_enabled = false,
        .api_token = "",
        .site_title = "evilblog",
        .site_logo = "",
        .site_logo_light = "",
        .site_logo_dark = "",
        .site_base_url = "http://127.0.0.1:8080",
        .site_description = "Latest posts from evilblog.",
        .site_default_og_image = "http://127.0.0.1:8080/statics/og-default.png",
        .donate_paypal_url = "https://www.paypal.com/donate",
        .donate_kofi_url = "https://ko-fi.com/",
        .donate_bitcoin_url = "bitcoin:",
        .donate_about_readme_url = "",
        .donate_about_profile_image_url = "",
        .footer_text = "evilblog",
    };

    try db.migrate(std.testing.allocator, cfg);
    const users: user.Store = .{ .allocator = std.testing.allocator, .cfg = cfg };
    const password = (try users.bootstrapDefaultAdminIfEmpty(std.testing.io, 100)).?;
    defer std.testing.allocator.free(password);

    const cookie = try loginCookie(std.testing.allocator, cfg, "admin");
    defer std.testing.allocator.free(cookie);
    const request = try std.fmt.allocPrint(std.testing.allocator, "GET /admin HTTP/1.1\r\nCookie: {s}\r\n\r\n", .{cookie});
    defer std.testing.allocator.free(request);

    var viewer = (try sessionViewer(std.testing.allocator, cfg, users, request)).?;
    defer viewer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("admin", viewer.username);
    try std.testing.expectEqual(Role.admin, viewer.role);
    try std.testing.expect(isAdmin(viewer));
    try std.testing.expect(viewer.must_change_password);
    try std.testing.expectEqualStrings("admin", @tagName(viewer.role));
}
