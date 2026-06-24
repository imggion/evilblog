//! Server-side HTML renderer for the blog UI.
//!
//! Static markup lives in embedded template files; this module keeps the
//! dynamic parts in Zig so loops, conditionals, and escaping stay explicit.
const std = @import("std");
const Config = @import("config.zig").Config;
const post = @import("post.zig");
const template = @import("template.zig");

const Writer = std.Io.Writer;

const templates = struct {
    const layout_start = @embedFile("templates/layout_start.html");
    const footer = @embedFile("templates/footer.html");
    const header_guest = @embedFile("templates/header_guest.html");
    const header_user = @embedFile("templates/header_user.html");
    const og_image_meta = @embedFile("templates/og_image_meta.html");
    const robots_meta = @embedFile("templates/robots_meta.html");
    const admin_form = @embedFile("templates/admin_form.html");
    const signin_form = @embedFile("templates/signin_form.html");
    const signin_error = @embedFile("templates/signin_error.html");
    const message = @embedFile("templates/message.html");
    const post_list_empty = @embedFile("templates/post_list_empty.html");
    const post_list_item = @embedFile("templates/post_list_item.html");
    const post_full = @embedFile("templates/post_full.html");
    const page_css = @embedFile("templates/page.css");
    const theme_boot_js = @embedFile("templates/theme_boot.js");
    const theme_choice_js = @embedFile("templates/theme_choice.js");
};

const Meta = struct {
    title: []const u8,
    social_title: []const u8 = "",
    description: []const u8,
    canonical_url: []const u8,
    og_type: []const u8 = "website",
    og_image: []const u8 = "",
    noindex: bool = false,
};

pub fn renderHome(allocator: std.mem.Allocator, cfg: Config, viewer: ?[]const u8, posts: []const post.Post, page: usize) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const page_title = if (page == 1)
        try allocator.dupe(u8, cfg.site_title)
    else
        try std.fmt.allocPrint(allocator, "{s} - page {d}", .{ cfg.site_title, page });
    defer allocator.free(page_title);

    const canonical_path = if (page == 1)
        try allocator.dupe(u8, "/")
    else
        try std.fmt.allocPrint(allocator, "/latest/{d}", .{page});
    defer allocator.free(canonical_path);

    const canonical_url = try absoluteUrl(allocator, cfg, canonical_path);
    defer allocator.free(canonical_url);
    const og_image = try imageUrl(allocator, cfg, cfg.site_default_og_image);
    defer allocator.free(og_image);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = page_title,
        .social_title = cfg.site_title,
        .description = cfg.site_description,
        .canonical_url = canonical_url,
        .og_image = og_image,
    });
    try renderPostList(allocator, &out.writer, posts, (page - 1) * post.per_page + 1);
    try renderPager(&out.writer, page);
    try endPage(&out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderSingle(allocator: std.mem.Allocator, cfg: Config, viewer: ?[]const u8, item: post.Post) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const page_title = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ item.title, cfg.site_title });
    defer allocator.free(page_title);

    // Explicit excerpts win, but deriving one keeps older posts useful in
    // search and social previews without requiring another admin field.
    const description = if (item.excerpt.len > 0)
        try allocator.dupe(u8, item.excerpt)
    else
        try excerptFromBody(allocator, item.body, item.title);
    defer allocator.free(description);

    const canonical_path = try std.fmt.allocPrint(allocator, "/post/{s}", .{item.slug});
    defer allocator.free(canonical_path);
    const canonical_url = try absoluteUrl(allocator, cfg, canonical_path);
    defer allocator.free(canonical_url);

    const raw_og_image = if (item.og_image.len > 0) item.og_image else cfg.site_default_og_image;
    const og_image = try imageUrl(allocator, cfg, raw_og_image);
    defer allocator.free(og_image);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = page_title,
        .social_title = item.title,
        .description = description,
        .canonical_url = canonical_url,
        .og_type = "article",
        .og_image = og_image,
    });
    try renderPostFull(allocator, &out.writer, item);
    try endPage(&out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderAdmin(allocator: std.mem.Allocator, cfg: Config, viewer: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const canonical_url = try absoluteUrl(allocator, cfg, "/admin");
    defer allocator.free(canonical_url);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = "admin",
        .social_title = "admin",
        .description = "Administration page.",
        .canonical_url = canonical_url,
        .noindex = true,
    });
    try template.render(&out.writer, templates.admin_form, &.{});
    try endPage(&out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderSignin(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
    error_message: ?[]const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const canonical_url = try absoluteUrl(allocator, cfg, "/signin");
    defer allocator.free(canonical_url);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = "signin",
        .social_title = "signin",
        .description = "Sign in.",
        .canonical_url = canonical_url,
        .noindex = true,
    });
    if (error_message) |message| {
        try template.render(&out.writer, templates.signin_error, &.{
            .{ .name = "message", .value = message },
        });
    }
    try template.render(&out.writer, templates.signin_form, &.{});
    try endPage(&out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderMessage(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?[]const u8,
    title: []const u8,
    message: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const canonical_url = try absoluteUrl(allocator, cfg, "/");
    defer allocator.free(canonical_url);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = title,
        .social_title = title,
        .description = message,
        .canonical_url = canonical_url,
        .noindex = true,
    });
    try template.render(&out.writer, templates.message, &.{
        .{ .name = "message", .value = message },
    });
    try endPage(&out.writer, cfg);
    return try out.toOwnedSlice();
}

fn beginPage(
    allocator: std.mem.Allocator,
    writer: *Writer,
    cfg: Config,
    viewer: ?[]const u8,
    meta: Meta,
) !void {
    const social_title = if (meta.social_title.len > 0) meta.social_title else meta.title;

    const header_actions = try headerActions(allocator, viewer);
    defer allocator.free(header_actions);

    const og_image_meta = try optionalOgImageMeta(allocator, meta.og_image);
    defer allocator.free(og_image_meta);

    // Admin and signin pages share the layout for consistency but opt out of
    // indexing because they are workflow pages, not public content.
    const robots_meta = if (meta.noindex) templates.robots_meta else "";
    const twitter_card = if (meta.og_image.len > 0) "summary_large_image" else "summary";

    try template.render(writer, templates.layout_start, &.{
        .{ .name = "title", .value = meta.title },
        .{ .name = "description", .value = meta.description },
        .{ .name = "canonical_url", .value = meta.canonical_url },
        .{ .name = "og_type", .value = meta.og_type },
        .{ .name = "social_title", .value = social_title },
        .{ .name = "twitter_card", .value = twitter_card },
        .{ .name = "og_image_meta", .value = og_image_meta },
        .{ .name = "robots_meta", .value = robots_meta },
        .{ .name = "theme_boot_js", .value = templates.theme_boot_js },
        .{ .name = "page_css", .value = templates.page_css },
        .{ .name = "site_title", .value = cfg.site_title },
        .{ .name = "header_actions", .value = header_actions },
    });
}

fn endPage(writer: *Writer, cfg: Config) !void {
    try template.render(writer, templates.footer, &.{
        .{ .name = "footer_text", .value = cfg.footer_text },
        .{ .name = "theme_choice_js", .value = templates.theme_choice_js },
    });
}

fn headerActions(allocator: std.mem.Allocator, viewer: ?[]const u8) ![]u8 {
    if (viewer) |username| {
        return try template.renderAlloc(allocator, templates.header_user, &.{
            .{ .name = "username", .value = username },
        });
    }
    return try allocator.dupe(u8, templates.header_guest);
}

fn optionalOgImageMeta(allocator: std.mem.Allocator, og_image: []const u8) ![]u8 {
    if (og_image.len == 0) return try allocator.dupe(u8, "");
    return try template.renderAlloc(allocator, templates.og_image_meta, &.{
        .{ .name = "og_image", .value = og_image },
    });
}

fn renderPostList(
    allocator: std.mem.Allocator,
    writer: *Writer,
    posts: []const post.Post,
    start_index: usize,
) !void {
    if (posts.len == 0) {
        try template.render(writer, templates.post_list_empty, &.{});
        return;
    }

    try writer.print("<ol class=\"posts\" start=\"{d}\">\n", .{start_index});
    for (posts) |item| {
        const tags_html = try escapedSuffix(allocator, " | ", item.tags);
        defer allocator.free(tags_html);

        try template.render(writer, templates.post_list_item, &.{
            .{ .name = "slug", .value = item.slug },
            .{ .name = "title", .value = item.title },
            .{ .name = "created_at", .value = item.created_at },
            .{ .name = "tags_html", .value = tags_html },
        });
    }
    try writer.writeAll("</ol>\n");
}

fn renderPostFull(allocator: std.mem.Allocator, writer: *Writer, item: post.Post) !void {
    const tags_html = try escapedSuffix(allocator, " | ", item.tags);
    defer allocator.free(tags_html);

    const body_html = try bodyHtml(allocator, item.body);
    defer allocator.free(body_html);

    try template.render(writer, templates.post_full, &.{
        .{ .name = "title", .value = item.title },
        .{ .name = "created_at", .value = item.created_at },
        .{ .name = "status", .value = item.status },
        .{ .name = "tags_html", .value = tags_html },
        .{ .name = "body_html", .value = body_html },
    });
}

fn renderPager(writer: *Writer, page: usize) !void {
    try writer.writeAll("<div class=\"pager\">");
    if (page > 1) {
        try writer.print("<a href=\"/latest/{d}\">prev</a> | ", .{page - 1});
    }
    try writer.print("<a href=\"/latest/{d}\">more</a>", .{page + 1});
    try writer.writeAll("</div>\n");
}

fn escapedSuffix(allocator: std.mem.Allocator, prefix: []const u8, text: []const u8) ![]u8 {
    if (text.len == 0) return try allocator.dupe(u8, "");

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(prefix);
    try escapeHtml(&out.writer, text);
    return try out.toOwnedSlice();
}

fn bodyHtml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try escapeBody(&out.writer, text);
    return try out.toOwnedSlice();
}

fn absoluteUrl(allocator: std.mem.Allocator, cfg: Config, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        return try allocator.dupe(u8, path);
    }
    const base = std.mem.trimEnd(u8, cfg.site_base_url, "/");
    if (path.len == 0) return try allocator.dupe(u8, base);
    if (path[0] == '/') return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
}

fn imageUrl(allocator: std.mem.Allocator, cfg: Config, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");
    return try absoluteUrl(allocator, cfg, trimmed);
}

fn excerptFromBody(allocator: std.mem.Allocator, body: []const u8, fallback: []const u8) ![]u8 {
    const limit = 180;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var previous_space = false;
    var truncated = false;
    // Meta descriptions have a short budget, so whitespace is collapsed instead
    // of preserving author formatting.
    for (body) |byte| {
        const is_space = switch (byte) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        };
        if (is_space) {
            if (out.items.len > 0 and !previous_space) {
                if (out.items.len >= limit) {
                    truncated = true;
                    break;
                }
                try out.append(allocator, ' ');
            }
            previous_space = true;
            continue;
        }

        if (out.items.len >= limit) {
            truncated = true;
            break;
        }
        try out.append(allocator, byte);
        previous_space = false;
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    if (out.items.len == 0) try out.appendSlice(allocator, fallback);
    if (truncated) try out.appendSlice(allocator, "...");
    return try out.toOwnedSlice(allocator);
}

pub fn escapeHtml(writer: *Writer, text: []const u8) !void {
    try template.escapeHtml(writer, text);
}

fn escapeBody(writer: *Writer, text: []const u8) !void {
    // Posts are plain text; line breaks become markup without allowing raw HTML.
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        '\n' => try writer.writeAll("<br>\n"),
        else => try writer.writeByte(byte),
    };
}

fn testConfig() Config {
    return .{
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
}

fn testPost(allocator: std.mem.Allocator) !post.Post {
    return .{
        .id = try allocator.dupe(u8, "1"),
        .title = try allocator.dupe(u8, "<Title & News>"),
        .slug = try allocator.dupe(u8, "title-news"),
        .body = try allocator.dupe(u8, "line <one>\nline & two"),
        .excerpt = try allocator.dupe(u8, ""),
        .og_image = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, "123"),
        .updated_at = try allocator.dupe(u8, "124"),
        .status = try allocator.dupe(u8, "published"),
        .tags = try allocator.dupe(u8, "zig & redis"),
    };
}

test "html escape covers active characters" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try escapeHtml(&out.writer, "<a&b>");
    try std.testing.expectEqualStrings("&lt;a&amp;b&gt;", out.written());
}

test "render signin escapes error message and resolves templates" {
    const html = try renderSignin(std.testing.allocator, testConfig(), null, "<bad&login>");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;bad&amp;login&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<bad&login>") == null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render single escapes dynamic post content" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);

    const html = try renderSingle(std.testing.allocator, testConfig(), null, item);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>&lt;Title &amp; News&gt;</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "line &lt;one&gt;<br>\nline &amp; two") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "zig &amp; redis") != null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}
