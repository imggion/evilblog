// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! Token-authenticated JSON API entry points.
const std = @import("std");

const auth = @import("auth.zig");
const Config = @import("config.zig").Config;
const Logger = @import("logger.zig").Logger;
const post = @import("post.zig");

const max_body_size = 128 * 1024;

const PostPayload = struct {
    title: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    body: ?[]const u8 = null,
    excerpt: ?[]const u8 = null,
    og_image: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tags: ?[]const u8 = null,
};

const PostWriteResponse = struct {
    slug: []const u8,
    url: []const u8,
};

const PostSummary = struct {
    id: []const u8,
    title: []const u8,
    slug: []const u8,
    status: []const u8,
    excerpt: []const u8,
    og_image: []const u8,
    tags: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

const ListPostsResponse = struct {
    posts: []const PostSummary,
};

const ErrorResponse = struct {
    @"error": []const u8,
};

pub fn handleCreatePost(
    allocator: std.mem.Allocator,
    cfg: Config,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    if (!tokenAuthorized(request.head_buffer, cfg.api_token)) {
        try respondError(allocator, request, .unauthorized, "unauthorized");
        return;
    }

    const body = readBody(allocator, request) catch |err| switch (err) {
        error.LengthRequired => {
            try respondError(allocator, request, .length_required, "content-length required");
            return;
        },
        error.BodyTooLarge => {
            try respondError(allocator, request, .payload_too_large, "request body too large");
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(PostPayload, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try respondError(allocator, request, .bad_request, "invalid json");
        return;
    };
    defer parsed.deinit();

    const title = parsed.value.title orelse {
        try respondError(allocator, request, .bad_request, "title is required");
        return;
    };
    const post_body = parsed.value.body orelse {
        try respondError(allocator, request, .bad_request, "body is required");
        return;
    };
    const status = parsed.value.status orelse "draft";
    if (!validStatus(status)) {
        try respondError(allocator, request, .bad_request, "status must be draft or published");
        return;
    }

    const now = std.Io.Clock.Timestamp.now(store.io, .real).raw.toSeconds();
    const saved_slug = store.save(.{
        .id = null,
        .title = title,
        .slug = parsed.value.slug,
        .body = post_body,
        .excerpt = parsed.value.excerpt orelse "",
        .og_image = parsed.value.og_image orelse "",
        .status = status,
        .tags = parsed.value.tags orelse "",
        .author = "admin",
    }, now) catch |err| switch (err) {
        error.TitleRequired => {
            try respondError(allocator, request, .bad_request, "title is required");
            return;
        },
        error.SlugTaken => {
            try respondError(allocator, request, .conflict, "slug already exists");
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(saved_slug);

    const url = try std.fmt.allocPrint(allocator, "/post/{s}", .{saved_slug});
    defer allocator.free(url);
    try respondJsonValue(allocator, request, .created, PostWriteResponse{ .slug = saved_slug, .url = url });
    Logger.init(cfg.log_level).debug("api.post_created", "slug={s} status={s}", .{ saved_slug, status });
}

pub fn handleListPosts(
    allocator: std.mem.Allocator,
    cfg: Config,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    if (!tokenAuthorized(request.head_buffer, cfg.api_token)) {
        try respondError(allocator, request, .unauthorized, "unauthorized");
        return;
    }

    var posts = try store.listAll();
    defer posts.deinit(allocator);

    var summaries: std.ArrayList(PostSummary) = .empty;
    defer summaries.deinit(allocator);
    for (posts.items) |item| {
        try summaries.append(allocator, .{
            .id = item.id,
            .title = item.title,
            .slug = item.slug,
            .status = item.status,
            .excerpt = item.excerpt,
            .og_image = item.og_image,
            .tags = item.tags,
            .created_at = item.created_at,
            .updated_at = item.updated_at,
        });
    }

    try respondJsonValue(allocator, request, .ok, ListPostsResponse{ .posts = summaries.items });
}

pub fn handlePatchPost(
    allocator: std.mem.Allocator,
    cfg: Config,
    store: post.Store,
    request: *std.http.Server.Request,
    id: []const u8,
) !void {
    if (!tokenAuthorized(request.head_buffer, cfg.api_token)) {
        try respondError(allocator, request, .unauthorized, "unauthorized");
        return;
    }

    var existing = (try store.readByIdFresh(id)) orelse {
        try respondError(allocator, request, .not_found, "post not found");
        return;
    };
    defer existing.deinit(allocator);

    const body = readBody(allocator, request) catch |err| switch (err) {
        error.LengthRequired => {
            try respondError(allocator, request, .length_required, "content-length required");
            return;
        },
        error.BodyTooLarge => {
            try respondError(allocator, request, .payload_too_large, "request body too large");
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(PostPayload, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try respondError(allocator, request, .bad_request, "invalid json");
        return;
    };
    defer parsed.deinit();

    if (!hasPatchFields(parsed.value)) {
        try respondError(allocator, request, .bad_request, "at least one field is required");
        return;
    }

    const status = parsed.value.status orelse existing.status;
    if (!validStatus(status)) {
        try respondError(allocator, request, .bad_request, "status must be draft or published");
        return;
    }

    const now = std.Io.Clock.Timestamp.now(store.io, .real).raw.toSeconds();
    const saved_slug = store.save(.{
        .id = existing.id,
        .title = parsed.value.title orelse existing.title,
        .slug = parsed.value.slug orelse existing.slug,
        .body = parsed.value.body orelse existing.body,
        .excerpt = parsed.value.excerpt orelse existing.excerpt,
        .og_image = parsed.value.og_image orelse existing.og_image,
        .status = status,
        .tags = parsed.value.tags orelse existing.tags,
        .author = existing.author,
    }, now) catch |err| switch (err) {
        error.TitleRequired => {
            try respondError(allocator, request, .bad_request, "title is required");
            return;
        },
        error.SlugTaken => {
            try respondError(allocator, request, .conflict, "slug already exists");
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(saved_slug);

    const url = try std.fmt.allocPrint(allocator, "/post/{s}", .{saved_slug});
    defer allocator.free(url);
    try respondJsonValue(allocator, request, .ok, PostWriteResponse{ .slug = saved_slug, .url = url });
    Logger.init(cfg.log_level).debug("api.post_updated", "post_id={s} slug={s} status={s}", .{ existing.id, saved_slug, status });
}

fn readBody(allocator: std.mem.Allocator, request: *std.http.Server.Request) ![]u8 {
    const len64 = request.head.content_length orelse return error.LengthRequired;
    if (len64 > max_body_size) return error.BodyTooLarge;
    const len: usize = @intCast(len64);
    var buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    return try reader.readAlloc(allocator, len);
}

fn respondError(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    try respondJsonValue(allocator, request, status, ErrorResponse{ .@"error" = message });
}

fn respondJsonValue(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    value: anytype,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    try request.respond(out.written(), .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
    });
}

fn tokenAuthorized(head_buffer: []const u8, configured_token: []const u8) bool {
    const expected = std.mem.trim(u8, configured_token, " \t\r\n");
    if (expected.len == 0) return false;
    const header = auth.headerValue(head_buffer, "authorization") orelse return false;
    const prefix = "Bearer ";
    if (header.len <= prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(header[0..prefix.len], prefix)) return false;
    const got = std.mem.trim(u8, header[prefix.len..], " \t\r\n");
    return constantTimeEqual(got, expected);
}

fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var diff: u8 = 0;
    for (left, right) |left_byte, right_byte| {
        diff |= left_byte ^ right_byte;
    }
    return diff == 0;
}

fn validStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "draft") or std.mem.eql(u8, status, "published");
}

fn hasPatchFields(payload: PostPayload) bool {
    return payload.title != null or
        payload.slug != null or
        payload.body != null or
        payload.excerpt != null or
        payload.og_image != null or
        payload.status != null or
        payload.tags != null;
}

test "bearer token authorizes api requests" {
    const request = "POST /api/posts HTTP/1.1\r\nAuthorization: Bearer secret\r\n\r\n";
    try std.testing.expect(tokenAuthorized(request, "secret"));
    try std.testing.expect(!tokenAuthorized(request, "wrong"));
    try std.testing.expect(!tokenAuthorized(request, ""));
}

test "post status accepts only stored values" {
    try std.testing.expect(validStatus("draft"));
    try std.testing.expect(validStatus("published"));
    try std.testing.expect(!validStatus("archived"));
}

test "patch payload requires one writable field" {
    try std.testing.expect(!hasPatchFields(.{}));
    try std.testing.expect(hasPatchFields(.{ .excerpt = "summary" }));
}
