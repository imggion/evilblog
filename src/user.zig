// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! SQLite-backed users and password hashing.
const std = @import("std");

const Config = @import("config.zig").Config;
const db = @import("db.zig");

const argon2 = std.crypto.pwhash.argon2;
const password_hash_params = argon2.Params.owasp_2id;
const min_password_len = 12;
const max_password_len = 256;
const max_username_len = 64;

pub const LoginUser = struct {
    username: []u8,
    role: []u8,
    must_change_password: bool,

    pub fn deinit(self: *LoginUser, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.role);
    }
};

pub const SessionInfo = struct {
    role: []u8,
    must_change_password: bool,

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
    }
};

const StoredUser = struct {
    username: []u8,
    password_hash: []u8,
    role: []u8,
    must_change_password: bool,

    fn deinit(self: *StoredUser, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password_hash);
        allocator.free(self.role);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    cfg: Config,

    pub fn bootstrapDefaultAdminIfEmpty(self: Store, io: std.Io, now_seconds: i64) !?[]u8 {
        if (try self.count() != 0) return null;

        const password = try randomPassword(self.allocator, io);
        errdefer self.allocator.free(password);

        const password_hash = try hashPassword(self.allocator, io, password);
        defer self.allocator.free(password_hash);

        try self.insertUser("admin", password_hash, "admin", true, now_seconds);
        return password;
    }

    pub fn authenticate(self: Store, username: []const u8, password: []const u8, now_seconds: i64, io: std.Io) !?LoginUser {
        const clean_username = std.mem.trim(u8, username, " \t\r\n");
        if (clean_username.len == 0 or clean_username.len > max_username_len) return null;
        if (password.len == 0 or password.len > max_password_len) return null;

        var stored = (try self.readStoredUser(clean_username)) orelse return null;
        defer stored.deinit(self.allocator);

        if (!try verifyPassword(self.allocator, io, stored.password_hash, password)) return null;
        try self.updateLastLogin(clean_username, now_seconds);

        return .{
            .username = try self.allocator.dupe(u8, stored.username),
            .role = try self.allocator.dupe(u8, stored.role),
            .must_change_password = stored.must_change_password,
        };
    }

    pub fn sessionInfo(self: Store, username: []const u8) !?SessionInfo {
        const clean_username = std.mem.trim(u8, username, " \t\r\n");
        if (clean_username.len == 0 or clean_username.len > max_username_len) return null;

        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT role, must_change_password FROM users WHERE username = ? LIMIT 1
        );
        defer db.finalize(stmt);

        try db.bindText(stmt, 1, clean_username);
        if (try db.step(stmt) != .row) return null;
        return .{
            .role = try db.textColumnAlloc(self.allocator, stmt, 0),
            .must_change_password = try boolColumn(self.allocator, stmt, 1),
        };
    }

    pub fn changePassword(self: Store, username: []const u8, current_password: []const u8, new_password: []const u8, now_seconds: i64, io: std.Io) !void {
        if (new_password.len < min_password_len) return error.NewPasswordTooShort;
        if (new_password.len > max_password_len) return error.NewPasswordTooLong;

        var stored = (try self.readStoredUser(username)) orelse return error.UserNotFound;
        defer stored.deinit(self.allocator);

        if (!try verifyPassword(self.allocator, io, stored.password_hash, current_password)) return error.CurrentPasswordInvalid;

        const password_hash = try hashPassword(self.allocator, io, new_password);
        defer self.allocator.free(password_hash);

        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\UPDATE users
            \\SET password_hash = ?, must_change_password = 0, updated_at = ?, password_changed_at = ?
            \\WHERE username = ?
        );
        defer db.finalize(stmt);

        try db.bindText(stmt, 1, password_hash);
        try db.bindInt(stmt, 2, now_seconds);
        try db.bindInt(stmt, 3, now_seconds);
        try db.bindText(stmt, 4, username);
        try db.stepDone(stmt);
    }

    // Rename a user and cascade the new username to posts.author and
    // post_upvotes.user so existing posts stay owned by the renamed account
    // and prior upvotes keep counting as the same voter. current_password
    // gates the action so a stolen session cookie alone is not enough.
    pub fn changeUsername(self: Store, current_username: []const u8, current_password: []const u8, new_username: []const u8, now_seconds: i64, io: std.Io) !void {
        const clean_new = std.mem.trim(u8, new_username, " \t\r\n");
        if (clean_new.len == 0) return error.NewUsernameTooShort;
        if (clean_new.len > max_username_len) return error.NewUsernameTooLong;

        var stored = (try self.readStoredUser(current_username)) orelse return error.UserNotFound;
        defer stored.deinit(self.allocator);

        if (!try verifyPassword(self.allocator, io, stored.password_hash, current_password)) return error.CurrentPasswordInvalid;

        if (try self.readStoredUser(clean_new)) |taken| {
            var owned_taken = taken;
            owned_taken.deinit(self.allocator);
            return error.NewUsernameTaken;
        }

        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        try db.exec(conn, "BEGIN;");
        errdefer db.exec(conn, "ROLLBACK;") catch {};

        const user_stmt = try db.prepare(conn,
            \\UPDATE users SET username = ?, updated_at = ? WHERE username = ?
        );
        defer db.finalize(user_stmt);
        try db.bindText(user_stmt, 1, clean_new);
        try db.bindInt(user_stmt, 2, now_seconds);
        try db.bindText(user_stmt, 3, current_username);
        try db.stepDone(user_stmt);

        const posts_stmt = try db.prepare(conn, "UPDATE posts SET author = ? WHERE author = ?");
        defer db.finalize(posts_stmt);
        try db.bindText(posts_stmt, 1, clean_new);
        try db.bindText(posts_stmt, 2, current_username);
        try db.stepDone(posts_stmt);

        const upvotes_stmt = try db.prepare(conn, "UPDATE post_upvotes SET user = ? WHERE user = ?");
        defer db.finalize(upvotes_stmt);
        try db.bindText(upvotes_stmt, 1, clean_new);
        try db.bindText(upvotes_stmt, 2, current_username);
        try db.stepDone(upvotes_stmt);

        try db.exec(conn, "COMMIT;");
    }

    fn count(self: Store) !usize {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn, "SELECT COUNT(*) FROM users");
        defer db.finalize(stmt);

        if (try db.step(stmt) != .row) return error.SqliteError;
        const count_text = try db.intColumnTextAlloc(self.allocator, stmt, 0);
        defer self.allocator.free(count_text);
        return try std.fmt.parseInt(usize, count_text, 10);
    }

    fn insertUser(self: Store, username: []const u8, password_hash: []const u8, role: []const u8, must_change_password: bool, now_seconds: i64) !void {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\INSERT INTO users (username, password_hash, role, must_change_password, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer db.finalize(stmt);

        try db.bindText(stmt, 1, username);
        try db.bindText(stmt, 2, password_hash);
        try db.bindText(stmt, 3, role);
        try db.bindInt(stmt, 4, if (must_change_password) 1 else 0);
        try db.bindInt(stmt, 5, now_seconds);
        try db.bindInt(stmt, 6, now_seconds);
        try db.stepDone(stmt);
    }

    fn readStoredUser(self: Store, username: []const u8) !?StoredUser {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT username, password_hash, role, must_change_password
            \\FROM users WHERE username = ? LIMIT 1
        );
        defer db.finalize(stmt);

        try db.bindText(stmt, 1, username);
        if (try db.step(stmt) != .row) return null;
        return .{
            .username = try db.textColumnAlloc(self.allocator, stmt, 0),
            .password_hash = try db.textColumnAlloc(self.allocator, stmt, 1),
            .role = try db.textColumnAlloc(self.allocator, stmt, 2),
            .must_change_password = try boolColumn(self.allocator, stmt, 3),
        };
    }

    fn updateLastLogin(self: Store, username: []const u8, now_seconds: i64) !void {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn, "UPDATE users SET last_login_at = ?, updated_at = ? WHERE username = ?");
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, now_seconds);
        try db.bindInt(stmt, 2, now_seconds);
        try db.bindText(stmt, 3, username);
        try db.stepDone(stmt);
    }
};

fn hashPassword(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    var buf: [128]u8 = undefined;
    const hash = try argon2.strHash(password, .{ .allocator = allocator, .params = password_hash_params }, &buf, io);
    return try allocator.dupe(u8, hash);
}

fn verifyPassword(allocator: std.mem.Allocator, io: std.Io, password_hash: []const u8, password: []const u8) !bool {
    argon2.strVerify(password_hash, password, .{ .allocator = allocator }, io) catch |err| switch (err) {
        error.PasswordVerificationFailed => return false,
        else => |e| return e,
    };
    return true;
}

fn randomPassword(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var raw: [24]u8 = undefined;
    io.random(&raw);

    const len = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
    return out;
}

fn boolColumn(allocator: std.mem.Allocator, stmt: db.Statement, column: c_int) !bool {
    const text = try db.intColumnTextAlloc(allocator, stmt, column);
    defer allocator.free(text);
    return (try std.fmt.parseInt(i64, text, 10)) != 0;
}

fn testConfig(sqlite_path: []const u8) Config {
    return .{
        .blog_host = "127.0.0.1",
        .blog_port = 8080,
        .log_level = .info,
        .sqlite_path = sqlite_path,
        .redis_host = "127.0.0.1",
        .redis_port = 9,
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
}

test "bootstrap creates one admin with generated password" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .cfg = cfg };
    const password = (try store.bootstrapDefaultAdminIfEmpty(std.testing.io, 100)).?;
    defer std.testing.allocator.free(password);
    try std.testing.expect(password.len >= min_password_len);
    try std.testing.expectEqual(@as(usize, 1), try store.count());
    try std.testing.expect((try store.bootstrapDefaultAdminIfEmpty(std.testing.io, 101)) == null);

    var login = (try store.authenticate("admin", password, 102, std.testing.io)).?;
    defer login.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("admin", login.username);
    try std.testing.expectEqualStrings("admin", login.role);
    try std.testing.expect(login.must_change_password);
    try std.testing.expect((try store.authenticate("admin", "wrong-password", 103, std.testing.io)) == null);
}

test "password change verifies current password and clears bootstrap flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .cfg = cfg };
    const password = (try store.bootstrapDefaultAdminIfEmpty(std.testing.io, 100)).?;
    defer std.testing.allocator.free(password);

    try std.testing.expectError(error.NewPasswordTooShort, store.changePassword("admin", password, "short", 101, std.testing.io));
    try std.testing.expectError(error.CurrentPasswordInvalid, store.changePassword("admin", "wrong-password", "new-password-123", 101, std.testing.io));
    try store.changePassword("admin", password, "new-password-123", 102, std.testing.io);

    var login = (try store.authenticate("admin", "new-password-123", 103, std.testing.io)).?;
    defer login.deinit(std.testing.allocator);
    try std.testing.expect(!login.must_change_password);
}

test "change username cascades to posts and upvotes and rejects taken names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .cfg = cfg };
    const password = (try store.bootstrapDefaultAdminIfEmpty(std.testing.io, 100)).?;
    defer std.testing.allocator.free(password);

    // ponytail: raw seed for cascade assertions, no higher-level post API in user tests.
    {
        const conn = try db.open(std.testing.allocator, cfg);
        defer db.close(conn);
        try db.exec(conn,
            \\INSERT INTO posts (title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags)
            \\VALUES ('P', 'p', '', '', '', 1, 1, 'admin', 'published', '');
        );
        try db.exec(conn,
            \\INSERT INTO post_upvotes (post_id, user, created_at) VALUES (1, 'admin', 1);
        );
    }

    try std.testing.expectError(error.CurrentPasswordInvalid, store.changeUsername("admin", "wrong", "imggion", 110, std.testing.io));
    try std.testing.expectError(error.NewUsernameTooShort, store.changeUsername("admin", password, "   ", 110, std.testing.io));

    try store.changeUsername("admin", password, "imggion", 120, std.testing.io);

    try std.testing.expect((try store.authenticate("admin", password, 121, std.testing.io)) == null);
    var login = (try store.authenticate("imggion", password, 122, std.testing.io)).?;
    defer login.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("imggion", login.username);

    try std.testing.expectError(error.NewUsernameTaken, store.changeUsername("imggion", password, "imggion", 130, std.testing.io));

    {
        const conn = try db.open(std.testing.allocator, cfg);
        defer db.close(conn);

        const post_stmt = try db.prepare(conn, "SELECT author FROM posts WHERE slug = ?");
        defer db.finalize(post_stmt);
        try db.bindText(post_stmt, 1, "p");
        try std.testing.expectEqual(db.StepResult.row, try db.step(post_stmt));
        const author = try db.textColumnAlloc(std.testing.allocator, post_stmt, 0);
        defer std.testing.allocator.free(author);
        try std.testing.expectEqualStrings("imggion", author);

        const up_stmt = try db.prepare(conn, "SELECT user FROM post_upvotes WHERE post_id = 1");
        defer db.finalize(up_stmt);
        try std.testing.expectEqual(db.StepResult.row, try db.step(up_stmt));
        const voter = try db.textColumnAlloc(std.testing.allocator, up_stmt, 0);
        defer std.testing.allocator.free(voter);
        try std.testing.expectEqualStrings("imggion", voter);
    }
}
