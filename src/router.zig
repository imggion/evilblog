// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! HTTP routing and form handling for the app's small public/admin surface.
//!
//! Routes are kept explicit instead of introducing a dispatcher framework; the
//! main readability rule is that each branch should hand off to a named helper
//! once it starts doing real work.
const std = @import("std");

const api = @import("api.zig");
const auth = @import("auth.zig");
const comment = @import("comment.zig");
const Config = @import("config.zig").Config;
const html = @import("html.zig");
const Logger = @import("logger.zig").Logger;
const post = @import("post.zig");
const rss = @import("rss.zig");
const user = @import("user.zig");

// Admin forms are small; reject oversized bodies before allocating request data.
const max_body_size = 128 * 1024;
const max_donate_about_readme_size = 128 * 1024;
const max_static_size = 4 * 1024 * 1024;
const static_url_prefix = "/statics/";
const static_dir = "statics";
const public_dir = "public";

pub fn handle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    request: *std.http.Server.Request,
) !void {
    const target_path = pathOnly(request.head.target);
    const log = Logger.init(cfg.log_level);
    log.debug("request.received", "method={s} path={s}", .{ @tagName(request.head.method), target_path });
    const store: post.Store = .{ .allocator = allocator, .io = io, .cfg = cfg };
    const user_store: user.Store = .{ .allocator = allocator, .cfg = cfg };
    var viewer = try auth.sessionViewer(allocator, cfg, user_store, request.head_buffer);
    defer if (viewer) |*current| current.deinit(allocator);

    if (viewerMustChangePassword(viewer, target_path)) {
        try redirect(request, "/account/password");
        return;
    }

    const handled = switch (request.head.method) {
        .GET => try handleGet(allocator, io, cfg, viewer, store, request, target_path),
        .POST => try handlePost(allocator, io, cfg, viewer, store, request, target_path),
        else => false,
    };

    if (!handled) {
        log.debug("request.not_found", "method={s} path={s}", .{ @tagName(request.head.method), target_path });
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Not found.");
    }
}

fn handleGet(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !bool {
    if (isPublicAssetPath(target_path)) {
        try sendPublicAsset(allocator, io, request, target_path);
        return true;
    }

    if (std.mem.startsWith(u8, target_path, static_url_prefix)) {
        try sendStatic(allocator, io, request, target_path);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/")) {
        try sendPostList(allocator, cfg, viewer, store, request, 1);
        return true;
    }

    if (std.mem.startsWith(u8, target_path, "/latest/")) {
        const page_text = target_path["/latest/".len..];
        // Malformed archive URLs degrade to the first page instead of 404ing a
        // public listing route.
        const page = std.fmt.parseInt(usize, page_text, 10) catch 1;
        try sendPostList(allocator, cfg, viewer, store, request, @max(page, 1));
        return true;
    }

    if (std.mem.startsWith(u8, target_path, "/post/")) {
        const slug = target_path["/post/".len..];
        try sendSinglePost(allocator, cfg, viewer, store, request, slug);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/rss")) {
        try sendRss(allocator, cfg, store, request);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/donate")) {
        try sendDonate(allocator, io, cfg, viewer, store, request);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/signin")) {
        try sendSignin(allocator, cfg, viewer, request);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/account/password")) {
        try sendAccountPassword(allocator, cfg, viewer, request, null);
        return true;
    }

    if (isAdminPath(target_path)) {
        const current = viewer orelse {
            if (std.mem.eql(u8, target_path, "/admin")) {
                try redirect(request, "/signin");
            } else {
                try sendSigninRequired(allocator, cfg, viewer, request);
            }
            return true;
        };
        if (!auth.isAdmin(current)) {
            try sendAdminRequired(allocator, cfg, viewer, request);
            return true;
        }

        if (std.mem.eql(u8, target_path, "/admin")) {
            try sendAdmin(allocator, cfg, current, store, request);
            return true;
        }

        if (std.mem.eql(u8, target_path, "/admin/drafts")) {
            try sendAdminDrafts(allocator, cfg, current, store, request);
            return true;
        }

        if (std.mem.startsWith(u8, target_path, "/admin/draft/")) {
            const id = target_path["/admin/draft/".len..];
            try sendAdminDraft(allocator, cfg, current, store, request, id);
            return true;
        }

        if (adminPostActionId(target_path, "/edit")) |id| {
            try sendAdminPostEdit(allocator, cfg, current, store, request, id);
            return true;
        }
    }

    return false;
}

fn sendPublicAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !void {
    try sendStaticFile(allocator, io, request, public_dir, target_path[1..]);
}

fn sendStatic(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !void {
    const relative_path = target_path[static_url_prefix.len..];
    if (!validStaticPath(relative_path)) {
        try request.respond("Not found.", .{
            .status = .not_found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        return;
    }

    try sendStaticFile(allocator, io, request, static_dir, relative_path);
}

fn sendStaticFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    directory: []const u8,
    relative_path: []const u8,
) !void {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, relative_path });
    defer allocator.free(file_path);

    const body = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(max_static_size),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("Not found.", .{
                .status = .not_found,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            });
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(body);

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = contentTypeForPath(relative_path) },
        .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
    };
    try request.respond(body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn isPublicAssetPath(path: []const u8) bool {
    const public_assets = [_][]const u8{
        "/android-chrome-192x192.png",
        "/android-chrome-512x512.png",
        "/apple-touch-icon.png",
        "/favicon-16x16.png",
        "/favicon-32x32.png",
        "/favicon.ico",
        "/site.webmanifest",
    };
    for (public_assets) |asset_path| {
        if (std.mem.eql(u8, path, asset_path)) return true;
    }
    return false;
}

fn validStaticPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".webmanifest")) return "application/manifest+json";
    return "application/octet-stream";
}

fn handlePost(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !bool {
    if (std.mem.eql(u8, target_path, "/api/posts")) {
        if (!cfg.api_gateway_enabled) return false;
        try api.handleCreatePost(allocator, cfg, store, request);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/signin")) {
        try handleSignin(allocator, io, cfg, viewer, request);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/account/password")) {
        try handleAccountPassword(allocator, io, cfg, viewer, request);
        return true;
    }

    if (std.mem.startsWith(u8, target_path, "/post/") and std.mem.endsWith(u8, target_path, "/upvote")) {
        try handlePostUpvote(allocator, io, cfg, viewer, store, request, target_path);
        return true;
    }

    if (std.mem.startsWith(u8, target_path, "/post/") and std.mem.endsWith(u8, target_path, "/comment")) {
        try handlePostComment(allocator, io, cfg, viewer, request, target_path);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/signout")) {
        const cookie = try auth.clearCookie(allocator);
        defer allocator.free(cookie);
        try redirectWithCookie(request, "/", cookie);
        return true;
    }

    if (isAdminPath(target_path)) {
        const current = viewer orelse {
            try sendSigninRequired(allocator, cfg, viewer, request);
            return true;
        };
        if (!auth.isAdmin(current)) {
            try sendAdminRequired(allocator, cfg, viewer, request);
            return true;
        }

        if (adminCommentActionId(target_path, "/delete")) |id| {
            try handleAdminCommentDelete(allocator, cfg, current, request, id);
            return true;
        }

        if (adminPostActionId(target_path, "/delete")) |id| {
            try handleAdminPostDelete(allocator, cfg, current, store, request, id);
            return true;
        }

        if (std.mem.eql(u8, target_path, "/admin/post")) {
            try handleAdminPost(allocator, io, cfg, current, store, request);
            return true;
        }
        return false;
    }

    return false;
}

fn handlePostUpvote(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !void {
    const current = viewer orelse {
        try redirect(request, "/signin");
        return;
    };

    const slug_start = "/post/".len;
    const slug_end = target_path.len - "/upvote".len;
    if (slug_end <= slug_start) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
        return;
    }

    const slug = target_path[slug_start..slug_end];
    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    store.upvoteBySlug(slug, current.username, now) catch |err| switch (err) {
        error.PostNotFound => {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    Logger.init(cfg.log_level).debug("post.upvoted", "slug={s}", .{slug});

    const location = try std.fmt.allocPrint(allocator, "/post/{s}", .{slug});
    defer allocator.free(location);
    try redirect(request, location);
}

fn handlePostComment(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !void {
    const slug_start = "/post/".len;
    const slug_end = target_path.len - "/comment".len;
    if (slug_end <= slug_start) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
        return;
    }
    const slug = target_path[slug_start..slug_end];

    const body = readBody(allocator, request) catch |err| switch (err) {
        error.LengthRequired => {
            try sendMessage(allocator, cfg, viewer, request, .length_required, "length required", "POST comment requires a Content-Length header.");
            return;
        },
        error.BodyTooLarge => {
            try sendMessage(allocator, cfg, viewer, request, .payload_too_large, "payload too large", "Comment bodies are limited to 128 KiB.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    defer allocator.free(body);

    var form = try parseCommentForm(allocator, body);
    defer form.deinit(allocator);

    const comment_store: comment.Store = .{ .allocator = allocator, .cfg = cfg };
    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    comment_store.addByPostSlug(slug, form.parent_id, form.author orelse "", form.body orelse "", now) catch |err| switch (err) {
        error.PostNotFound => {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
            return;
        },
        error.AuthorRequired => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Name is required.");
            return;
        },
        error.CommentRequired => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Comment is required.");
            return;
        },
        error.AuthorTooLong => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Name is too long.");
            return;
        },
        error.CommentTooLong => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Comment is too long.");
            return;
        },
        error.InvalidId, error.CommentParentNotFound => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Reply target was not found.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    Logger.init(cfg.log_level).debug("comment.created", "slug={s}", .{slug});

    const location = try std.fmt.allocPrint(allocator, "/post/{s}#comments", .{slug});
    defer allocator.free(location);
    try redirect(request, location);
}

fn sendPostList(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    page: usize,
) !void {
    var posts = store.listPublished(page) catch |err| return sendServiceProblem(allocator, cfg, request, err);
    defer posts.deinit(allocator);
    const draft_count = draftCountForViewer(store, viewer) catch |err| return sendServiceProblem(allocator, cfg, request, err);
    const now = std.Io.Clock.Timestamp.now(store.io, .real).raw.toSeconds();
    const body = try html.renderHome(allocator, cfg, viewer, posts.items, page, now, draft_count);
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendSinglePost(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    slug: []const u8,
) !void {
    if (slug.len == 0) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
        return;
    }
    if (store.readBySlug(slug) catch |err| return sendServiceProblem(allocator, cfg, request, err)) |item| {
        var mutable_item = item;
        defer mutable_item.deinit(allocator);
        const comment_store: comment.Store = .{ .allocator = allocator, .cfg = cfg };
        var comments = comment_store.listForPostId(mutable_item.id) catch |err| return sendServiceProblem(allocator, cfg, request, err);
        defer comments.deinit(allocator);
        const draft_count = draftCountForViewer(store, viewer) catch |err| return sendServiceProblem(allocator, cfg, request, err);
        const now = std.Io.Clock.Timestamp.now(store.io, .real).raw.toSeconds();
        const body = try html.renderSingle(allocator, cfg, viewer, mutable_item, comments.items, now, draft_count);
        defer allocator.free(body);
        try respondHtml(request, .ok, body);
    } else {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
    }
}

fn sendRss(
    allocator: std.mem.Allocator,
    cfg: Config,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    var posts = store.listPublished(1) catch |err| return sendServiceProblem(allocator, cfg, request, err);
    defer posts.deinit(allocator);
    const body = try rss.render(allocator, cfg, posts.items);
    defer allocator.free(body);
    try request.respond(body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/rss+xml; charset=utf-8" }},
    });
}

fn sendSignin(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
) !void {
    if (viewer) |current| {
        if (current.must_change_password) {
            try redirect(request, "/account/password");
            return;
        }
        try redirect(request, if (auth.isAdmin(current)) "/admin" else "/");
        return;
    }
    const body = try html.renderSignin(allocator, cfg, viewer, null);
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendAccountPassword(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
    error_message: ?[]const u8,
) !void {
    if (viewer == null) {
        try redirect(request, "/signin");
        return;
    }
    const body = try html.renderPasswordChange(allocator, cfg, viewer, error_message);
    defer allocator.free(body);
    try respondHtml(request, if (error_message == null) .ok else .bad_request, body);
}

fn sendDonate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    const draft_count = draftCountForViewer(store, viewer) catch |err| return sendServiceProblem(allocator, cfg, request, err);
    const about_markdown = fetchDonateAboutReadme(allocator, io, cfg.donate_about_readme_url) catch |err| about: {
        Logger.init(cfg.log_level).debug("donate.about_fetch_failed", "error={s}", .{@errorName(err)});
        break :about null;
    };
    defer if (about_markdown) |markdown_source| allocator.free(markdown_source);

    const body = try html.renderDonate(allocator, cfg, viewer, draft_count, about_markdown orelse "");
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn fetchDonateAboutReadme(allocator: std.mem.Allocator, io: std.Io, raw_url: []const u8) !?[]u8 {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return null;
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return null;

    var buffer: [max_donate_about_readme_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "user-agent", .value = "evilblog" }},
    });
    if (result.status != .ok) return null;
    return try allocator.dupe(u8, writer.buffered());
}

fn sendAdmin(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    const draft_count = store.countDrafts() catch |err| return sendServiceProblem(allocator, cfg, request, err);
    const body = try html.renderAdmin(allocator, cfg, viewer, .{ .draft_count = draft_count });
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendAdminDrafts(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    var drafts = store.listDrafts() catch |err| return sendServiceProblem(allocator, cfg, request, err);
    defer drafts.deinit(allocator);

    const body = try html.renderAdmin(allocator, cfg, viewer, .{
        .draft_count = drafts.items.len,
        .drafts = drafts.items,
        .show_drafts = true,
    });
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendAdminDraft(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    id: []const u8,
) !void {
    if (id.len == 0) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Draft not found.");
        return;
    }

    if (store.readById(id) catch |err| return sendServiceProblem(allocator, cfg, request, err)) |item| {
        var draft = item;
        defer draft.deinit(allocator);
        if (!std.mem.eql(u8, draft.status, "draft")) {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Draft not found.");
            return;
        }

        const draft_count = store.countDrafts() catch |err| return sendServiceProblem(allocator, cfg, request, err);
        const body = try html.renderAdmin(allocator, cfg, viewer, .{
            .draft_count = draft_count,
            .selected = &draft,
        });
        defer allocator.free(body);
        try respondHtml(request, .ok, body);
    } else {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Draft not found.");
    }
}

fn sendAdminPostEdit(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    id: []const u8,
) !void {
    if (id.len == 0) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
        return;
    }

    if (store.readByIdFresh(id) catch |err| return sendServiceProblem(allocator, cfg, request, err)) |item| {
        var selected = item;
        defer selected.deinit(allocator);
        if (!viewerOwnsPost(viewer.username, selected)) {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
            return;
        }

        const draft_count = store.countDrafts() catch |err| return sendServiceProblem(allocator, cfg, request, err);
        const body = try html.renderAdmin(allocator, cfg, viewer, .{
            .draft_count = draft_count,
            .selected = &selected,
        });
        defer allocator.free(body);
        try respondHtml(request, .ok, body);
    } else {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
    }
}

fn draftCountForViewer(store: post.Store, viewer: ?auth.Viewer) !usize {
    if (viewer == null or !auth.isAdmin(viewer.?)) return 0;
    return try store.countDrafts();
}

fn viewerMustChangePassword(viewer: ?auth.Viewer, target_path: []const u8) bool {
    const current = viewer orelse return false;
    if (!current.must_change_password) return false;
    if (std.mem.eql(u8, target_path, "/account/password")) return false;
    if (std.mem.eql(u8, target_path, "/signout")) return false;
    if (std.mem.eql(u8, target_path, "/signin")) return false;
    if (std.mem.startsWith(u8, target_path, "/api/")) return false;
    if (isPublicAssetPath(target_path)) return false;
    if (std.mem.startsWith(u8, target_path, static_url_prefix)) return false;
    return true;
}

fn sendSigninRequired(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
) !void {
    try sendMessage(allocator, cfg, viewer, request, .unauthorized, "unauthorized", "Signin required.");
}

fn sendAdminRequired(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
) !void {
    try sendMessage(allocator, cfg, viewer, request, .unauthorized, "unauthorized", "Admin required.");
}

fn handleSignin(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
) !void {
    const body = readBody(allocator, request) catch |err| switch (err) {
        error.LengthRequired => {
            try sendMessage(allocator, cfg, viewer, request, .length_required, "length required", "POST /signin requires a Content-Length header.");
            return;
        },
        error.BodyTooLarge => {
            try sendMessage(allocator, cfg, viewer, request, .payload_too_large, "payload too large", "Signin bodies are limited to 128 KiB.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    defer allocator.free(body);

    var form = try parseSigninForm(allocator, body);
    defer form.deinit(allocator);

    const user_store: user.Store = .{ .allocator = allocator, .cfg = cfg };
    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    var login = (try auth.authenticate(allocator, user_store, form.username orelse "", form.password orelse "", now, io)) orelse {
        const page = try html.renderSignin(allocator, cfg, viewer, "Invalid username or password.");
        defer allocator.free(page);
        try respondHtml(request, .unauthorized, page);
        return;
    };
    defer login.deinit(allocator);

    const cookie = try auth.loginCookie(allocator, cfg, login.username);
    defer allocator.free(cookie);
    const location = if (login.must_change_password) "/account/password" else if (auth.isAdmin(login)) "/admin" else "/";
    try redirectWithCookie(request, location, cookie);
}

fn handleAccountPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
) !void {
    const current = viewer orelse {
        try redirect(request, "/signin");
        return;
    };

    const body = readBody(allocator, request) catch |err| switch (err) {
        error.LengthRequired => {
            try sendMessage(allocator, cfg, viewer, request, .length_required, "length required", "POST /account/password requires a Content-Length header.");
            return;
        },
        error.BodyTooLarge => {
            try sendMessage(allocator, cfg, viewer, request, .payload_too_large, "payload too large", "Password bodies are limited to 128 KiB.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    defer allocator.free(body);

    var form = try parsePasswordForm(allocator, body);
    defer form.deinit(allocator);

    const current_password = form.current_password orelse "";
    const new_password = form.new_password orelse "";
    const confirm_password = form.confirm_password orelse "";
    if (!std.mem.eql(u8, new_password, confirm_password)) {
        try sendAccountPassword(allocator, cfg, viewer, request, "New passwords do not match.");
        return;
    }

    const user_store: user.Store = .{ .allocator = allocator, .cfg = cfg };
    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    user_store.changePassword(current.username, current_password, new_password, now, io) catch |err| switch (err) {
        error.CurrentPasswordInvalid => {
            try sendAccountPassword(allocator, cfg, viewer, request, "Current password is invalid.");
            return;
        },
        error.NewPasswordTooShort => {
            try sendAccountPassword(allocator, cfg, viewer, request, "New password must be at least 12 characters.");
            return;
        },
        error.NewPasswordTooLong => {
            try sendAccountPassword(allocator, cfg, viewer, request, "New password is too long.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };

    try redirect(request, if (auth.isAdmin(current)) "/admin" else "/");
}

fn handleAdminPost(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
) !void {
    const body = readBody(allocator, request) catch |err| switch (err) {
        error.LengthRequired => {
            try sendMessage(allocator, cfg, viewer, request, .length_required, "length required", "POST /admin/post requires a Content-Length header.");
            return;
        },
        error.BodyTooLarge => {
            try sendMessage(allocator, cfg, viewer, request, .payload_too_large, "payload too large", "Post bodies are limited to 128 KiB.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    defer allocator.free(body);

    var form = try parsePostForm(allocator, body);
    defer form.deinit(allocator);

    if (trimmedFormId(form.id)) |id| {
        if (!(try viewerOwnsPostId(store, id, viewer.username))) {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
            return;
        }
    }

    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    const saved_slug = store.save(.{
        .id = form.id,
        .title = form.title orelse "",
        .slug = form.slug,
        .body = form.body orelse "",
        .excerpt = form.excerpt orelse "",
        .og_image = form.og_image orelse "",
        .status = form.status orelse "published",
        .tags = form.tags orelse "",
        .author = viewer.username,
    }, now) catch |err| switch (err) {
        error.TitleRequired => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Title is required.");
            return;
        },
        error.InvalidId => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Post id must be a positive integer.");
            return;
        },
        error.SlugTaken => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Slug is already used by another post.");
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(saved_slug);
    Logger.init(cfg.log_level).debug("admin.post_saved", "slug={s} has_existing_id={}", .{ saved_slug, trimmedFormId(form.id) != null });

    const location = try std.fmt.allocPrint(allocator, "/post/{s}", .{saved_slug});
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

fn handleAdminPostDelete(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: auth.Viewer,
    store: post.Store,
    request: *std.http.Server.Request,
    id: []const u8,
) !void {
    if (id.len == 0) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
        return;
    }

    store.deleteByIdForAuthor(id, viewer.username) catch |err| switch (err) {
        error.PostNotFound => {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Post not found.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    Logger.init(cfg.log_level).debug("admin.post_deleted", "post_id={s}", .{id});
    try redirect(request, "/");
}

fn handleAdminCommentDelete(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: auth.Viewer,
    request: *std.http.Server.Request,
    id: []const u8,
) !void {
    if (id.len == 0) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Comment not found.");
        return;
    }

    const comment_store: comment.Store = .{ .allocator = allocator, .cfg = cfg };
    const slug = comment_store.deleteByIdForAdmin(id) catch |err| switch (err) {
        error.InvalidId => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Comment id must be a positive integer.");
            return;
        },
        error.CommentNotFound => {
            try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Comment not found.");
            return;
        },
        else => |e| return sendServiceProblem(allocator, cfg, request, e),
    };
    defer allocator.free(slug);
    Logger.init(cfg.log_level).debug("admin.comment_deleted", "comment_id={s}", .{id});

    const location = try std.fmt.allocPrint(allocator, "/post/{s}#comments", .{slug});
    defer allocator.free(location);
    try redirect(request, location);
}

fn readBody(allocator: std.mem.Allocator, request: *std.http.Server.Request) ![]u8 {
    // Browser form posts should declare their size; requiring Content-Length
    // makes the allocation bound explicit and enforceable.
    const len64 = request.head.content_length orelse return error.LengthRequired;
    if (len64 > max_body_size) return error.BodyTooLarge;
    const len: usize = @intCast(len64);
    var buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    return try reader.readAlloc(allocator, len);
}

fn respondHtml(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn redirect(request: *std.http.Server.Request, location: []const u8) !void {
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

fn redirectWithCookie(request: *std.http.Server.Request, location: []const u8, cookie: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "location", .value = location },
        .{ .name = "set-cookie", .value = cookie },
    };
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn sendMessage(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    request: *std.http.Server.Request,
    status: std.http.Status,
    title: []const u8,
    message: []const u8,
) !void {
    const body = try html.renderMessage(allocator, cfg, viewer, title, message);
    defer allocator.free(body);
    try respondHtml(request, status, body);
}

fn sendServiceProblem(
    allocator: std.mem.Allocator,
    cfg: Config,
    request: *std.http.Server.Request,
    err: anyerror,
) !void {
    Logger.init(cfg.log_level).err("request.service_problem", "path={s} error={s}", .{ pathOnly(request.head.target), @errorName(err) });
    try sendMessage(allocator, cfg, null, request, .service_unavailable, "service unavailable", "Some error occurred. Please contact the administrator.");
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |index| return target[0..index];
    return target;
}

fn isAdminPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/admin") or std.mem.startsWith(u8, path, "/admin/");
}

fn adminPostActionId(path: []const u8, suffix: []const u8) ?[]const u8 {
    const prefix = "/admin/post/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (!std.mem.endsWith(u8, path, suffix)) return null;

    const id_end = path.len - suffix.len;
    if (id_end <= prefix.len) return null;
    return path[prefix.len..id_end];
}

fn adminCommentActionId(path: []const u8, suffix: []const u8) ?[]const u8 {
    const prefix = "/admin/comment/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (!std.mem.endsWith(u8, path, suffix)) return null;

    const id_end = path.len - suffix.len;
    if (id_end <= prefix.len) return null;
    return path[prefix.len..id_end];
}

fn viewerOwnsPostId(store: post.Store, id: []const u8, username: []const u8) !bool {
    if (try store.readByIdFresh(id)) |item| {
        var owned = item;
        defer owned.deinit(store.allocator);
        return viewerOwnsPost(username, owned);
    }
    return false;
}

fn viewerOwnsPost(username: []const u8, item: post.Post) bool {
    return item.author.len > 0 and std.mem.eql(u8, username, item.author);
}

fn trimmedFormId(id: ?[]const u8) ?[]const u8 {
    const raw = id orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

const PostForm = struct {
    id: ?[]u8 = null,
    title: ?[]u8 = null,
    slug: ?[]u8 = null,
    body: ?[]u8 = null,
    excerpt: ?[]u8 = null,
    og_image: ?[]u8 = null,
    status: ?[]u8 = null,
    tags: ?[]u8 = null,

    fn deinit(self: *PostForm, allocator: std.mem.Allocator) void {
        if (self.id) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        if (self.slug) |value| allocator.free(value);
        if (self.body) |value| allocator.free(value);
        if (self.excerpt) |value| allocator.free(value);
        if (self.og_image) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        if (self.tags) |value| allocator.free(value);
    }
};

const SigninForm = struct {
    username: ?[]u8 = null,
    password: ?[]u8 = null,

    fn deinit(self: *SigninForm, allocator: std.mem.Allocator) void {
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

const CommentForm = struct {
    parent_id: ?[]u8 = null,
    author: ?[]u8 = null,
    body: ?[]u8 = null,

    fn deinit(self: *CommentForm, allocator: std.mem.Allocator) void {
        if (self.parent_id) |value| allocator.free(value);
        if (self.author) |value| allocator.free(value);
        if (self.body) |value| allocator.free(value);
    }
};

const PasswordForm = struct {
    current_password: ?[]u8 = null,
    new_password: ?[]u8 = null,
    confirm_password: ?[]u8 = null,

    fn deinit(self: *PasswordForm, allocator: std.mem.Allocator) void {
        if (self.current_password) |value| allocator.free(value);
        if (self.new_password) |value| allocator.free(value);
        if (self.confirm_password) |value| allocator.free(value);
    }
};

// Form parsers retain only route-owned fields so templates can evolve without
// widening the data each route consumes.
fn parseSigninForm(allocator: std.mem.Allocator, body: []const u8) !SigninForm {
    var form: SigninForm = .{};
    errdefer form.deinit(allocator);

    var fields = std.mem.splitScalar(u8, body, '&');
    while (try nextFormField(allocator, &fields)) |field| {
        defer allocator.free(field.name);
        if (!putSigninField(allocator, &form, field.name, field.value)) {
            allocator.free(field.value);
        }
    }
    return form;
}

fn parsePostForm(allocator: std.mem.Allocator, body: []const u8) !PostForm {
    var form: PostForm = .{};
    errdefer form.deinit(allocator);

    var fields = std.mem.splitScalar(u8, body, '&');
    while (try nextFormField(allocator, &fields)) |field| {
        defer allocator.free(field.name);
        if (!putPostField(allocator, &form, field.name, field.value)) {
            allocator.free(field.value);
        }
    }
    return form;
}

fn parseCommentForm(allocator: std.mem.Allocator, body: []const u8) !CommentForm {
    var form: CommentForm = .{};
    errdefer form.deinit(allocator);

    var fields = std.mem.splitScalar(u8, body, '&');
    while (try nextFormField(allocator, &fields)) |field| {
        defer allocator.free(field.name);
        if (!putCommentField(allocator, &form, field.name, field.value)) {
            allocator.free(field.value);
        }
    }
    return form;
}

fn parsePasswordForm(allocator: std.mem.Allocator, body: []const u8) !PasswordForm {
    var form: PasswordForm = .{};
    errdefer form.deinit(allocator);

    var fields = std.mem.splitScalar(u8, body, '&');
    while (try nextFormField(allocator, &fields)) |field| {
        defer allocator.free(field.name);
        if (!putPasswordField(allocator, &form, field.name, field.value)) {
            allocator.free(field.value);
        }
    }
    return form;
}

const FormField = struct {
    name: []u8,
    value: []u8,
};

fn nextFormField(
    allocator: std.mem.Allocator,
    fields: *std.mem.SplitIterator(u8, .scalar),
) !?FormField {
    while (fields.next()) |raw_field| {
        if (raw_field.len == 0) continue;

        const equals = std.mem.findScalar(u8, raw_field, '=') orelse raw_field.len;
        const raw_value = if (equals < raw_field.len) raw_field[equals + 1 ..] else "";
        const name = try decodeFormComponent(allocator, raw_field[0..equals]);
        errdefer allocator.free(name);
        const value = try decodeFormComponent(allocator, raw_value);
        return .{
            .name = name,
            .value = value,
        };
    }
    return null;
}

fn putSigninField(allocator: std.mem.Allocator, form: *SigninForm, name: []const u8, value: []u8) bool {
    if (std.mem.eql(u8, name, "username")) {
        replaceField(allocator, &form.username, value);
        return true;
    }
    if (std.mem.eql(u8, name, "password")) {
        replaceField(allocator, &form.password, value);
        return true;
    }
    return false;
}

fn putPostField(allocator: std.mem.Allocator, form: *PostForm, name: []const u8, value: []u8) bool {
    if (std.mem.eql(u8, name, "id")) {
        replaceField(allocator, &form.id, value);
        return true;
    }
    if (std.mem.eql(u8, name, "title")) {
        replaceField(allocator, &form.title, value);
        return true;
    }
    if (std.mem.eql(u8, name, "slug")) {
        replaceField(allocator, &form.slug, value);
        return true;
    }
    if (std.mem.eql(u8, name, "body")) {
        replaceField(allocator, &form.body, value);
        return true;
    }
    if (std.mem.eql(u8, name, "excerpt")) {
        replaceField(allocator, &form.excerpt, value);
        return true;
    }
    if (std.mem.eql(u8, name, "og_image")) {
        replaceField(allocator, &form.og_image, value);
        return true;
    }
    if (std.mem.eql(u8, name, "status")) {
        replaceField(allocator, &form.status, value);
        return true;
    }
    if (std.mem.eql(u8, name, "tags")) {
        replaceField(allocator, &form.tags, value);
        return true;
    }
    return false;
}

fn putCommentField(allocator: std.mem.Allocator, form: *CommentForm, name: []const u8, value: []u8) bool {
    if (std.mem.eql(u8, name, "parent_id")) {
        replaceField(allocator, &form.parent_id, value);
        return true;
    }
    if (std.mem.eql(u8, name, "author")) {
        replaceField(allocator, &form.author, value);
        return true;
    }
    if (std.mem.eql(u8, name, "body")) {
        replaceField(allocator, &form.body, value);
        return true;
    }
    return false;
}

fn putPasswordField(allocator: std.mem.Allocator, form: *PasswordForm, name: []const u8, value: []u8) bool {
    if (std.mem.eql(u8, name, "current_password")) {
        replaceField(allocator, &form.current_password, value);
        return true;
    }
    if (std.mem.eql(u8, name, "new_password")) {
        replaceField(allocator, &form.new_password, value);
        return true;
    }
    if (std.mem.eql(u8, name, "confirm_password")) {
        replaceField(allocator, &form.confirm_password, value);
        return true;
    }
    return false;
}

fn replaceField(allocator: std.mem.Allocator, slot: *?[]u8, value: []u8) void {
    if (slot.*) |old| allocator.free(old);
    slot.* = value;
}

fn decodeFormComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        switch (raw[i]) {
            '+' => {
                try out.append(allocator, ' ');
                i += 1;
            },
            '%' => {
                if (i + 2 < raw.len) {
                    const byte: ?u8 = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch null;
                    if (byte) |decoded| {
                        try out.append(allocator, decoded);
                        i += 3;
                        continue;
                    }
                }
                // Preserve malformed escapes literally rather than rejecting an
                // otherwise valid admin post.
                try out.append(allocator, raw[i]);
                i += 1;
            },
            else => |byte| {
                try out.append(allocator, byte);
                i += 1;
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "form decoding handles plus and percent escapes" {
    const decoded = try decodeFormComponent(std.testing.allocator, "hello+zig%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello zig!", decoded);
}

test "signin form parser keeps recognized fields" {
    var form = try parseSigninForm(std.testing.allocator, "ignored=x&username=admin&password=hello+zig");
    defer form.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("admin", form.username.?);
    try std.testing.expectEqualStrings("hello zig", form.password.?);
}

test "comment form parser keeps recognized fields" {
    var form = try parseCommentForm(std.testing.allocator, "ignored=x&parent_id=42&author=Alice+Bob&body=hello%0Aworld");
    defer form.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("42", form.parent_id.?);
    try std.testing.expectEqualStrings("Alice Bob", form.author.?);
    try std.testing.expectEqualStrings("hello\nworld", form.body.?);
}

test "password form parser keeps recognized fields" {
    var form = try parsePasswordForm(std.testing.allocator, "current_password=old&new_password=new+secret&confirm_password=new+secret");
    defer form.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("old", form.current_password.?);
    try std.testing.expectEqualStrings("new secret", form.new_password.?);
    try std.testing.expectEqualStrings("new secret", form.confirm_password.?);
}

test "admin route matching stays in the admin namespace" {
    try std.testing.expect(isAdminPath("/admin"));
    try std.testing.expect(isAdminPath("/admin/post"));
    try std.testing.expect(!isAdminPath("/administrator"));
    try std.testing.expectEqualStrings("42", adminPostActionId("/admin/post/42/edit", "/edit").?);
    try std.testing.expectEqualStrings("42", adminPostActionId("/admin/post/42/delete", "/delete").?);
    try std.testing.expectEqualStrings("42", adminCommentActionId("/admin/comment/42/delete", "/delete").?);
    try std.testing.expect(adminPostActionId("/admin/post//edit", "/edit") == null);
    try std.testing.expect(adminPostActionId("/admin/post/42", "/edit") == null);
    try std.testing.expect(adminPostActionId("/admin/draft/42/edit", "/edit") == null);
    try std.testing.expect(adminCommentActionId("/admin/comment//delete", "/delete") == null);
    try std.testing.expect(adminCommentActionId("/admin/post/42/delete", "/delete") == null);
}

test "admin route helpers require admin role" {
    try std.testing.expect(auth.isAdmin(.{ .username = @constCast("admin"), .role = .admin, .must_change_password = false }));
    try std.testing.expect(!auth.isAdmin(.{ .username = @constCast("member"), .role = .member, .must_change_password = false }));
}

test "forced password change allows only password and signout routes" {
    const viewer: auth.Viewer = .{ .username = @constCast("admin"), .role = .admin, .must_change_password = true };
    try std.testing.expect(viewerMustChangePassword(viewer, "/admin"));
    try std.testing.expect(!viewerMustChangePassword(viewer, "/account/password"));
    try std.testing.expect(!viewerMustChangePassword(viewer, "/signout"));
    try std.testing.expect(!viewerMustChangePassword(viewer, "/favicon.ico"));
    const ready: auth.Viewer = .{ .username = @constCast("admin"), .role = .admin, .must_change_password = false };
    try std.testing.expect(!viewerMustChangePassword(ready, "/admin"));
}

test "public favicon assets are whitelisted with web content types" {
    try std.testing.expect(isPublicAssetPath("/favicon.ico"));
    try std.testing.expect(isPublicAssetPath("/site.webmanifest"));
    try std.testing.expect(!isPublicAssetPath("/evilblog.sqlite3"));
    try std.testing.expectEqualStrings("image/x-icon", contentTypeForPath("favicon.ico"));
    try std.testing.expectEqualStrings("application/manifest+json", contentTypeForPath("site.webmanifest"));
}
