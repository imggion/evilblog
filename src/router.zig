//! HTTP routing and form handling for the app's small public/admin surface.
//!
//! Routes are kept explicit instead of introducing a dispatcher framework; the
//! main readability rule is that each branch should hand off to a named helper
//! once it starts doing real work.
const std = @import("std");

const auth = @import("auth.zig");
const Config = @import("config.zig").Config;
const html = @import("html.zig");
const post = @import("post.zig");
const rss = @import("rss.zig");

// Admin forms are small; reject oversized bodies before allocating request data.
const max_body_size = 128 * 1024;

pub fn handle(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    request: *std.http.Server.Request,
) !void {
    const target_path = pathOnly(request.head.target);
    const store: post.Store = .{ .allocator = allocator, .io = io, .cfg = cfg };
    const viewer = try auth.sessionUsername(allocator, cfg, request.head_buffer);

    const handled = switch (request.head.method) {
        .GET => try handleGet(allocator, cfg, viewer, store, request, target_path),
        .POST => try handlePost(allocator, io, cfg, viewer, store, request, target_path),
        else => false,
    };

    if (!handled) {
        try sendMessage(allocator, cfg, viewer, request, .not_found, "not found", "Not found.");
    }
}

fn handleGet(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
    store: post.Store,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !bool {
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

    if (std.mem.eql(u8, target_path, "/signin")) {
        try sendSignin(allocator, cfg, viewer, request);
        return true;
    }

    if (isAdminPath(target_path)) {
        const username = viewer orelse {
            if (std.mem.eql(u8, target_path, "/admin")) {
                try redirect(request, "/signin");
            } else {
                try sendSigninRequired(allocator, cfg, viewer, request);
            }
            return true;
        };

        if (std.mem.eql(u8, target_path, "/admin")) {
            try sendAdmin(allocator, cfg, username, request);
            return true;
        }
    }

    return false;
}

fn handlePost(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?[]const u8,
    store: post.Store,
    request: *std.http.Server.Request,
    target_path: []const u8,
) !bool {
    if (std.mem.eql(u8, target_path, "/signin")) {
        try handleSignin(allocator, cfg, viewer, request);
        return true;
    }

    if (std.mem.eql(u8, target_path, "/signout")) {
        const cookie = try auth.clearCookie(allocator);
        defer allocator.free(cookie);
        try redirectWithCookie(request, "/", cookie);
        return true;
    }

    if (isAdminPath(target_path)) {
        if (viewer == null) {
            try sendSigninRequired(allocator, cfg, viewer, request);
            return true;
        }
        if (std.mem.eql(u8, target_path, "/admin/post")) {
            try handleAdminPost(allocator, io, cfg, viewer, store, request);
            return true;
        }
        return false;
    }

    return false;
}

fn sendPostList(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
    store: post.Store,
    request: *std.http.Server.Request,
    page: usize,
) !void {
    var posts = store.listPublished(page) catch |err| return sendServiceProblem(allocator, cfg, request, err);
    defer posts.deinit(allocator);
    const body = try html.renderHome(allocator, cfg, viewer, posts.items, page);
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendSinglePost(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
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
        const body = try html.renderSingle(allocator, cfg, viewer, mutable_item);
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
    viewer: ?[]const u8,
    request: *std.http.Server.Request,
) !void {
    if (viewer != null) {
        try redirect(request, "/admin");
        return;
    }
    const body = try html.renderSignin(allocator, cfg, viewer, null);
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendAdmin(
    allocator: std.mem.Allocator,
    cfg: Config,
    username: []const u8,
    request: *std.http.Server.Request,
) !void {
    const body = try html.renderAdmin(allocator, cfg, username);
    defer allocator.free(body);
    try respondHtml(request, .ok, body);
}

fn sendSigninRequired(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
    request: *std.http.Server.Request,
) !void {
    try sendMessage(allocator, cfg, viewer, request, .unauthorized, "unauthorized", "Signin required.");
}

fn handleSignin(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
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

    if (!auth.validCredentials(cfg, form.username orelse "", form.password orelse "")) {
        const page = try html.renderSignin(allocator, cfg, viewer, "Invalid username or password.");
        defer allocator.free(page);
        try respondHtml(request, .unauthorized, page);
        return;
    }

    const cookie = try auth.loginCookie(allocator, cfg);
    defer allocator.free(cookie);
    try redirectWithCookie(request, "/admin", cookie);
}

fn handleAdminPost(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    viewer: ?[]const u8,
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
    }, now) catch |err| switch (err) {
        error.TitleRequired => {
            try sendMessage(allocator, cfg, viewer, request, .bad_request, "bad request", "Title is required.");
            return;
        },
        else => |e| return e,
    };
    defer allocator.free(saved_slug);

    const location = try std.fmt.allocPrint(allocator, "/post/{s}", .{saved_slug});
    defer allocator.free(location);
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
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
    viewer: ?[]const u8,
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
    std.log.err("request failed while handling {s}: {s}", .{ request.head.target, @errorName(err) });
    try sendMessage(allocator, cfg, null, request, .service_unavailable, "service unavailable", "Some error occurred. Please contact the administrator.");
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |index| return target[0..index];
    return target;
}

fn isAdminPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/admin") or std.mem.startsWith(u8, path, "/admin/");
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

test "admin route matching stays in the admin namespace" {
    try std.testing.expect(isAdminPath("/admin"));
    try std.testing.expect(isAdminPath("/admin/post"));
    try std.testing.expect(!isAdminPath("/administrator"));
}
