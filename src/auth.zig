//! Cookie-session helpers for the single-admin workflow.
//!
//! Sessions are signed from configured credentials so the MVP avoids a session
//! table while still rejecting forged admin cookies.
const std = @import("std");
const Config = @import("config.zig").Config;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const session_cookie_name = "easynews_session";

pub fn sessionUsername(allocator: std.mem.Allocator, cfg: Config, head_buffer: []const u8) !?[]const u8 {
    const token = cookieValue(head_buffer, session_cookie_name) orelse return null;
    const expected = tokenFor(allocator, cfg) catch return null;
    defer allocator.free(expected);
    if (!constantTimeEqual(token, expected)) return null;
    return cfg.admin_user;
}

pub fn validCredentials(cfg: Config, username: []const u8, password: []const u8) bool {
    const configured_user = cfg.admin_user orelse return false;
    const configured_password = cfg.admin_password orelse return false;
    return constantTimeEqual(username, configured_user) and constantTimeEqual(password, configured_password);
}

pub fn loginCookie(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    const token = try tokenFor(allocator, cfg);
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

fn tokenFor(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    const user = cfg.admin_user orelse return error.AuthNotConfigured;
    const password = cfg.admin_password orelse return error.AuthNotConfigured;

    // The admin password doubles as HMAC key so the single-user deployment does
    // not need a separate session-secret setting.
    const message = try std.fmt.allocPrint(allocator, "easynews-session:{s}", .{user});
    defer allocator.free(message);

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, message, password);

    const encoded_user_len = std.base64.url_safe_no_pad.Encoder.calcSize(user.len);
    const encoded_mac_len = std.base64.url_safe_no_pad.Encoder.calcSize(mac.len);
    const token = try allocator.alloc(u8, "v1.".len + encoded_user_len + 1 + encoded_mac_len);
    var offset: usize = 0;
    @memcpy(token[offset..][0.."v1.".len], "v1.");
    offset += "v1.".len;
    offset += std.base64.url_safe_no_pad.Encoder.encode(token[offset..][0..encoded_user_len], user).len;
    token[offset] = '.';
    offset += 1;
    offset += std.base64.url_safe_no_pad.Encoder.encode(token[offset..][0..encoded_mac_len], &mac).len;
    return token[0..offset];
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
    const value = cookieValue("GET / HTTP/1.1\r\nCookie: foo=1; easynews_session=abc; theme=dark\r\n\r\n", session_cookie_name).?;
    try std.testing.expectEqualStrings("abc", value);
}

test "session token validates configured admin" {
    const cfg: Config = .{
        .blog_host = "127.0.0.1",
        .blog_port = 8080,
        .redis_host = "127.0.0.1",
        .redis_port = 6379,
        .admin_user = "admin",
        .admin_password = "secret",
        .site_title = "easynews",
        .site_base_url = "http://127.0.0.1:8080",
        .site_description = "Latest posts from easynews.",
        .site_default_og_image = "http://127.0.0.1:8080/static/og-default.png",
        .footer_text = "easynews",
    };

    const cookie = try loginCookie(std.testing.allocator, cfg);
    defer std.testing.allocator.free(cookie);
    const request = try std.fmt.allocPrint(std.testing.allocator, "GET /admin HTTP/1.1\r\nCookie: {s}\r\n\r\n", .{cookie});
    defer std.testing.allocator.free(request);

    const username = (try sessionUsername(std.testing.allocator, cfg, request)).?;
    try std.testing.expectEqualStrings("admin", username);
}
