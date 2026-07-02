// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! RSS rendering for the public published-post feed.
//!
//! This stays separate from HTML rendering because feed output has a different
//! document contract even though both share the same escaping rules.
const std = @import("std");
const Config = @import("config.zig").Config;
const markdown = @import("markdown.zig");
const post = @import("post.zig");
const html = @import("html.zig");

pub fn render(allocator: std.mem.Allocator, cfg: Config, posts: []const post.Post) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<rss version="2.0"><channel>
        \\<title>
    );
    try escapeXml(&out.writer, cfg.site_title);
    try out.writer.writeAll("</title><link>");
    try escapeXml(&out.writer, cfg.site_base_url);
    try out.writer.writeAll("</link><description>");
    try escapeXml(&out.writer, cfg.site_title);
    try out.writer.writeAll("</description>\n");

    for (posts) |item| {
        try out.writer.writeAll("<item><title>");
        try escapeXml(&out.writer, item.title);
        try out.writer.writeAll("</title><link>");
        try escapeXml(&out.writer, cfg.site_base_url);
        try out.writer.writeAll("/post/");
        try escapeXml(&out.writer, item.slug);
        try out.writer.writeAll("</link><guid>");
        try escapeXml(&out.writer, cfg.site_base_url);
        try out.writer.writeAll("/post/");
        try escapeXml(&out.writer, item.slug);
        try out.writer.writeAll("</guid><description>");
        const description = try markdown.plainText(allocator, item.body);
        defer allocator.free(description);
        try escapeXml(&out.writer, description);
        try out.writer.writeAll("</description></item>\n");
    }

    try out.writer.writeAll("</channel></rss>\n");
    return try out.toOwnedSlice();
}

fn escapeXml(writer: *std.Io.Writer, text: []const u8) !void {
    // The feed only needs XML's active characters escaped, so the HTML escaper
    // gives a stricter compatible subset without another implementation.
    try html.escapeHtml(writer, text);
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
        .donate_paypal_url = "",
        .donate_kofi_url = "",
        .donate_bitcoin_url = "",
        .donate_about_readme_url = "",
        .donate_about_profile_image_url = "",
        .footer_text = "evilblog",
    };
}

fn testPost(allocator: std.mem.Allocator) !post.Post {
    return .{
        .id = try allocator.dupe(u8, "1"),
        .title = try allocator.dupe(u8, "RSS"),
        .slug = try allocator.dupe(u8, "rss"),
        .body = try allocator.dupe(u8, "Hello **bold** [site](https://example.com) <tag>"),
        .excerpt = try allocator.dupe(u8, ""),
        .og_image = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, "123"),
        .updated_at = try allocator.dupe(u8, "124"),
        .author = try allocator.dupe(u8, "admin"),
        .points = try allocator.dupe(u8, "0"),
        .status = try allocator.dupe(u8, "published"),
        .tags = try allocator.dupe(u8, ""),
    };
}

test "rss descriptions use markdown plain text" {
    var item = try testPost(std.testing.allocator);
    defer item.deinit(std.testing.allocator);

    const xml = try render(std.testing.allocator, testConfig(), &.{item});
    defer std.testing.allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "Hello bold site &lt;tag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "**bold**") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "href=") == null);
}
