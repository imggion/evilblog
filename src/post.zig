//! Redis-backed post storage and slug/id rules.
//!
//! The store intentionally exposes coarse post operations rather than leaking
//! Redis commands into route handlers, which keeps request code focused on HTTP.
const std = @import("std");
const Config = @import("config.zig").Config;
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
};

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
        };
    }

    pub fn save(self: Store, input: SaveInput, now_seconds: i64) ![]u8 {
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0) return error.TitleRequired;

        // Only `draft` is special; any other value follows the public default.
        const status = if (std.mem.eql(u8, input.status, "draft")) "draft" else "published";
        const existing_id = if (input.id) |id| blankToNull(std.mem.trim(u8, id, " \t\r\n")) else null;
        const id = if (existing_id) |raw_id|
            try self.allocator.dupe(u8, raw_id)
        else
            try self.nextId();
        defer self.allocator.free(id);

        var existing: ?Post = if (existing_id != null) try self.readById(id) else null;
        defer if (existing) |*post| post.deinit(self.allocator);

        const wanted_slug = if (input.slug) |raw_slug| std.mem.trim(u8, raw_slug, " \t\r\n") else "";
        const slug = if (wanted_slug.len > 0)
            try slugify(self.allocator, wanted_slug)
        else
            try slugify(self.allocator, title);
        defer self.allocator.free(slug);

        const now = try std.fmt.allocPrint(self.allocator, "{d}", .{now_seconds});
        defer self.allocator.free(now);

        // Preserve original creation time so edits do not reorder the archive.
        const created_at = if (existing) |post| post.created_at else now;
        const key = try std.fmt.allocPrint(self.allocator, "post:{s}", .{id});
        defer self.allocator.free(key);

        _ = try self.client().commandInteger(&.{
            "HSET",       key,
            "title",      title,
            "slug",       slug,
            "body",       input.body,
            "excerpt",    input.excerpt,
            "og_image",   input.og_image,
            "created_at", created_at,
            "updated_at", now,
            "status",     status,
            "tags",       input.tags,
        });

        if (existing) |post| {
            if (!std.mem.eql(u8, post.slug, slug)) {
                const old_slug_key = try std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{post.slug});
                defer self.allocator.free(old_slug_key);
                _ = try self.client().commandInteger(&.{ "DEL", old_slug_key });
            }
        }

        const slug_key = try std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{slug});
        defer self.allocator.free(slug_key);
        try self.client().commandStatus(&.{ "SET", slug_key, id });

        // The hash is the canonical record; these indexes optimize the public
        // archive and keep drafts out of published pagination.
        if (std.mem.eql(u8, status, "published")) {
            _ = try self.client().commandInteger(&.{ "ZADD", "posts:published", created_at, id });
            _ = try self.client().commandInteger(&.{ "SREM", "posts:drafts", id });
        } else {
            _ = try self.client().commandInteger(&.{ "ZREM", "posts:published", id });
            _ = try self.client().commandInteger(&.{ "SADD", "posts:drafts", id });
        }

        return try self.allocator.dupe(u8, slug);
    }

    pub fn readBySlug(self: Store, slug: []const u8) !?Post {
        const slug_key = try std.fmt.allocPrint(self.allocator, "post_by_slug:{s}", .{slug});
        defer self.allocator.free(slug_key);

        const maybe_id = try self.client().commandBulk(&.{ "GET", slug_key });
        const id = maybe_id orelse return null;
        defer self.allocator.free(id);
        return try self.readById(id);
    }

    pub fn readById(self: Store, id: []const u8) !?Post {
        const key = try std.fmt.allocPrint(self.allocator, "post:{s}", .{id});
        defer self.allocator.free(key);

        const values = try self.client().commandArray(&.{
            "HMGET",      key,
            "title",      "slug",
            "body",       "excerpt",
            "og_image",   "created_at",
            "updated_at", "status",
            "tags",
        });
        defer redis.freeArray(self.allocator, values);

        if (values.len != 9) return error.UnexpectedRedisResponse;
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
            .status = try takeOrDefault(self.allocator, values, 7, "draft"),
            .tags = try takeOrDefault(self.allocator, values, 8, ""),
        };
    }

    pub fn listPublished(self: Store, page: usize) !PostList {
        const safe_page = @max(page, 1);
        const start = (safe_page - 1) * per_page;
        const stop = start + per_page - 1;
        const start_s = try std.fmt.allocPrint(self.allocator, "{d}", .{start});
        defer self.allocator.free(start_s);
        const stop_s = try std.fmt.allocPrint(self.allocator, "{d}", .{stop});
        defer self.allocator.free(stop_s);

        const ids = try self.client().commandArray(&.{ "ZREVRANGE", "posts:published", start_s, stop_s });
        defer redis.freeArray(self.allocator, ids);

        var list: std.ArrayList(Post) = .empty;
        errdefer {
            for (list.items) |*item| item.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        for (ids) |maybe_id| {
            const id = maybe_id orelse continue;
            if (try self.readById(id)) |post| {
                // Recheck after loading because Redis index updates are not
                // wrapped in a transaction in this small store.
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

    fn nextId(self: Store) ![]u8 {
        const n = try self.client().commandInteger(&.{ "INCR", "post:next_id" });
        return try std.fmt.allocPrint(self.allocator, "{d}", .{n});
    }
};

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

test "slugify lowercases and collapses separators" {
    const slug = try slugify(std.testing.allocator, " Hello, Zig 0.16! ");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("hello-zig-0-16", slug);
}
