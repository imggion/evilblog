//! SQLite-backed post storage with Redis as an optional cache.
const std = @import("std");
const Config = @import("config.zig").Config;
const db = @import("db.zig");
const Logger = @import("logger.zig").Logger;
const redis = @import("redis.zig");

pub const per_page = 30;

pub const Post = struct {
    id: []u8,
    title: []u8,
    slug: []u8,
    body: []u8,
    excerpt: []u8,
    og_image: []u8,
    created_at: []u8,
    updated_at: []u8,
    author: []u8,
    points: []u8,
    status: []u8,
    tags: []u8,

    pub fn deinit(self: *Post, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.slug);
        allocator.free(self.body);
        allocator.free(self.excerpt);
        allocator.free(self.og_image);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.free(self.author);
        allocator.free(self.points);
        allocator.free(self.status);
        allocator.free(self.tags);
    }
};

pub const PostList = struct {
    items: []Post,

    pub fn deinit(self: *PostList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const SaveInput = struct {
    id: ?[]const u8,
    title: []const u8,
    slug: ?[]const u8,
    body: []const u8,
    excerpt: []const u8,
    og_image: []const u8,
    status: []const u8,
    tags: []const u8,
    author: []const u8,
};

pub fn refreshRedisCache(allocator: std.mem.Allocator, io: std.Io, cfg: Config) void {
    const store: Store = .{ .allocator = allocator, .io = io, .cfg = cfg };
    store.rebuildRedisCache() catch |err| {
        Logger.init(cfg.log_level).warn("redis.cache_unavailable", "error={s}", .{@errorName(err)});
    };
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,

    fn client(self: Store) redis.Client {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .host = self.cfg.redis_host,
            .port = self.cfg.redis_port,
            .username = self.cfg.redis_username,
            .password = self.cfg.redis_password,
        };
    }

    pub fn save(self: Store, input: SaveInput, now_seconds: i64) ![]u8 {
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0) return error.TitleRequired;

        const status = if (std.mem.eql(u8, input.status, "draft")) "draft" else "published";
        const existing_id = if (input.id) |id| blankToNull(std.mem.trim(u8, id, " \t\r\n")) else null;
        const id_number = if (existing_id) |raw_id| try parseId(raw_id) else null;

        var existing: ?Post = if (id_number) |id| try self.readByIdSqliteNumber(id) else null;
        defer if (existing) |*post| post.deinit(self.allocator);

        const wanted_slug = if (input.slug) |raw_slug| std.mem.trim(u8, raw_slug, " \t\r\n") else "";
        const slug = if (wanted_slug.len > 0)
            try slugify(self.allocator, wanted_slug)
        else
            try slugify(self.allocator, title);
        errdefer self.allocator.free(slug);

        const created_at = if (existing) |post|
            std.fmt.parseInt(i64, post.created_at, 10) catch now_seconds
        else
            now_seconds;
        const author = if (existing) |post|
            if (post.author.len > 0) post.author else input.author
        else
            input.author;

        const saved_id = try self.saveSqlite(id_number, .{
            .id = null,
            .title = title,
            .slug = slug,
            .body = input.body,
            .excerpt = input.excerpt,
            .og_image = input.og_image,
            .status = status,
            .tags = input.tags,
            .author = author,
        }, created_at, now_seconds);
        defer self.allocator.free(saved_id);

        if (existing) |post| {
            if (!std.mem.eql(u8, post.slug, slug)) self.deleteCachedSlugBestEffort(post.slug);
        }
        if (try self.readByIdSqlite(saved_id)) |item| {
            var mutable_item = item;
            defer mutable_item.deinit(self.allocator);
            self.cachePostBestEffort(mutable_item);
        }

        return slug;
    }

    pub fn upvoteBySlug(self: Store, slug: []const u8, username: []const u8, now_seconds: i64) !void {
        var item = (try self.readBySlugSqlite(slug)) orelse return error.PostNotFound;
        defer item.deinit(self.allocator);

        const post_id = try parseId(item.id);
        try self.insertUpvoteSqlite(post_id, username, now_seconds);

        if (try self.readByIdSqliteNumber(post_id)) |updated| {
            var mutable_updated = updated;
            defer mutable_updated.deinit(self.allocator);
            self.cachePostBestEffort(mutable_updated);
        }
    }

    pub fn readBySlug(self: Store, slug: []const u8) !?Post {
        if (self.readBySlugRedis(slug) catch null) |post| return post;
        const post = try self.readBySlugSqlite(slug);
        if (post) |item| self.cachePostBestEffort(item);
        return post;
    }

    pub fn readById(self: Store, id: []const u8) !?Post {
        if (self.readByIdRedis(id) catch null) |post| return post;
        const post = try self.readByIdSqlite(id);
        if (post) |item| self.cachePostBestEffort(item);
        return post;
    }

    pub fn readByIdFresh(self: Store, id: []const u8) !?Post {
        return try self.readByIdSqlite(id);
    }

    pub fn listPublished(self: Store, page: usize) !PostList {
        if (self.listPublishedRedis(page) catch null) |posts| return posts;
        const posts = try self.listPublishedSqlite(page);
        for (posts.items) |item| self.cachePostBestEffort(item);
        return posts;
    }

    pub fn countDrafts(self: Store) !usize {
        return try self.countDraftsSqlite();
    }

    pub fn listDrafts(self: Store) !PostList {
        return try self.listDraftsSqlite();
    }

    pub fn deleteByIdForAuthor(self: Store, id: []const u8, author: []const u8) !void {
        const id_number = parseId(id) catch return error.PostNotFound;
        var existing = (try self.readByIdSqliteNumber(id_number)) orelse return error.PostNotFound;
        defer existing.deinit(self.allocator);

        if (existing.author.len == 0 or !std.mem.eql(u8, existing.author, author)) return error.PostNotFound;

        try self.deleteSqlite(id_number);
        self.deleteCachedPostBestEffort(existing);
    }

    fn saveSqlite(self: Store, id: ?i64, input: SaveInput, created_at: i64, updated_at: i64) ![]u8 {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        if (id) |id_number| {
            const stmt = try db.prepare(conn,
                \\INSERT INTO posts (id, title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags)
                \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                \\ON CONFLICT(id) DO UPDATE SET
                \\  title = excluded.title,
                \\  slug = excluded.slug,
                \\  body = excluded.body,
                \\  excerpt = excluded.excerpt,
                \\  og_image = excluded.og_image,
                \\  created_at = excluded.created_at,
                \\  updated_at = excluded.updated_at,
                \\  author = excluded.author,
                \\  status = excluded.status,
                \\  tags = excluded.tags
            );
            defer db.finalize(stmt);

            try db.bindInt(stmt, 1, id_number);
            try db.bindText(stmt, 2, input.title);
            try db.bindText(stmt, 3, input.slug.?);
            try db.bindText(stmt, 4, input.body);
            try db.bindText(stmt, 5, input.excerpt);
            try db.bindText(stmt, 6, input.og_image);
            try db.bindInt(stmt, 7, created_at);
            try db.bindInt(stmt, 8, updated_at);
            try db.bindText(stmt, 9, input.author);
            try db.bindText(stmt, 10, input.status);
            try db.bindText(stmt, 11, input.tags);
            try stepSave(stmt);
            return try std.fmt.allocPrint(self.allocator, "{d}", .{id_number});
        }

        const stmt = try db.prepare(conn,
            \\INSERT INTO posts (title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer db.finalize(stmt);

        try db.bindText(stmt, 1, input.title);
        try db.bindText(stmt, 2, input.slug.?);
        try db.bindText(stmt, 3, input.body);
        try db.bindText(stmt, 4, input.excerpt);
        try db.bindText(stmt, 5, input.og_image);
        try db.bindInt(stmt, 6, created_at);
        try db.bindInt(stmt, 7, updated_at);
        try db.bindText(stmt, 8, input.author);
        try db.bindText(stmt, 9, input.status);
        try db.bindText(stmt, 10, input.tags);
        try stepSave(stmt);
        return try std.fmt.allocPrint(self.allocator, "{d}", .{db.lastInsertRowId(conn)});
    }

    fn insertUpvoteSqlite(self: Store, post_id: i64, username: []const u8, created_at: i64) !void {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\INSERT INTO post_upvotes (post_id, user, created_at)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT(post_id, user) DO NOTHING
        );
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, post_id);
        try db.bindText(stmt, 2, username);
        try db.bindInt(stmt, 3, created_at);
        try db.stepDone(stmt);
    }

    fn deleteSqlite(self: Store, id: i64) !void {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn, "DELETE FROM posts WHERE id = ?");
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, id);
        try db.stepDone(stmt);
    }

    fn readBySlugSqlite(self: Store, slug: []const u8) !?Post {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT id, title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags,
            \\  (SELECT COUNT(*) FROM post_upvotes WHERE post_id = posts.id) AS points
            \\FROM posts WHERE slug = ? LIMIT 1
        );
        defer db.finalize(stmt);

        try db.bindText(stmt, 1, slug);
        return try readPostRow(self.allocator, stmt);
    }

    fn readByIdSqlite(self: Store, id: []const u8) !?Post {
        const id_number = parseId(id) catch return null;
        return try self.readByIdSqliteNumber(id_number);
    }

    fn readByIdSqliteNumber(self: Store, id: i64) !?Post {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT id, title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags,
            \\  (SELECT COUNT(*) FROM post_upvotes WHERE post_id = posts.id) AS points
            \\FROM posts WHERE id = ? LIMIT 1
        );
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, id);
        return try readPostRow(self.allocator, stmt);
    }

    fn listPublishedSqlite(self: Store, page: usize) !PostList {
        const safe_page = @max(page, 1);
        const offset: i64 = @intCast((safe_page - 1) * per_page);
        const limit: i64 = per_page;

        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT id, title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags,
            \\  (SELECT COUNT(*) FROM post_upvotes WHERE post_id = posts.id) AS points
            \\FROM posts WHERE status = 'published'
            \\ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?
        );
        defer db.finalize(stmt);

        try db.bindInt(stmt, 1, limit);
        try db.bindInt(stmt, 2, offset);
        return try readPostList(self.allocator, stmt);
    }

    fn countDraftsSqlite(self: Store) !usize {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn, "SELECT COUNT(*) FROM posts WHERE status = 'draft'");
        defer db.finalize(stmt);

        if (try db.step(stmt) != .row) return error.SqliteError;
        const count = try db.intColumnTextAlloc(self.allocator, stmt, 0);
        defer self.allocator.free(count);
        return try std.fmt.parseInt(usize, count, 10);
    }

    fn listDraftsSqlite(self: Store) !PostList {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT id, title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags,
            \\  (SELECT COUNT(*) FROM post_upvotes WHERE post_id = posts.id) AS points
            \\FROM posts WHERE status = 'draft'
            \\ORDER BY updated_at DESC, id DESC
        );
        defer db.finalize(stmt);

        return try readPostList(self.allocator, stmt);
    }

    fn listAllSqlite(self: Store) !PostList {
        const conn = try db.open(self.allocator, self.cfg);
        defer db.close(conn);

        const stmt = try db.prepare(conn,
            \\SELECT id, title, slug, body, excerpt, og_image, created_at, updated_at, author, status, tags,
            \\  (SELECT COUNT(*) FROM post_upvotes WHERE post_id = posts.id) AS points
            \\FROM posts ORDER BY id ASC
        );
        defer db.finalize(stmt);

        return try readPostList(self.allocator, stmt);
    }

    fn readBySlugRedis(self: Store, slug: []const u8) !?Post {
        const slug_key = try std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{slug});
        defer self.allocator.free(slug_key);

        const maybe_id = try self.client().commandBulk(&.{ "GET", slug_key });
        const id = maybe_id orelse return null;
        defer self.allocator.free(id);
        return try self.readByIdRedis(id);
    }

    fn readByIdRedis(self: Store, id: []const u8) !?Post {
        const key = try std.fmt.allocPrint(self.allocator, "post:{s}", .{id});
        defer self.allocator.free(key);

        const values = try self.client().commandArray(&.{
            "HMGET",      key,
            "title",      "slug",
            "body",       "excerpt",
            "og_image",   "created_at",
            "updated_at", "author",
            "status",     "tags",
            "points",
        });
        defer redis.freeArray(self.allocator, values);

        if (values.len != 11) return error.UnexpectedRedisResponse;
        if (values[0] == null or values[1] == null) return null;

        return .{
            .id = try self.allocator.dupe(u8, id),
            .title = try takeOrDefault(self.allocator, values, 0, ""),
            .slug = try takeOrDefault(self.allocator, values, 1, ""),
            .body = try takeOrDefault(self.allocator, values, 2, ""),
            .excerpt = try takeOrDefault(self.allocator, values, 3, ""),
            .og_image = try takeOrDefault(self.allocator, values, 4, ""),
            .created_at = try takeOrDefault(self.allocator, values, 5, "0"),
            .updated_at = try takeOrDefault(self.allocator, values, 6, "0"),
            .author = try takeOrDefault(self.allocator, values, 7, ""),
            .status = try takeOrDefault(self.allocator, values, 8, "draft"),
            .tags = try takeOrDefault(self.allocator, values, 9, ""),
            .points = try takeOrDefault(self.allocator, values, 10, "0"),
        };
    }

    fn listPublishedRedis(self: Store, page: usize) !?PostList {
        const safe_page = @max(page, 1);
        const start = (safe_page - 1) * per_page;
        const stop = start + per_page - 1;
        const start_s = try std.fmt.allocPrint(self.allocator, "{d}", .{start});
        defer self.allocator.free(start_s);
        const stop_s = try std.fmt.allocPrint(self.allocator, "{d}", .{stop});
        defer self.allocator.free(stop_s);

        const ids = try self.client().commandArray(&.{ "ZREVRANGE", "posts:published", start_s, stop_s });
        defer redis.freeArray(self.allocator, ids);
        if (ids.len == 0) return null;

        var list: std.ArrayList(Post) = .empty;
        errdefer {
            for (list.items) |*item| item.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        for (ids) |maybe_id| {
            const id = maybe_id orelse continue;
            if (try self.readByIdRedis(id)) |post| {
                if (std.mem.eql(u8, post.status, "published")) {
                    try list.append(self.allocator, post);
                } else {
                    var mutable_post = post;
                    mutable_post.deinit(self.allocator);
                }
            }
        }

        return .{ .items = try list.toOwnedSlice(self.allocator) };
    }

    fn cachePostBestEffort(self: Store, item: Post) void {
        self.cachePost(item) catch |err| {
            Logger.init(self.cfg.log_level).debug("redis.cache_write_skipped", "post_id={s} error={s}", .{ item.id, @errorName(err) });
        };
    }

    fn deleteCachedSlugBestEffort(self: Store, slug: []const u8) void {
        const slug_key = std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{slug}) catch return;
        defer self.allocator.free(slug_key);
        _ = self.client().commandInteger(&.{ "DEL", slug_key }) catch return;
    }

    fn deleteCachedPostBestEffort(self: Store, item: Post) void {
        const post_key = std.fmt.allocPrint(self.allocator, "post:{s}", .{item.id}) catch return;
        defer self.allocator.free(post_key);
        const slug_key = std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{item.slug}) catch return;
        defer self.allocator.free(slug_key);

        _ = self.client().commandInteger(&.{ "DEL", post_key, slug_key }) catch return;
        _ = self.client().commandInteger(&.{ "ZREM", "posts:published", item.id }) catch return;
        _ = self.client().commandInteger(&.{ "SREM", "posts:drafts", item.id }) catch return;
    }

    fn cachePost(self: Store, item: Post) !void {
        const key = try std.fmt.allocPrint(self.allocator, "post:{s}", .{item.id});
        defer self.allocator.free(key);

        _ = try self.client().commandInteger(&.{
            "HSET",       key,
            "title",      item.title,
            "slug",       item.slug,
            "body",       item.body,
            "excerpt",    item.excerpt,
            "og_image",   item.og_image,
            "created_at", item.created_at,
            "updated_at", item.updated_at,
            "author",     item.author,
            "status",     item.status,
            "tags",       item.tags,
            "points",     item.points,
        });

        const slug_key = try std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{item.slug});
        defer self.allocator.free(slug_key);
        try self.client().commandStatus(&.{ "SET", slug_key, item.id });

        if (std.mem.eql(u8, item.status, "published")) {
            _ = try self.client().commandInteger(&.{ "ZADD", "posts:published", item.created_at, item.id });
            _ = try self.client().commandInteger(&.{ "SREM", "posts:drafts", item.id });
        } else {
            _ = try self.client().commandInteger(&.{ "ZREM", "posts:published", item.id });
            _ = try self.client().commandInteger(&.{ "SADD", "posts:drafts", item.id });
        }
    }

    fn rebuildRedisCache(self: Store) !void {
        _ = try self.client().commandInteger(&.{ "DEL", "posts:published", "posts:drafts" });

        var posts = try self.listAllSqlite();
        defer posts.deinit(self.allocator);

        var max_id: i64 = 0;
        for (posts.items) |item| {
            try self.cachePost(item);
            max_id = @max(max_id, std.fmt.parseInt(i64, item.id, 10) catch 0);
        }

        const max_id_s = try std.fmt.allocPrint(self.allocator, "{d}", .{max_id});
        defer self.allocator.free(max_id_s);
        try self.client().commandStatus(&.{ "SET", "post:next_id", max_id_s });
    }
};

fn stepSave(stmt: db.Statement) !void {
    db.stepWrite(stmt) catch |err| switch (err) {
        error.SqliteConstraint => return error.SlugTaken,
        else => return err,
    };
}

fn readPostRow(allocator: std.mem.Allocator, stmt: db.Statement) !?Post {
    return switch (try db.step(stmt)) {
        .done => null,
        .row => try postFromRow(allocator, stmt),
    };
}

fn readPostList(allocator: std.mem.Allocator, stmt: db.Statement) !PostList {
    var list: std.ArrayList(Post) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    while (true) {
        switch (try db.step(stmt)) {
            .row => try list.append(allocator, try postFromRow(allocator, stmt)),
            .done => return .{ .items = try list.toOwnedSlice(allocator) },
        }
    }
}

fn postFromRow(allocator: std.mem.Allocator, stmt: db.Statement) !Post {
    return .{
        .id = try db.intColumnTextAlloc(allocator, stmt, 0),
        .title = try db.textColumnAlloc(allocator, stmt, 1),
        .slug = try db.textColumnAlloc(allocator, stmt, 2),
        .body = try db.textColumnAlloc(allocator, stmt, 3),
        .excerpt = try db.textColumnAlloc(allocator, stmt, 4),
        .og_image = try db.textColumnAlloc(allocator, stmt, 5),
        .created_at = try db.intColumnTextAlloc(allocator, stmt, 6),
        .updated_at = try db.intColumnTextAlloc(allocator, stmt, 7),
        .author = try db.textColumnAlloc(allocator, stmt, 8),
        .status = try db.textColumnAlloc(allocator, stmt, 9),
        .tags = try db.textColumnAlloc(allocator, stmt, 10),
        .points = try db.intColumnTextAlloc(allocator, stmt, 11),
    };
}

fn parseId(value: []const u8) !i64 {
    const id = try std.fmt.parseInt(i64, value, 10);
    if (id <= 0) return error.InvalidId;
    return id;
}

fn takeOrDefault(allocator: std.mem.Allocator, values: []?[]u8, index: usize, default_value: []const u8) ![]u8 {
    if (values[index]) |value| {
        values[index] = null;
        return value;
    }
    return try allocator.dupe(u8, default_value);
}

fn blankToNull(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

pub fn slugify(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var previous_dash = false;
    for (title) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try out.append(allocator, std.ascii.toLower(byte));
            previous_dash = false;
        } else if (!previous_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            previous_dash = true;
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        out.items.len -= 1;
    }

    if (out.items.len == 0) try out.appendSlice(allocator, "post");
    return try out.toOwnedSlice(allocator);
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

test "slugify lowercases and collapses separators" {
    const slug = try slugify(std.testing.allocator, " Hello, Zig 0.16! ");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("hello-zig-0-16", slug);
}

test "sqlite store saves and reads without redis" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .io = std.testing.io, .cfg = cfg };
    const slug = try store.save(.{
        .id = null,
        .title = "Hello SQLite",
        .slug = null,
        .body = "body",
        .excerpt = "",
        .og_image = "",
        .status = "published",
        .tags = "zig,sqlite",
        .author = "admin",
    }, 123);
    defer std.testing.allocator.free(slug);

    var post = (try store.readBySlug(slug)).?;
    defer post.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello SQLite", post.title);
    try std.testing.expectEqualStrings("admin", post.author);
    try std.testing.expectEqualStrings("0", post.points);

    var posts = try store.listPublished(1);
    defer posts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), posts.items.len);

    const draft_slug = try store.save(.{
        .id = null,
        .title = "Draft SQLite",
        .slug = null,
        .body = "draft body",
        .excerpt = "",
        .og_image = "",
        .status = "draft",
        .tags = "",
        .author = "admin",
    }, 124);
    defer std.testing.allocator.free(draft_slug);

    try std.testing.expectEqual(@as(usize, 1), try store.countDrafts());
    var drafts = try store.listDrafts();
    defer drafts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), drafts.items.len);
    try std.testing.expectEqualStrings("Draft SQLite", drafts.items[0].title);
}

test "sqlite upvotes are counted once per user" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .io = std.testing.io, .cfg = cfg };
    const slug = try store.save(.{
        .id = null,
        .title = "Vote Me",
        .slug = null,
        .body = "body",
        .excerpt = "",
        .og_image = "",
        .status = "published",
        .tags = "",
        .author = "admin",
    }, 123);
    defer std.testing.allocator.free(slug);

    try store.upvoteBySlug(slug, "admin", 124);
    try store.upvoteBySlug(slug, "admin", 125);

    var post = (try store.readBySlug(slug)).?;
    defer post.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1", post.points);
}

test "sqlite store deletes posts for the author" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evilblog.sqlite3", .{&tmp.sub_path});
    defer std.testing.allocator.free(db_path);

    const cfg = testConfig(db_path);
    try db.migrate(std.testing.allocator, cfg);

    const store: Store = .{ .allocator = std.testing.allocator, .io = std.testing.io, .cfg = cfg };
    const published_slug = try store.save(.{
        .id = null,
        .title = "Delete Me",
        .slug = null,
        .body = "body",
        .excerpt = "",
        .og_image = "",
        .status = "published",
        .tags = "",
        .author = "admin",
    }, 123);
    defer std.testing.allocator.free(published_slug);

    const draft_slug = try store.save(.{
        .id = null,
        .title = "Draft Delete Me",
        .slug = null,
        .body = "draft body",
        .excerpt = "",
        .og_image = "",
        .status = "draft",
        .tags = "",
        .author = "admin",
    }, 124);
    defer std.testing.allocator.free(draft_slug);

    try store.upvoteBySlug(published_slug, "admin", 125);

    var published = (try store.readBySlug(published_slug)).?;
    defer published.deinit(std.testing.allocator);
    try std.testing.expectError(error.PostNotFound, store.deleteByIdForAuthor(published.id, "other"));

    try store.deleteByIdForAuthor(published.id, "admin");
    try std.testing.expect((try store.readBySlug(published_slug)) == null);

    var posts = try store.listPublished(1);
    defer posts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), posts.items.len);
    try std.testing.expectEqual(@as(usize, 1), try store.countDrafts());

    var draft = (try store.readBySlug(draft_slug)).?;
    defer draft.deinit(std.testing.allocator);
    try store.deleteByIdForAuthor(draft.id, "admin");
    try std.testing.expect((try store.readBySlug(draft_slug)) == null);
    try std.testing.expectEqual(@as(usize, 0), try store.countDrafts());
}
