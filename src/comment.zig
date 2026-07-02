// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! SQLite-backed anonymous comments for posts.
const std = @import("std");

const Config = @import("config.zig").Config;
const db = @import("db.zig");

const max_author_len = 80;
const max_body_len = 5000;

pub const Comment = struct {
    id: []u8,
    post_id: []u8,
    parent_id: []u8,
    author: []u8,
    body: []u8,
    created_at: []u8,

    pub fn deinit(self: *Comment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.post_id);
        allocator.free(self.parent_id);
        allocator.free(self.author);
        allocator.free(self.body);
        allocator.free(self.created_at);
    }
};

pub const CommentList = struct {
    items: []Comment,

    pub fn deinit(self: *CommentList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    cfg: Config,

    pub fn addByPostSlug(
        self: Store,
        slug: []const u8,
        parent_id: ?[]const u8,
        author: []const u8,
        body: []const u8,
        created_at: i64,
    ) !void {
        const clean_author = std.mem.trim(u8, author, " \t\r\n");
        if (clean_author.len == 0) return error.AuthorRequired;
        if (clean_author.len > max_author_len) return error.AuthorTooLong;

        const clean_body = std.mem.trim(u8, body, " \t\r\n");
        if (clean_body.len == 0) return error.CommentRequired;
        if (clean_body.len > max_body_len) return error.CommentTooLong;

        const clean_parent = if (parent_id) |value| blankToNull(std.mem.trim(u8, value, " \t\r\n")) else null;
        const parent_number = if (clean_parent) |value| try parseId(value) else null;

        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const post_id = try postIdBySlug(self.allocator, conn, slug);
        if (parent_number) |id| {
            if (!try parentBelongsToPost(conn, id, post_id)) return error.CommentParentNotFound;
        }

        const stmt = try db.prepare(conn,
            \\INSERT INTO comments (post_id, parent_id, author, body, created_at)
            \\VALUES (?, ?, ?, ?, ?)
        );
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, post_id);
        if (parent_number) |id| {
            try db.bindInt(stmt, 2, id);
        } else {
            try db.bindNull(stmt, 2);
        }
        try db.bindText(stmt, 3, clean_author);
        try db.bindText(stmt, 4, clean_body);
        try db.bindInt(stmt, 5, created_at);
        try db.stepDone(stmt);
    }

    pub fn listForPostId(self: Store, post_id: []const u8) !CommentList {
        const id = try parseId(post_id);
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT id, post_id, COALESCE(CAST(parent_id AS TEXT), ''), author, body, created_at
            \\FROM comments WHERE post_id = ?
            \\ORDER BY created_at ASC, id ASC
        );
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, id);
        return try readCommentList(self.allocator, stmt);
    }

    pub fn deleteByIdForAdmin(self: Store, id: []const u8) ![]u8 {
        const id_number = try parseId(id);
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const slug = try commentPostSlug(self.allocator, conn, id_number);
        errdefer self.allocator.free(slug);

        const stmt = try db.prepare(conn, "DELETE FROM comments WHERE id = ?");
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, id_number);
        try db.stepDone(stmt);
        return slug;
    }
};

fn commentPostSlug(allocator: std.mem.Allocator, conn: db.Connection, comment_id: i64) ![]u8 {
    const stmt = try db.prepare(conn,
        \\SELECT posts.slug FROM comments
        \\JOIN posts ON posts.id = comments.post_id
        \\WHERE comments.id = ? LIMIT 1
    );
    defer db.finalize(stmt);

    try db.bindInt(stmt, 1, comment_id);
    if (try db.step(stmt) != .row) return error.CommentNotFound;
    return try db.textColumnAlloc(allocator, stmt, 0);
}

fn postIdBySlug(allocator: std.mem.Allocator, conn: db.Connection, slug: []const u8) !i64 {
    const stmt = try db.prepare(conn, "SELECT id FROM posts WHERE slug = ? LIMIT 1");
    defer db.finalize(stmt);

    try db.bindText(stmt, 1, slug);
    if (try db.step(stmt) != .row) return error.PostNotFound;
    const id = try db.intColumnTextAlloc(allocator, stmt, 0);
    defer allocator.free(id);
    return try parseId(id);
}

fn parentBelongsToPost(conn: db.Connection, parent_id: i64, post_id: i64) !bool {
    const stmt = try db.prepare(conn, "SELECT 1 FROM comments WHERE id = ? AND post_id = ? LIMIT 1");
    defer db.finalize(stmt);

    try db.bindInt(stmt, 1, parent_id);
    try db.bindInt(stmt, 2, post_id);
    return (try db.step(stmt)) == .row;
}

fn readCommentList(allocator: std.mem.Allocator, stmt: db.Statement) !CommentList {
    var list: std.ArrayList(Comment) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    while (true) {
        switch (try db.step(stmt)) {
            .row => try list.append(allocator, try commentFromRow(allocator, stmt)),
            .done => return .{ .items = try list.toOwnedSlice(allocator) },
        }
    }
}

fn commentFromRow(allocator: std.mem.Allocator, stmt: db.Statement) !Comment {
    return .{
        .id = try db.intColumnTextAlloc(allocator, stmt, 0),
        .post_id = try db.intColumnTextAlloc(allocator, stmt, 1),
        .parent_id = try db.textColumnAlloc(allocator, stmt, 2),
        .author = try db.textColumnAlloc(allocator, stmt, 3),
        .body = try db.textColumnAlloc(allocator, stmt, 4),
        .created_at = try db.intColumnTextAlloc(allocator, stmt, 5),
    };
}

fn parseId(value: []const u8) !i64 {
    const id = std.fmt.parseInt(i64, value, 10) catch return error.InvalidId;
    if (id <= 0) return error.InvalidId;
    return id;
}

fn blankToNull(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
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

test "sqlite comments store root comments and replies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    {
        const conn = try db.open(std.testing.allocator, cfg);
        defer db.close(conn);
        try db.exec(conn,
            \\INSERT INTO posts (title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags)
            \\VALUES ('Hello', 'hello', 'body', '', '', 100, 100, 'admin', 'published', '');
        );
    }

    const store: Store = .{ .allocator = std.testing.allocator, .cfg = cfg };
    try store.addByPostSlug("hello", null, " Alice ", " Root <x> ", 101);

    var roots = try store.listForPostId("1");
    defer roots.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings("", roots.items[0].parent_id);
    try std.testing.expectEqualStrings("Alice", roots.items[0].author);
    try std.testing.expectEqualStrings("Root <x>", roots.items[0].body);

    try store.addByPostSlug("hello", roots.items[0].id, "Bob", "Reply", 102);
    try std.testing.expectError(error.CommentParentNotFound, store.addByPostSlug("hello", "999", "Bob", "Nope", 103));

    var comments = try store.listForPostId("1");
    defer comments.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), comments.items.len);
    try std.testing.expectEqualStrings(roots.items[0].id, comments.items[1].parent_id);
    try std.testing.expectEqualStrings("Reply", comments.items[1].body);

    const redirect_slug = try store.deleteByIdForAdmin(roots.items[0].id);
    defer std.testing.allocator.free(redirect_slug);
    try std.testing.expectEqualStrings("hello", redirect_slug);

    var after_delete = try store.listForPostId("1");
    defer after_delete.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after_delete.items.len);
}

test "sqlite comments validate public fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .cfg = cfg };
    try std.testing.expectError(error.AuthorRequired, store.addByPostSlug("missing", null, " ", "body", 101));
    try std.testing.expectError(error.CommentRequired, store.addByPostSlug("missing", null, "alice", " ", 101));
}
