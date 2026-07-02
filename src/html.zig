// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! Server-side HTML renderer for the blog UI.
//!
//! Static markup lives in embedded template files; this module keeps the
//! dynamic parts in Zig so loops, conditionals, and escaping stay explicit.
const std = @import("std");
const auth = @import("auth.zig");
const build_options = @import("build_options");
const comment = @import("comment.zig");
const Config = @import("config.zig").Config;
const markdown = @import("markdown.zig");
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
    const donate = @embedFile("templates/donate.html");
    const post_list_empty = @embedFile("templates/post_list_empty.html");
    const post_list_item = @embedFile("templates/post_list_item.html");
    const post_full = @embedFile("templates/post_full.html");
    const theme_css = @embedFile("templates/styles/theme.css");
    const layout_css = @embedFile("templates/styles/layout.css");
    const posts_css = @embedFile("templates/styles/posts.css");
    const forms_css = @embedFile("templates/styles/forms.css");
    const donate_css = @embedFile("templates/styles/donate.css");
    const theme_boot_js = @embedFile("templates/scripts/theme_boot.js");
    const theme_choice_js = @embedFile("templates/scripts/theme_choice.js");
    const post_actions_js = @embedFile("templates/scripts/post_actions.js");
};

const Meta = struct {
    title: []const u8,
    social_title: []const u8 = "",
    description: []const u8,
    canonical_url: []const u8,
    og_type: []const u8 = "website",
    og_image: []const u8 = "",
    noindex: bool = false,
    draft_count: usize = 0,
};

pub const AdminView = struct {
    draft_count: usize = 0,
    drafts: []const post.Post = &.{},
    show_drafts: bool = false,
    selected: ?*const post.Post = null,
};

pub fn renderHome(allocator: std.mem.Allocator, cfg: Config, viewer: ?auth.Viewer, posts: []const post.Post, page: usize, now_seconds: i64, draft_count: usize) ![]u8 {
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
        .draft_count = draft_count,
    });
    try renderPostList(allocator, &out.writer, posts, (page - 1) * post.per_page + 1, now_seconds);
    try renderPager(&out.writer, page);
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderSingle(allocator: std.mem.Allocator, cfg: Config, viewer: ?auth.Viewer, item: post.Post, comments: []const comment.Comment, now_seconds: i64, draft_count: usize) ![]u8 {
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
        .draft_count = draft_count,
    });
    try renderPostFull(allocator, &out.writer, viewer, item, comments, now_seconds);
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderAdmin(allocator: std.mem.Allocator, cfg: Config, viewer: auth.Viewer, admin: AdminView) ![]u8 {
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
        .draft_count = admin.draft_count,
    });

    const drafts_html = try draftListHtml(allocator, admin.drafts, admin.show_drafts);
    defer allocator.free(drafts_html);
    const draft_count = try draftCountLabel(allocator, admin.draft_count);
    defer allocator.free(draft_count);
    const drafts_href = if (admin.show_drafts) "/admin" else "/admin/drafts";
    const selected = admin.selected;
    const status = if (selected) |item| item.status else "draft";

    try template.render(&out.writer, templates.admin_form, &.{
        .{ .name = "id", .value = if (selected) |item| item.id else "" },
        .{ .name = "title", .value = if (selected) |item| item.title else "" },
        .{ .name = "draft_count", .value = draft_count },
        .{ .name = "drafts_href", .value = drafts_href },
        .{ .name = "drafts_html", .value = drafts_html },
        .{ .name = "draft_selected", .value = if (std.mem.eql(u8, status, "draft")) " selected" else "" },
        .{ .name = "published_selected", .value = if (std.mem.eql(u8, status, "published")) " selected" else "" },
        .{ .name = "body", .value = if (selected) |item| item.body else "" },
        .{ .name = "excerpt", .value = if (selected) |item| item.excerpt else "" },
        .{ .name = "og_image", .value = if (selected) |item| item.og_image else "" },
        .{ .name = "tags", .value = if (selected) |item| item.tags else "" },
    });
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderSignin(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
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
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderPasswordChange(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
    error_message: ?[]const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const canonical_url = try absoluteUrl(allocator, cfg, "/account/password");
    defer allocator.free(canonical_url);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = "change password",
        .social_title = "change password",
        .description = "Change account password.",
        .canonical_url = canonical_url,
        .noindex = true,
    });
    if (viewer) |current| {
        if (current.must_change_password) {
            try out.writer.writeAll("<p class=\"form-error\">This generated password must be changed before continuing.</p>\n");
        }
    }
    if (error_message) |message| {
        try template.render(&out.writer, templates.signin_error, &.{
            .{ .name = "message", .value = message },
        });
    }
    try out.writer.writeAll(
        \\<form class="password-form" method="post" action="/account/password">
        \\<div><label>current password<input name="current_password" type="password" autocomplete="current-password" required></label></div>
        \\<div><label>new password<input name="new_password" type="password" autocomplete="new-password" minlength="12" maxlength="256" required></label></div>
        \\<div><label>confirm password<input name="confirm_password" type="password" autocomplete="new-password" minlength="12" maxlength="256" required></label></div>
        \\<div><button type="submit">change password</button></div>
        \\</form>
        \\
    );
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

pub fn renderDonate(allocator: std.mem.Allocator, cfg: Config, viewer: ?auth.Viewer, draft_count: usize, about_markdown: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const canonical_url = try absoluteUrl(allocator, cfg, "/donate");
    defer allocator.free(canonical_url);
    const description = try std.fmt.allocPrint(allocator, "Support {s}.", .{cfg.site_title});
    defer allocator.free(description);

    try beginPage(allocator, &out.writer, cfg, viewer, .{
        .title = "donate",
        .social_title = "donate",
        .description = description,
        .canonical_url = canonical_url,
        .draft_count = draft_count,
    });

    const paypal_link = try donateProviderLink(allocator, cfg.donate_paypal_url, "PayPal", "paypal");
    defer allocator.free(paypal_link);
    const kofi_link = try donateProviderLink(allocator, cfg.donate_kofi_url, "Ko-fi", "kofi");
    defer allocator.free(kofi_link);
    const bitcoin_link = try donateProviderLink(allocator, cfg.donate_bitcoin_url, "Bitcoin", "bitcoin");
    defer allocator.free(bitcoin_link);

    const standard_links = try concatFragments(allocator, &.{ paypal_link, kofi_link });
    defer allocator.free(standard_links);
    const crypto_links = try concatFragments(allocator, &.{bitcoin_link});
    defer allocator.free(crypto_links);

    const standard_section = try donateSection(allocator, "standard", standard_links);
    defer allocator.free(standard_section);
    const crypto_section = try donateSection(allocator, "crypto", crypto_links);
    defer allocator.free(crypto_section);
    const about_section = try donateAboutSection(allocator, cfg.donate_about_profile_image_url, about_markdown);
    defer allocator.free(about_section);

    try template.render(&out.writer, templates.donate, &.{
        .{ .name = "standard_section", .value = standard_section },
        .{ .name = "crypto_section", .value = crypto_section },
        .{ .name = "about_section", .value = about_section },
    });
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

fn donateProviderLink(
    allocator: std.mem.Allocator,
    url: []const u8,
    label: []const u8,
    provider: []const u8,
) ![]u8 {
    const trimmed_url = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed_url.len == 0) return try allocator.dupe(u8, "");

    return try template.renderAlloc(allocator, "<a class=\"donate-button donate-button-{{provider}}\" href=\"{{url}}\" target=\"_blank\" rel=\"noopener noreferrer\" aria-label=\"Donate with {{label}}\" title=\"{{label}}\"><span class=\"donate-button-label\">{{label}}</span></a>\n", &.{
        .{ .name = "url", .value = trimmed_url },
        .{ .name = "label", .value = label },
        .{ .name = "provider", .value = provider },
    });
}

fn concatFragments(allocator: std.mem.Allocator, fragments: []const []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    for (fragments) |fragment| {
        if (fragment.len > 0) try out.writer.writeAll(fragment);
    }
    return try out.toOwnedSlice();
}

fn donateSection(allocator: std.mem.Allocator, title: []const u8, links_html: []const u8) ![]u8 {
    if (links_html.len == 0) return try allocator.dupe(u8, "");

    return try template.renderAlloc(allocator, "<div class=\"donate-section\">\n<h2>{{title}}</h2>\n<div class=\"donate-links\">\n{{{links_html}}}</div>\n</div>\n", &.{
        .{ .name = "title", .value = title },
        .{ .name = "links_html", .value = links_html },
    });
}

fn donateAboutSection(allocator: std.mem.Allocator, raw_profile_image_url: []const u8, source: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");

    const profile_image = try donateProfileImage(allocator, raw_profile_image_url);
    defer allocator.free(profile_image);
    const about_html = try markdown.renderBody(allocator, trimmed);
    defer allocator.free(about_html);
    return try template.renderAlloc(allocator, "<div class=\"donate-about\">\n<h2>about me</h2>\n{{{profile_image}}}<div class=\"donate-about-body\">\n{{{about_html}}}</div>\n</div>\n", &.{
        .{ .name = "profile_image", .value = profile_image },
        .{ .name = "about_html", .value = about_html },
    });
}

fn donateProfileImage(allocator: std.mem.Allocator, raw_url: []const u8) ![]u8 {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (!safeImageUrl(url)) return try allocator.dupe(u8, "");

    return try template.renderAlloc(allocator, "<img class=\"donate-profile-image\" src=\"{{url}}\" alt=\"profile photo\" loading=\"lazy\" decoding=\"async\">\n", &.{
        .{ .name = "url", .value = url },
    });
}

fn safeImageUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '"' or byte == '\'' or byte == '<' or byte == '>') return false;
    }
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "/statics/");
}

pub fn renderMessage(
    allocator: std.mem.Allocator,
    cfg: Config,
    viewer: ?auth.Viewer,
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
    try endPage(allocator, &out.writer, cfg);
    return try out.toOwnedSlice();
}

fn beginPage(
    allocator: std.mem.Allocator,
    writer: *Writer,
    cfg: Config,
    viewer: ?auth.Viewer,
    meta: Meta,
) !void {
    const social_title = if (meta.social_title.len > 0) meta.social_title else meta.title;

    const header_actions = try headerActions(allocator, viewer);
    defer allocator.free(header_actions);

    const submit_link = try submitLink(allocator, meta.draft_count);
    defer allocator.free(submit_link);

    const brand_logo = try brandLogo(allocator, cfg.site_logo_light, cfg.site_logo_dark);
    defer allocator.free(brand_logo);

    const og_image_meta = try optionalOgImageMeta(allocator, meta.og_image, social_title);
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
        .{ .name = "theme_css", .value = templates.theme_css },
        .{ .name = "layout_css", .value = templates.layout_css },
        .{ .name = "posts_css", .value = templates.posts_css },
        .{ .name = "forms_css", .value = templates.forms_css },
        .{ .name = "donate_css", .value = templates.donate_css },
        .{ .name = "brand_logo", .value = brand_logo },
        .{ .name = "site_title", .value = cfg.site_title },
        .{ .name = "submit_link", .value = submit_link },
        .{ .name = "header_actions", .value = header_actions },
    });
}

fn endPage(allocator: std.mem.Allocator, writer: *Writer, cfg: Config) !void {
    const powered_by = try poweredBy(allocator, cfg.site_logo_light, cfg.site_logo_dark, build_options.version);
    defer allocator.free(powered_by);

    try template.render(writer, templates.footer, &.{
        .{ .name = "footer_text", .value = cfg.footer_text },
        .{ .name = "powered_by", .value = powered_by },
        .{ .name = "theme_choice_js", .value = templates.theme_choice_js },
        .{ .name = "post_actions_js", .value = templates.post_actions_js },
    });
}

fn brandLogo(allocator: std.mem.Allocator, site_logo_light: []const u8, site_logo_dark: []const u8) ![]u8 {
    const light_logo = std.mem.trim(u8, site_logo_light, " \t\r\n");
    const dark_logo = std.mem.trim(u8, site_logo_dark, " \t\r\n");
    if (light_logo.len == 0 and dark_logo.len == 0) return try allocator.dupe(u8, "");

    return try template.renderAlloc(allocator, "<img class=\"brand-logo theme-logo-light\" src=\"{{light_logo}}\" alt=\"\" width=\"18\" height=\"18\"><img class=\"brand-logo theme-logo-dark\" src=\"{{dark_logo}}\" alt=\"\" width=\"18\" height=\"18\">", &.{
        .{ .name = "light_logo", .value = if (light_logo.len > 0) light_logo else dark_logo },
        .{ .name = "dark_logo", .value = if (dark_logo.len > 0) dark_logo else light_logo },
    });
}

fn poweredBy(allocator: std.mem.Allocator, site_logo_light: []const u8, site_logo_dark: []const u8, app_version: []const u8) ![]u8 {
    const light_logo = std.mem.trim(u8, site_logo_light, " \t\r\n");
    const dark_logo = std.mem.trim(u8, site_logo_dark, " \t\r\n");
    if (light_logo.len == 0 and dark_logo.len == 0) {
        return try template.renderAlloc(allocator, "<div class=\"powered-by\"><span class=\"app-version\">v{{version}}</span></div>", &.{
            .{ .name = "version", .value = app_version },
        });
    }

    return try template.renderAlloc(allocator, "<div class=\"powered-by\">powered by <img class=\"powered-by-logo theme-logo-light\" src=\"{{light_logo}}\" alt=\"\" width=\"18\" height=\"18\"><img class=\"powered-by-logo theme-logo-dark\" src=\"{{dark_logo}}\" alt=\"\" width=\"18\" height=\"18\"><span class=\"app-version\">v{{version}}</span></div>", &.{
        .{ .name = "light_logo", .value = if (light_logo.len > 0) light_logo else dark_logo },
        .{ .name = "dark_logo", .value = if (dark_logo.len > 0) dark_logo else light_logo },
        .{ .name = "version", .value = app_version },
    });
}

fn headerActions(allocator: std.mem.Allocator, viewer: ?auth.Viewer) ![]u8 {
    if (viewer) |current| {
        return try template.renderAlloc(allocator, templates.header_user, &.{
            .{ .name = "username", .value = current.username },
        });
    }
    return try allocator.dupe(u8, templates.header_guest);
}

fn submitLink(allocator: std.mem.Allocator, draft_count: usize) ![]u8 {
    if (draft_count == 0) return try allocator.dupe(u8, "<a href=\"/admin\">submit</a>");
    return try std.fmt.allocPrint(allocator, "<a href=\"/admin\">submit({d})</a>", .{draft_count});
}

fn draftCountLabel(allocator: std.mem.Allocator, draft_count: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{draft_count});
}

fn draftListHtml(allocator: std.mem.Allocator, drafts: []const post.Post, show_drafts: bool) ![]u8 {
    if (!show_drafts) return try allocator.dupe(u8, "");

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("<div class=\"draft-list\">\n<h2>drafts</h2>\n");
    if (drafts.len == 0) {
        try out.writer.writeAll("<div class=\"subtext\">no drafts</div>\n</div>\n");
        return try out.toOwnedSlice();
    }

    try out.writer.writeAll("<ol>\n");
    for (drafts) |item| {
        try out.writer.writeAll("<li><a href=\"/admin/draft/");
        try escapeHtml(&out.writer, item.id);
        try out.writer.writeAll("\">");
        try escapeHtml(&out.writer, item.title);
        try out.writer.writeAll("</a></li>\n");
    }
    try out.writer.writeAll("</ol>\n</div>\n");
    return try out.toOwnedSlice();
}

fn optionalOgImageMeta(allocator: std.mem.Allocator, og_image: []const u8, image_alt: []const u8) ![]u8 {
    if (og_image.len == 0) return try allocator.dupe(u8, "");
    return try template.renderAlloc(allocator, templates.og_image_meta, &.{
        .{ .name = "og_image", .value = og_image },
        .{ .name = "image_alt", .value = image_alt },
    });
}

fn renderPostList(
    allocator: std.mem.Allocator,
    writer: *Writer,
    posts: []const post.Post,
    start_index: usize,
    now_seconds: i64,
) !void {
    if (posts.len == 0) {
        try template.render(writer, templates.post_list_empty, &.{});
        return;
    }

    try writer.print("<ol class=\"posts\" start=\"{d}\">\n", .{start_index});
    for (posts) |item| {
        const relative_time = try relativeTime(allocator, item.created_at, now_seconds);
        defer allocator.free(relative_time);

        try template.render(writer, templates.post_list_item, &.{
            .{ .name = "slug", .value = item.slug },
            .{ .name = "title", .value = item.title },
            .{ .name = "points", .value = item.points },
            .{ .name = "author", .value = authorOrFallback(item.author) },
            .{ .name = "relative_time", .value = relative_time },
        });
    }
    try writer.writeAll("</ol>\n");
}

fn renderPostFull(allocator: std.mem.Allocator, writer: *Writer, viewer: ?auth.Viewer, item: post.Post, comments: []const comment.Comment, now_seconds: i64) !void {
    const tags_html = try escapedSuffix(allocator, " | ", item.tags);
    defer allocator.free(tags_html);

    const body_html = try markdown.renderBody(allocator, item.body);
    defer allocator.free(body_html);

    const relative_time = try relativeTime(allocator, item.created_at, now_seconds);
    defer allocator.free(relative_time);

    const author_actions = try postAuthorActions(allocator, viewer, item);
    defer allocator.free(author_actions);

    const comments_html = try renderComments(allocator, viewer, item.slug, comments, now_seconds);
    defer allocator.free(comments_html);

    try template.render(writer, templates.post_full, &.{
        .{ .name = "slug", .value = item.slug },
        .{ .name = "title", .value = item.title },
        .{ .name = "author_actions", .value = author_actions },
        .{ .name = "points", .value = item.points },
        .{ .name = "author", .value = authorOrFallback(item.author) },
        .{ .name = "relative_time", .value = relative_time },
        .{ .name = "status", .value = item.status },
        .{ .name = "tags_html", .value = tags_html },
        .{ .name = "body_html", .value = body_html },
        .{ .name = "comments_html", .value = comments_html },
    });
}

fn renderComments(allocator: std.mem.Allocator, viewer: ?auth.Viewer, post_slug: []const u8, comments: []const comment.Comment, now_seconds: i64) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("<section id=\"comments\" class=\"comments\">\n");
    try out.writer.print("<h2>{d} {s}</h2>\n", .{ comments.len, if (comments.len == 1) "comment" else "comments" });
    try renderRootCommentForm(&out.writer, post_slug);

    if (comments.len == 0) {
        try out.writer.writeAll("<p class=\"subtext\">no comments yet</p>\n</section>\n");
        return try out.toOwnedSlice();
    }

    try out.writer.writeAll("<ol class=\"comment-list\">\n");
    const can_delete = if (viewer) |current| auth.isAdmin(current) else false;
    try renderCommentChildren(allocator, &out.writer, can_delete, post_slug, comments, "", now_seconds);
    try out.writer.writeAll("</ol>\n</section>\n");
    return try out.toOwnedSlice();
}

fn renderCommentChildren(allocator: std.mem.Allocator, writer: *Writer, can_delete: bool, post_slug: []const u8, comments: []const comment.Comment, parent_id: []const u8, now_seconds: i64) anyerror!void {
    // ponytail: O(n²) tree walk is fine for small blog threads; index children if comment volume hurts.
    for (comments) |item| {
        if (!std.mem.eql(u8, item.parent_id, parent_id)) continue;
        try renderCommentItem(allocator, writer, can_delete, post_slug, comments, item, now_seconds);
    }
}

fn renderCommentItem(allocator: std.mem.Allocator, writer: *Writer, can_delete: bool, post_slug: []const u8, comments: []const comment.Comment, item: comment.Comment, now_seconds: i64) anyerror!void {
    const relative_time = try relativeTime(allocator, item.created_at, now_seconds);
    defer allocator.free(relative_time);

    try writer.writeAll("<li id=\"comment-");
    try escapeHtml(writer, item.id);
    try writer.writeAll("\" class=\"comment\">\n<div class=\"comment-meta\"><a href=\"#comment-");
    try escapeHtml(writer, item.id);
    try writer.writeAll("\">#</a> ");
    try escapeHtml(writer, item.author);
    try writer.writeAll(" ");
    try escapeHtml(writer, relative_time);
    if (can_delete) try renderCommentDeleteControl(writer, item);
    try writer.writeAll("</div>\n<div class=\"comment-body\">");
    try renderPlainWithBreaks(writer, item.body);
    try writer.writeAll("</div>\n<details class=\"comment-reply\"><summary>reply</summary>\n");
    try renderCommentForm(writer, post_slug, item.id);
    try writer.writeAll("</details>\n");

    if (hasCommentChildren(comments, item.id)) {
        try writer.writeAll("<ol class=\"comment-children\">\n");
        try renderCommentChildren(allocator, writer, can_delete, post_slug, comments, item.id, now_seconds);
        try writer.writeAll("</ol>\n");
    }

    try writer.writeAll("</li>\n");
}

fn renderCommentDeleteControl(writer: *Writer, item: comment.Comment) !void {
    try writer.writeAll(" <button class=\"comment-delete-button\" type=\"button\" data-open-delete-dialog=\"comment-delete-dialog-");
    try escapeHtml(writer, item.id);
    try writer.writeAll("\" aria-label=\"delete comment by ");
    try escapeHtml(writer, item.author);
    try writer.writeAll("\" title=\"delete\">x</button>\n");
    try writer.writeAll("<dialog id=\"comment-delete-dialog-");
    try escapeHtml(writer, item.id);
    try writer.writeAll("\" class=\"post-delete-dialog comment-delete-dialog\" aria-labelledby=\"comment-delete-title-");
    try escapeHtml(writer, item.id);
    try writer.writeAll("\">\n<div class=\"post-delete-header\" id=\"comment-delete-title-");
    try escapeHtml(writer, item.id);
    try writer.writeAll("\">delete comment?</div>\n<div class=\"post-delete-body\">\n<form class=\"post-delete-form\" method=\"post\" action=\"/admin/comment/");
    try escapeHtml(writer, item.id);
    try writer.writeAll("/delete\">\n<div class=\"post-delete-actions\">\n<button type=\"submit\">yes</button>\n<button type=\"button\" data-close-delete-dialog>no</button>\n</div>\n</form>\n</div>\n</dialog>");
}

fn renderRootCommentForm(writer: *Writer, post_slug: []const u8) !void {
    try writer.writeAll("<details class=\"comment-compose\">\n<summary>add comment</summary>\n");
    try renderCommentForm(writer, post_slug, null);
    try writer.writeAll("</details>\n");
}

fn renderCommentForm(writer: *Writer, post_slug: []const u8, parent_id: ?[]const u8) !void {
    try writer.writeAll("<form class=\"comment-form");
    if (parent_id != null) try writer.writeAll(" comment-reply-form");
    try writer.writeAll("\" method=\"post\" action=\"/post/");
    try escapeHtml(writer, post_slug);
    try writer.writeAll("/comment\">\n");
    if (parent_id) |id| {
        try writer.writeAll("<input type=\"hidden\" name=\"parent_id\" value=\"");
        try escapeHtml(writer, id);
        try writer.writeAll("\">\n");
    }
    try writer.writeAll("<div><label>name<input name=\"author\" maxlength=\"80\" autocomplete=\"name\" required></label></div>\n");
    try writer.writeAll("<div><label>comment<textarea name=\"body\" rows=\"4\" maxlength=\"5000\" required></textarea></label></div>\n");
    try writer.writeAll("<div><button type=\"submit\">");
    try writer.writeAll(if (parent_id == null) "add comment" else "comment");
    try writer.writeAll("</button></div>\n</form>\n");
}

fn hasCommentChildren(comments: []const comment.Comment, parent_id: []const u8) bool {
    for (comments) |item| {
        if (std.mem.eql(u8, item.parent_id, parent_id)) return true;
    }
    return false;
}

fn renderPlainWithBreaks(writer: *Writer, text: []const u8) !void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte != '\n' and byte != '\r') {
            index += 1;
            continue;
        }

        try escapeHtml(writer, text[start..index]);
        try writer.writeAll("<br>\n");
        index += 1;
        if (byte == '\r' and index < text.len and text[index] == '\n') index += 1;
        start = index;
    }
    try escapeHtml(writer, text[start..]);
}

fn postAuthorActions(allocator: std.mem.Allocator, viewer: ?auth.Viewer, item: post.Post) ![]u8 {
    const current = viewer orelse return try allocator.dupe(u8, "");
    if (!auth.isAdmin(current) or item.author.len == 0 or !std.mem.eql(u8, current.username, item.author)) return try allocator.dupe(u8, "");

    return try template.renderAlloc(allocator,
        \\<div class="post-author-actions">
        \\<a class="post-action-button" href="/admin/post/{{id}}/edit" aria-label="edit {{title}}" title="edit">
        \\<svg class="post-action-icon post-edit-icon" xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" aria-hidden="true"><path fill="#888888" d="M4 21q-.425 0-.712-.288T3 20v-2.425q0-.4.15-.763t.425-.637L16.2 3.575q.3-.275.663-.425t.762-.15t.775.15t.65.45L20.425 5q.3.275.437.65T21 6.4q0 .4-.138.763t-.437.662l-12.6 12.6q-.275.275-.638.425t-.762.15zM17.6 7.8L19 6.4L17.6 5l-1.4 1.4z"/></svg>
        \\</a>
        \\<button class="post-action-button" type="button" data-open-delete-dialog="post-delete-dialog-{{id}}" aria-label="delete {{title}}" title="delete">
        \\<svg class="post-action-icon post-delete-icon" xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" aria-hidden="true"><path fill="#888888" d="M9 17h2V8H9zm4 0h2V8h-2zm-8 4V6H4V4h5V3h6v1h5v2h-1v15z"/></svg>
        \\</button>
        \\</div>
        \\<dialog id="post-delete-dialog-{{id}}" class="post-delete-dialog" aria-labelledby="post-delete-title-{{id}}">
        \\<div class="post-delete-header" id="post-delete-title-{{id}}">are you sure?</div>
        \\<div class="post-delete-body">
        \\<form class="post-delete-form" method="post" action="/admin/post/{{id}}/delete">
        \\<div class="post-delete-actions">
        \\<button type="submit">yes</button>
        \\<button type="button" data-close-delete-dialog>no</button>
        \\</div>
        \\</form>
        \\</div>
        \\</dialog>
        \\
    , &.{
        .{ .name = "id", .value = item.id },
        .{ .name = "title", .value = item.title },
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

fn authorOrFallback(author: []const u8) []const u8 {
    return if (author.len > 0) author else "unknown";
}

fn relativeTime(allocator: std.mem.Allocator, created_at: []const u8, now_seconds: i64) ![]u8 {
    const created_seconds = std.fmt.parseInt(i64, created_at, 10) catch now_seconds;
    const raw_age = now_seconds - created_seconds;
    const age = if (raw_age > 0) raw_age else 0;

    if (age < 3600) {
        const minutes = @max(@divFloor(age, 60), 1);
        return try std.fmt.allocPrint(allocator, "{d} minutes ago", .{minutes});
    }
    if (age < 86400) {
        const hours = @max(@divFloor(age, 3600), 1);
        return try std.fmt.allocPrint(allocator, "{d} hours ago", .{hours});
    }

    const days = @max(@divFloor(age, 86400), 1);
    const unit = if (days == 1) "day" else "days";
    return try std.fmt.allocPrint(allocator, "{d} {s} ago", .{ days, unit });
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
    const plain = try markdown.plainText(allocator, body);
    defer allocator.free(plain);
    return try excerptFromPlain(allocator, plain, fallback);
}

fn excerptFromPlain(allocator: std.mem.Allocator, body: []const u8, fallback: []const u8) ![]u8 {
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

fn testConfig() Config {
    return .{
        .blog_host = "127.0.0.1",
        .blog_port = 8080,
        .log_level = .info,
        .sqlite_path = "evilblog.sqlite3",
        .redis_host = "127.0.0.1",
        .redis_port = 6379,
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
        .donate_about_profile_image_url = "https://avatars.githubusercontent.com/u/19678157?v=4",
        .footer_text = "evilblog",
    };
}

fn testPost(allocator: std.mem.Allocator) !post.Post {
    return .{
        .id = try allocator.dupe(u8, "1"),
        .title = try allocator.dupe(u8, "<Title & News>"),
        .slug = try allocator.dupe(u8, "title-news"),
        .body = try allocator.dupe(u8, "line <one>\nline & two\n\n**bold** [link](/post/a)"),
        .excerpt = try allocator.dupe(u8, ""),
        .og_image = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, "123"),
        .updated_at = try allocator.dupe(u8, "124"),
        .author = try allocator.dupe(u8, "admin"),
        .points = try allocator.dupe(u8, "3"),
        .status = try allocator.dupe(u8, "published"),
        .tags = try allocator.dupe(u8, "zig & redis"),
    };
}

fn testViewer(username: []const u8, role: auth.Role) auth.Viewer {
    return .{ .username = @constCast(username), .role = role, .must_change_password = false };
}

fn testComment(allocator: std.mem.Allocator, id: []const u8, parent_id: []const u8, author: []const u8, body: []const u8, created_at: []const u8) !comment.Comment {
    return .{
        .id = try allocator.dupe(u8, id),
        .post_id = try allocator.dupe(u8, "1"),
        .parent_id = try allocator.dupe(u8, parent_id),
        .author = try allocator.dupe(u8, author),
        .body = try allocator.dupe(u8, body),
        .created_at = try allocator.dupe(u8, created_at),
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
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"/apple-touch-icon.png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"icon\" type=\"image/png\" sizes=\"32x32\" href=\"/favicon-32x32.png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"icon\" type=\"image/png\" sizes=\"16x16\" href=\"/favicon-16x16.png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"manifest\" href=\"/site.webmanifest\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<link rel=\"shortcut icon\" href=\"/favicon.ico\">") != null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render password change shows forced-change warning" {
    var viewer = testViewer("admin", .admin);
    viewer.must_change_password = true;

    const html = try renderPasswordChange(std.testing.allocator, testConfig(), viewer, "Bad password");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "This generated password must be changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Bad password") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"current_password\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"new_password\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"confirm_password\"") != null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render admin form uses creation sections and generated slugs" {
    const html = try renderAdmin(std.testing.allocator, testConfig(), testViewer("admin", .admin), .{ .draft_count = 2 });
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Evilblog post") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Evilblog metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<hr class=\"admin-section-separator\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a href=\"/admin\">submit(2)</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<a class=\"drafts-button\" href=\"/admin/drafts\">drafts(2)</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"slug\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<option value=\"draft\" selected>draft</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"title\"").? < std.mem.indexOf(u8, html, "name=\"status\"").?);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"status\"").? < std.mem.indexOf(u8, html, "name=\"body\"").?);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"body\"").? < std.mem.indexOf(u8, html, "Evilblog metadata").?);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render admin can list and load drafts" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);
    std.testing.allocator.free(item.status);
    item.status = try std.testing.allocator.dupe(u8, "draft");

    const drafts = [_]post.Post{item};
    const list_html = try renderAdmin(std.testing.allocator, testConfig(), testViewer("admin", .admin), .{
        .draft_count = 1,
        .drafts = &drafts,
        .show_drafts = true,
    });
    defer std.testing.allocator.free(list_html);

    try std.testing.expect(std.mem.indexOf(u8, list_html, "<div class=\"draft-list\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_html, "<a class=\"drafts-button\" href=\"/admin\">drafts(1)</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_html, "href=\"/admin/draft/1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_html, "drafts-button").? < std.mem.indexOf(u8, list_html, "<div class=\"draft-list\">").?);
    try std.testing.expect(std.mem.indexOf(u8, list_html, "<div class=\"draft-list\">").? < std.mem.indexOf(u8, list_html, "name=\"title\"").?);

    const form_html = try renderAdmin(std.testing.allocator, testConfig(), testViewer("admin", .admin), .{
        .draft_count = 1,
        .selected = &item,
    });
    defer std.testing.allocator.free(form_html);

    try std.testing.expect(std.mem.indexOf(u8, form_html, "name=\"id\" value=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_html, "value=\"&lt;Title &amp; News&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_html, "line &lt;one&gt;") != null);
    try std.testing.expect(!template.containsPlaceholderToken(form_html));
}

test "render single escapes dynamic post content" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);

    const html = try renderSingle(std.testing.allocator, testConfig(), null, item, &.{}, 123 + 3600, 0);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>&lt;Title &amp; News&gt;</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>line &lt;one&gt;<br>\nline &amp; two</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>bold</strong> <a href=\"/post/a\" rel=\"noopener noreferrer\">link</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "zig &amp; redis") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "3 points by admin 1 hours ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"post-author-actions\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/admin/post/1/edit") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"post-delete-dialog\"") == null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render single shows escaped threaded comments" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);

    var root = try testComment(std.testing.allocator, "1", "", "Alice <x>", "Root <script>\nline", "123");
    defer root.deinit(std.testing.allocator);
    var reply = try testComment(std.testing.allocator, "2", "1", "Bob", "Reply & ok", "183");
    defer reply.deinit(std.testing.allocator);
    const comments = [_]comment.Comment{ root, reply };

    const html = try renderSingle(std.testing.allocator, testConfig(), null, item, &comments, 123 + 3600, 0);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<section id=\"comments\" class=\"comments\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<hr class=\"post-comments-divider\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<details class=\"comment-compose\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<summary>add comment</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<button type=\"submit\">add comment</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "2 comments") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "action=\"/post/title-news/comment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Alice &lt;x&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Root &lt;script&gt;<br>\nline") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Reply &amp; ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"comment-children\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"parent_id\" value=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/admin/comment/1/delete") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Root <script>") == null);
    try std.testing.expect(!template.containsPlaceholderToken(html));

    const admin_html = try renderSingle(std.testing.allocator, testConfig(), testViewer("admin", .admin), item, &comments, 123 + 3600, 0);
    defer std.testing.allocator.free(admin_html);
    try std.testing.expect(std.mem.indexOf(u8, admin_html, "data-open-delete-dialog=\"comment-delete-dialog-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_html, "action=\"/admin/comment/1/delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_html, "delete comment?") != null);

    const member_html = try renderSingle(std.testing.allocator, testConfig(), testViewer("member", .member), item, &comments, 123 + 3600, 0);
    defer std.testing.allocator.free(member_html);
    try std.testing.expect(std.mem.indexOf(u8, member_html, "/admin/comment/1/delete") == null);
}

test "render single shows author edit and delete controls" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);

    const other_html = try renderSingle(std.testing.allocator, testConfig(), testViewer("other", .admin), item, &.{}, 123 + 3600, 0);
    defer std.testing.allocator.free(other_html);
    try std.testing.expect(std.mem.indexOf(u8, other_html, "class=\"post-author-actions\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, other_html, "/admin/post/1/delete") == null);

    const author_html = try renderSingle(std.testing.allocator, testConfig(), testViewer("admin", .admin), item, &.{}, 123 + 3600, 0);
    defer std.testing.allocator.free(author_html);

    try std.testing.expect(std.mem.indexOf(u8, author_html, "class=\"post-author-actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "href=\"/admin/post/1/edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "action=\"/admin/post/1/delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "aria-label=\"edit &lt;Title &amp; News&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "aria-label=\"delete &lt;Title &amp; News&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "class=\"post-action-icon post-edit-icon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "class=\"post-action-icon post-delete-icon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "are you sure?") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "data-open-delete-dialog=\"post-delete-dialog-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_html, "data-close-delete-dialog") != null);
    try std.testing.expect(!template.containsPlaceholderToken(author_html));
}

test "render home includes configured brand logo" {
    var cfg = testConfig();
    cfg.site_logo_light = "/statics/evilblog-logo-light.png";
    cfg.site_logo_dark = "/statics/evilblog-logo.png";

    const html = try renderHome(std.testing.allocator, cfg, null, &.{}, 1, 123, 0);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<img class=\"brand-logo theme-logo-light\" src=\"/statics/evilblog-logo-light.png\" alt=\"\" width=\"18\" height=\"18\"><img class=\"brand-logo theme-logo-dark\" src=\"/statics/evilblog-logo.png\" alt=\"\" width=\"18\" height=\"18\"><span class=\"brand-title\">evilblog</span>") != null);
}

test "render home includes default social image metadata" {
    const html = try renderHome(std.testing.allocator, testConfig(), null, &.{}, 1, 123, 0);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<meta property=\"og:site_name\" content=\"evilblog\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta property=\"og:image\" content=\"http://127.0.0.1:8080/statics/og-default.png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta property=\"og:image:type\" content=\"image/png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta property=\"og:image:width\" content=\"1200\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta property=\"og:image:height\" content=\"630\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta name=\"twitter:card\" content=\"summary_large_image\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta name=\"twitter:url\" content=\"http://127.0.0.1:8080/\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta name=\"twitter:image\" content=\"http://127.0.0.1:8080/statics/og-default.png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta name=\"twitter:image:alt\" content=\"evilblog\">") != null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render home includes upvote action and relative post metadata" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);

    const html = try renderHome(std.testing.allocator, testConfig(), null, &.{item}, 1, 123 + 120, 0);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "action=\"/post/title-news/upvote\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"upvote-icon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "3 points by admin 2 minutes ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "(title-news)") == null);
}

test "render donate shows provider button links" {
    const html = try renderDonate(std.testing.allocator, testConfig(), null, 0, "### hi\n\n**builder** <script>");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"donate-title\">Donate</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "If you want to support my projects and Evilblog :)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>standard</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>crypto</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"https://www.paypal.com/donate\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"https://ko-fi.com/\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"bitcoin:\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-button donate-button-paypal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-button donate-button-kofi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-button donate-button-bitcoin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>about me</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-profile-image\" src=\"https://avatars.githubusercontent.com/u/19678157?v=4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h3>hi</h3>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>builder</strong> &lt;script&gt;") != null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}

test "render donate hides providers without configured urls" {
    var cfg = testConfig();
    cfg.donate_paypal_url = "";
    cfg.donate_kofi_url = "   ";
    cfg.donate_bitcoin_url = "";

    const html = try renderDonate(std.testing.allocator, cfg, null, 0, "");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-button donate-button-paypal\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-button donate-button-kofi\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"donate-button donate-button-bitcoin\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>standard</h2>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>crypto</h2>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>about me</h2>") == null);
    try std.testing.expect(!template.containsPlaceholderToken(html));
}
