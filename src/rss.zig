//! RSS rendering for the public published-post feed.
//!
//! This stays separate from HTML rendering because feed output has a different
//! document contract even though both share the same escaping rules.
const std = @import("std");
const Config = @import("config.zig").Config;
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
        try escapeXml(&out.writer, item.body);
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
