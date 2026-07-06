// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! SQLite connection setup, schema migrations, and statement helpers.
const std = @import("std");

const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Connection = *c.sqlite3;
pub const Statement = *c.sqlite3_stmt;
pub const StepResult = enum { row, done };

// TODO: for myself of the future:
// use a folder /migrations instead of raw strings of queries.
// every migration will be a versioned .sql file
pub fn migrate(allocator: std.mem.Allocator, cfg: Config) !void {
    const conn = try open(allocator, cfg);
    defer close(conn);

    const version = try userVersion(conn);
    switch (version) {
        0 => {
            try exec(conn,
                \\CREATE TABLE posts (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  title TEXT NOT NULL,
                \\  slug TEXT NOT NULL UNIQUE,
                \\  body TEXT NOT NULL DEFAULT '',
                \\  excerpt TEXT NOT NULL DEFAULT '',
                \\  og_image TEXT NOT NULL DEFAULT '',
                \\  created_at INTEGER NOT NULL,
                \\  updated_at INTEGER NOT NULL,
                \\  author TEXT NOT NULL DEFAULT '',
                \\  status TEXT NOT NULL CHECK (status IN ('draft', 'published')),
                \\  tags TEXT NOT NULL DEFAULT ''
                \\);
                \\CREATE TABLE post_upvotes (
                \\  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                \\  user TEXT NOT NULL,
                \\  created_at INTEGER NOT NULL,
                \\  PRIMARY KEY (post_id, user)
                \\);
                \\CREATE INDEX posts_published_idx ON posts(status, created_at DESC, id DESC);
                \\CREATE INDEX post_upvotes_post_idx ON post_upvotes(post_id);
                \\CREATE TABLE comments (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                \\  parent_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
                \\  author TEXT NOT NULL,
                \\  body TEXT NOT NULL,
                \\  created_at INTEGER NOT NULL
                \\);
                \\CREATE INDEX comments_post_idx ON comments(post_id, created_at ASC, id ASC);
                \\CREATE INDEX comments_parent_idx ON comments(parent_id, created_at ASC, id ASC);
                \\CREATE TABLE users (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  username TEXT NOT NULL UNIQUE,
                \\  password_hash TEXT NOT NULL,
                \\  role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
                \\  must_change_password INTEGER NOT NULL DEFAULT 0,
                \\  created_at INTEGER NOT NULL,
                \\  updated_at INTEGER NOT NULL,
                \\  last_login_at INTEGER,
                \\  password_changed_at INTEGER
                \\);
                \\CREATE INDEX users_role_idx ON users(role);
                \\CREATE TABLE post_visits (
                \\  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                \\  visitor_key TEXT NOT NULL,
                \\  created_at INTEGER NOT NULL,
                \\  PRIMARY KEY (post_id, visitor_key)
                \\);
                \\PRAGMA user_version = 5;
            );
        },
        1 => {
            try migrateToV2(conn);
            try migrateToV3(conn);
            try migrateToV4(conn);
            try migrateToV5(conn);
        },
        2 => {
            try migrateToV3(conn);
            try migrateToV4(conn);
            try migrateToV5(conn);
        },
        3 => {
            try migrateToV4(conn);
            try migrateToV5(conn);
        },
        4 => try migrateToV5(conn),
        5 => {},
        else => return error.UnsupportedSchema,
    }
}

pub fn open(allocator: std.mem.Allocator, cfg: Config) !Connection {
    const path = try allocator.dupeZ(u8, cfg.sqlite_path);
    defer allocator.free(path);

    var conn: ?Connection = null;
    const rc = c.sqlite3_open(path.ptr, &conn);
    if (rc != c.SQLITE_OK) {
        if (conn) |handle| {
            logSqlite(handle);
            _ = c.sqlite3_close(handle);
        }
        return error.SqliteError;
    }

    const handle = conn.?;
    errdefer close(handle);
    try exec(handle, "PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;");
    return handle;
}

pub fn close(conn: Connection) void {
    _ = c.sqlite3_close(conn);
}

pub fn exec(conn: Connection, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(conn, sql.ptr, null, null, null) != c.SQLITE_OK) return failDb(conn);
}

pub fn prepare(conn: Connection, sql: []const u8) !Statement {
    var stmt: ?Statement = null;
    if (c.sqlite3_prepare_v2(conn, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return failDb(conn);
    return stmt.?;
}

pub fn finalize(stmt: Statement) void {
    _ = c.sqlite3_finalize(stmt);
}

pub fn bindText(stmt: Statement, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return failStmt(stmt);
}

pub fn bindInt(stmt: Statement, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return failStmt(stmt);
}

pub fn bindNull(stmt: Statement, index: c_int) !void {
    if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) return failStmt(stmt);
}

pub fn step(stmt: Statement) !StepResult {
    const rc = c.sqlite3_step(stmt);
    return switch (rc) {
        c.SQLITE_ROW => .row,
        c.SQLITE_DONE => .done,
        else => failStmt(stmt),
    };
}

pub fn stepDone(stmt: Statement) !void {
    const result = try step(stmt);
    if (result != .done) return failStmt(stmt);
}

pub fn stepWrite(stmt: Statement) !void {
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return;
    if (rc == c.SQLITE_CONSTRAINT) return error.SqliteConstraint;
    return failStmt(stmt);
}

pub fn lastInsertRowId(conn: Connection) i64 {
    return c.sqlite3_last_insert_rowid(conn);
}

pub fn textColumnAlloc(allocator: std.mem.Allocator, stmt: Statement, column: c_int) ![]u8 {
    const raw = c.sqlite3_column_text(stmt, column);
    if (raw == null) return try allocator.dupe(u8, "");
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return try allocator.dupe(u8, raw[0..len]);
}

pub fn intColumnTextAlloc(allocator: std.mem.Allocator, stmt: Statement, column: c_int) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{c.sqlite3_column_int64(stmt, column)});
}

fn migrateToV2(conn: Connection) !void {
    try exec(conn,
        \\BEGIN;
        \\ALTER TABLE posts ADD COLUMN author TEXT NOT NULL DEFAULT '';
        \\CREATE TABLE post_upvotes (
        \\  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
        \\  user TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  PRIMARY KEY (post_id, user)
        \\);
        \\CREATE INDEX post_upvotes_post_idx ON post_upvotes(post_id);
    );
    errdefer exec(conn, "ROLLBACK;") catch {};

    const stmt = try prepare(conn, "UPDATE posts SET author = 'admin' WHERE author = ''");
    defer finalize(stmt);
    try stepDone(stmt);

    try exec(conn, "PRAGMA user_version = 2; COMMIT;");
}

fn migrateToV3(conn: Connection) !void {
    try exec(conn,
        \\BEGIN;
        \\CREATE TABLE comments (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
        \\  parent_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
        \\  author TEXT NOT NULL,
        \\  body TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\);
        \\CREATE INDEX comments_post_idx ON comments(post_id, created_at ASC, id ASC);
        \\CREATE INDEX comments_parent_idx ON comments(parent_id, created_at ASC, id ASC);
        \\PRAGMA user_version = 3;
        \\COMMIT;
    );
}

fn migrateToV4(conn: Connection) !void {
    try exec(conn,
        \\BEGIN;
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  username TEXT NOT NULL UNIQUE,
        \\  password_hash TEXT NOT NULL,
        \\  role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
        \\  must_change_password INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  last_login_at INTEGER,
        \\  password_changed_at INTEGER
        \\);
        \\CREATE INDEX users_role_idx ON users(role);
        \\PRAGMA user_version = 4;
        \\COMMIT;
    );
}

fn migrateToV5(conn: Connection) !void {
    try exec(conn,
        \\BEGIN;
        \\CREATE TABLE post_visits (
        \\  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
        \\  visitor_key TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  PRIMARY KEY (post_id, visitor_key)
        \\);
        \\PRAGMA user_version = 5;
        \\COMMIT;
    );
}

fn userVersion(conn: Connection) !i64 {
    const stmt = try prepare(conn, "PRAGMA user_version");
    defer finalize(stmt);

    const result = try step(stmt);
    if (result != .row) return failStmt(stmt);
    return c.sqlite3_column_int64(stmt, 0);
}

fn failDb(conn: Connection) error{SqliteError} {
    logSqlite(conn);
    return error.SqliteError;
}

fn failStmt(stmt: Statement) error{SqliteError} {
    return failDb(c.sqlite3_db_handle(stmt).?);
}

fn logSqlite(conn: Connection) void {
    Logger.init(.info).err("sqlite.error", "message=\"{s}\"", .{std.mem.span(c.sqlite3_errmsg(conn))});
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

test "migration v1 to latest creates upvotes comments and backfills author" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    {
        const conn = try open(std.testing.allocator, cfg);
        defer close(conn);

        try exec(conn,
            \\CREATE TABLE posts (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  title TEXT NOT NULL,
            \\  slug TEXT NOT NULL UNIQUE,
            \\  body TEXT NOT NULL DEFAULT '',
            \\  excerpt TEXT NOT NULL DEFAULT '',
            \\  og_image TEXT NOT NULL DEFAULT '',
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL,
            \\  status TEXT NOT NULL CHECK (status IN ('draft', 'published')),
            \\  tags TEXT NOT NULL DEFAULT ''
            \\);
            \\CREATE INDEX posts_published_idx ON posts(status, created_at DESC, id DESC);
            \\INSERT INTO posts (title, slug, body, excerpt, og_image, created_at, updated_at, status, tags)
            \\VALUES ('Legacy', 'legacy-post', 'body', '', '', 123, 123, 'published', '');
            \\PRAGMA user_version = 1;
        );
    }

    try migrate(std.testing.allocator, cfg);

    const conn = try open(std.testing.allocator, cfg);
    defer close(conn);

    const version_stmt = try prepare(conn, "PRAGMA user_version");
    defer finalize(version_stmt);
    try std.testing.expectEqual(StepResult.row, try step(version_stmt));
    const version = try intColumnTextAlloc(std.testing.allocator, version_stmt, 0);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("5", version);

    const stmt = try prepare(conn,
        \\SELECT author, (SELECT COUNT(*) FROM post_upvotes WHERE post_id = posts.id)
        \\FROM posts WHERE slug = ?
    );
    defer finalize(stmt);

    try bindText(stmt, 1, "legacy-post");
    try std.testing.expectEqual(StepResult.row, try step(stmt));
    const author = try textColumnAlloc(std.testing.allocator, stmt, 0);
    defer std.testing.allocator.free(author);
    const points = try intColumnTextAlloc(std.testing.allocator, stmt, 1);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualStrings("admin", author);
    try std.testing.expectEqualStrings("0", points);
    try std.testing.expectEqual(StepResult.done, try step(stmt));

    const comments_stmt = try prepare(conn, "SELECT COUNT(*) FROM comments");
    defer finalize(comments_stmt);
    try std.testing.expectEqual(StepResult.row, try step(comments_stmt));
    const comment_count = try intColumnTextAlloc(std.testing.allocator, comments_stmt, 0);
    defer std.testing.allocator.free(comment_count);
    try std.testing.expectEqualStrings("0", comment_count);

    const users_stmt = try prepare(conn, "SELECT COUNT(*) FROM users");
    defer finalize(users_stmt);
    try std.testing.expectEqual(StepResult.row, try step(users_stmt));
    const user_count = try intColumnTextAlloc(std.testing.allocator, users_stmt, 0);
    defer std.testing.allocator.free(user_count);
    try std.testing.expectEqualStrings("0", user_count);
}
