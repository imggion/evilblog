// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! Small Markdown subset for post bodies.
//!
//! The database stores the author-written source. This module is the only place
//! that turns that source into HTML, and it emits only hardcoded tags.
const std = @import("std");
const template = @import("template.zig");

const Writer = std.Io.Writer;

const ListKind = enum { unordered, ordered };

const ListItem = struct {
    kind: ListKind,
    text: []const u8,
};

const Heading = struct {
    level: u8,
    text: []const u8,
};

pub fn renderBody(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var paragraph_open = false;
    var current_list: ?ListKind = null;
    var in_code_block = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = stripTrailingCarriageReturn(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (in_code_block) {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                try out.writer.writeAll("</code></pre>\n");
                in_code_block = false;
            } else {
                try template.escapeHtml(&out.writer, line);
                try out.writer.writeByte('\n');
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            try closeParagraph(&out.writer, &paragraph_open);
            try closeList(&out.writer, &current_list);
            try openCodeBlock(&out.writer, std.mem.trim(u8, trimmed[3..], " \t"));
            in_code_block = true;
            continue;
        }

        if (trimmed.len == 0) {
            try closeParagraph(&out.writer, &paragraph_open);
            try closeList(&out.writer, &current_list);
            continue;
        }

        if (parseHeading(trimmed)) |heading| {
            try closeParagraph(&out.writer, &paragraph_open);
            try closeList(&out.writer, &current_list);
            try out.writer.print("<h{d}>", .{heading.level});
            try renderInline(&out.writer, heading.text);
            try out.writer.print("</h{d}>\n", .{heading.level});
            continue;
        }

        if (parseListItem(trimmed)) |item| {
            try closeParagraph(&out.writer, &paragraph_open);
            if (current_list) |kind| {
                if (kind != item.kind) {
                    try closeList(&out.writer, &current_list);
                    try openList(&out.writer, item.kind);
                    current_list = item.kind;
                }
            } else {
                try openList(&out.writer, item.kind);
                current_list = item.kind;
            }

            try out.writer.writeAll("<li>");
            try renderInline(&out.writer, item.text);
            try out.writer.writeAll("</li>\n");
            continue;
        }

        try closeList(&out.writer, &current_list);
        if (paragraph_open) {
            try out.writer.writeAll("<br>\n");
        } else {
            try out.writer.writeAll("<p>");
            paragraph_open = true;
        }
        try renderInline(&out.writer, line);
    }

    if (in_code_block) try out.writer.writeAll("</code></pre>\n");
    try closeParagraph(&out.writer, &paragraph_open);
    try closeList(&out.writer, &current_list);
    return try out.toOwnedSlice();
}

pub fn plainText(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var in_code_block = false;
    var wrote_line = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = stripTrailingCarriageReturn(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code_block = !in_code_block;
            continue;
        }

        if (wrote_line) try out.writer.writeByte('\n');
        const text = if (!in_code_block) block: {
            if (parseHeading(trimmed)) |heading| break :block heading.text;
            if (parseListItem(trimmed)) |item| break :block item.text;
            break :block line;
        } else line;
        try writePlainInline(&out.writer, text);
        wrote_line = true;
    }

    return try out.toOwnedSlice();
}

fn renderInline(writer: *Writer, source: []const u8) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (parseImage(source, index)) |span| {
            if (isSafeImageUrl(span.url)) {
                try writer.writeAll("<img src=\"");
                try template.escapeHtml(writer, std.mem.trim(u8, span.url, " \t\r\n"));
                try writer.writeAll("\" alt=\"");
                try template.escapeHtml(writer, span.label);
                try writer.writeAll("\" loading=\"lazy\" decoding=\"async\">");
            } else {
                try template.escapeHtml(writer, source[index..span.end]);
            }
            index = span.end;
            continue;
        }

        if (parseLink(source, index)) |span| {
            if (isSafeLinkUrl(span.url)) {
                try openLink(writer, span.url);
                if (cleanLinkLabel(span.label, span.url)) |label| {
                    try template.escapeHtml(writer, label);
                } else {
                    try renderInline(writer, span.label);
                }
                try writer.writeAll("</a>");
            } else {
                try renderInline(writer, span.label);
            }
            index = span.end;
            continue;
        }

        if (parseAutoLink(source, index)) |span| {
            try openLink(writer, span.url);
            try template.escapeHtml(writer, span.label);
            try writer.writeAll("</a>");
            index = span.end;
            continue;
        }

        if (std.mem.startsWith(u8, source[index..], "**")) {
            if (findToken(source, index + 2, "**")) |close| {
                if (close > index + 2) {
                    try writer.writeAll("<strong>");
                    try renderInline(writer, source[index + 2 .. close]);
                    try writer.writeAll("</strong>");
                    index = close + 2;
                    continue;
                }
            }
        }

        if (source[index] == '_') {
            if (findToken(source, index + 1, "_")) |close| {
                if (close > index + 1) {
                    try writer.writeAll("<em>");
                    try renderInline(writer, source[index + 1 .. close]);
                    try writer.writeAll("</em>");
                    index = close + 1;
                    continue;
                }
            }
        }

        if (source[index] == '`') {
            if (findToken(source, index + 1, "`")) |close| {
                if (close > index + 1) {
                    try writer.writeAll("<code>");
                    try template.escapeHtml(writer, source[index + 1 .. close]);
                    try writer.writeAll("</code>");
                    index = close + 1;
                    continue;
                }
            }
        }

        try escapeByte(writer, source[index]);
        index += 1;
    }
}

fn writePlainInline(writer: *Writer, source: []const u8) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (parseImage(source, index)) |span| {
            try writePlainInline(writer, span.label);
            index = span.end;
            continue;
        }

        if (parseLink(source, index)) |span| {
            if (cleanLinkLabel(span.label, span.url)) |label| {
                try writer.writeAll(label);
            } else {
                try writePlainInline(writer, span.label);
            }
            index = span.end;
            continue;
        }

        if (parseAutoLink(source, index)) |span| {
            try writer.writeAll(span.label);
            index = span.end;
            continue;
        }

        if (std.mem.startsWith(u8, source[index..], "**")) {
            if (findToken(source, index + 2, "**")) |close| {
                if (close > index + 2) {
                    try writePlainInline(writer, source[index + 2 .. close]);
                    index = close + 2;
                    continue;
                }
            }
        }

        if (source[index] == '_') {
            if (findToken(source, index + 1, "_")) |close| {
                if (close > index + 1) {
                    try writePlainInline(writer, source[index + 1 .. close]);
                    index = close + 1;
                    continue;
                }
            }
        }

        if (source[index] == '`') {
            if (findToken(source, index + 1, "`")) |close| {
                if (close > index + 1) {
                    try writer.writeAll(source[index + 1 .. close]);
                    index = close + 1;
                    continue;
                }
            }
        }

        try writer.writeByte(source[index]);
        index += 1;
    }
}

const LinkSpan = struct {
    label: []const u8,
    url: []const u8,
    end: usize,
};

fn openLink(writer: *Writer, raw_url: []const u8) !void {
    try writer.writeAll("<a href=\"");
    try template.escapeHtml(writer, std.mem.trim(u8, raw_url, " \t\r\n"));
    try writer.writeAll("\" rel=\"noopener noreferrer\">");
}

fn cleanLinkLabel(label: []const u8, raw_url: []const u8) ?[]const u8 {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (!std.mem.eql(u8, label, url)) return null;
    return readableUrlLabel(url);
}

fn parseImage(source: []const u8, index: usize) ?LinkSpan {
    if (!std.mem.startsWith(u8, source[index..], "![")) return null;
    return parseBracketLink(source, index, 2);
}

fn parseLink(source: []const u8, index: usize) ?LinkSpan {
    if (source[index] != '[') return null;
    return parseBracketLink(source, index, 1);
}

fn parseBracketLink(source: []const u8, index: usize, marker_len: usize) ?LinkSpan {
    const label_start = index + marker_len;
    const label_end = std.mem.indexOfPos(u8, source, label_start, "](") orelse return null;
    const url_start = label_end + 2;
    const url_end = std.mem.indexOfScalarPos(u8, source, url_start, ')') orelse return null;
    return .{
        .label = source[label_start..label_end],
        .url = source[url_start..url_end],
        .end = url_end + 1,
    };
}

fn parseAutoLink(source: []const u8, index: usize) ?LinkSpan {
    const prefix_len: usize = if (std.mem.startsWith(u8, source[index..], "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, source[index..], "http://"))
        "http://".len
    else if (std.mem.startsWith(u8, source[index..], "mailto:"))
        "mailto:".len
    else
        return null;

    var end = index + prefix_len;
    while (end < source.len and !isAutoLinkTerminator(source[end])) end += 1;
    while (end > index + prefix_len and isAutoLinkTrailingPunctuation(source[end - 1])) end -= 1;
    if (end <= index + prefix_len) return null;

    const url = source[index..end];
    if (!isSafeLinkUrl(url)) return null;
    return .{
        .label = readableUrlLabel(url),
        .url = url,
        .end = end,
    };
}

fn readableUrlLabel(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "https://")) return url["https://".len..];
    if (std.mem.startsWith(u8, url, "http://")) return url["http://".len..];
    if (std.mem.startsWith(u8, url, "mailto:")) return url["mailto:".len..];
    return url;
}

fn findToken(source: []const u8, start: usize, token: []const u8) ?usize {
    return std.mem.indexOfPos(u8, source, start, token);
}

fn parseHeading(trimmed_line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < 3 and level < trimmed_line.len and trimmed_line[level] == '#') level += 1;
    if (level == 0 or level >= trimmed_line.len) return null;
    if (trimmed_line[level] != ' ') return null;

    const text = std.mem.trim(u8, trimmed_line[level + 1 ..], " \t");
    if (text.len == 0) return null;
    return .{ .level = level, .text = text };
}

fn parseListItem(trimmed_line: []const u8) ?ListItem {
    if (std.mem.startsWith(u8, trimmed_line, "- ")) {
        return .{ .kind = .unordered, .text = trimmed_line[2..] };
    }

    var index: usize = 0;
    while (index < trimmed_line.len and isAsciiDigit(trimmed_line[index])) index += 1;
    if (index == 0 or index + 1 >= trimmed_line.len) return null;
    if (trimmed_line[index] != '.' or trimmed_line[index + 1] != ' ') return null;
    return .{ .kind = .ordered, .text = trimmed_line[index + 2 ..] };
}

fn openList(writer: *Writer, kind: ListKind) !void {
    try writer.writeAll(if (kind == .unordered) "<ul>\n" else "<ol>\n");
}

fn closeList(writer: *Writer, current_list: *?ListKind) !void {
    if (current_list.*) |kind| {
        try writer.writeAll(if (kind == .unordered) "</ul>\n" else "</ol>\n");
        current_list.* = null;
    }
}

fn closeParagraph(writer: *Writer, paragraph_open: *bool) !void {
    if (paragraph_open.*) {
        try writer.writeAll("</p>\n");
        paragraph_open.* = false;
    }
}

fn openCodeBlock(writer: *Writer, language: []const u8) !void {
    try writer.writeAll("<pre class=\"code-block\"><code");
    if (isSafeLanguageName(language)) {
        try writer.writeAll(" class=\"language-");
        try writer.writeAll(language);
        try writer.writeAll("\"");
    }
    try writer.writeAll(">");
}

fn isSafeLinkUrl(raw_url: []const u8) bool {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return false;
    if (hasUnsafeUrlByte(url)) return false;
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "mailto:")) return true;
    if (std.mem.startsWith(u8, url, "#")) return true;
    return std.mem.startsWith(u8, url, "/") and !std.mem.startsWith(u8, url, "//");
}

fn isSafeImageUrl(raw_url: []const u8) bool {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return false;
    if (hasUnsafeUrlByte(url)) return false;
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    return std.mem.startsWith(u8, url, "/statics/");
}

fn hasUnsafeUrlByte(url: []const u8) bool {
    for (url) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return true;
        if (byte == '"' or byte == '\'' or byte == '<' or byte == '>') return true;
    }
    return false;
}

fn isAutoLinkTerminator(byte: u8) bool {
    return byte <= 0x20 or byte == 0x7f or byte == '<' or byte == '>' or byte == '"' or byte == '\'';
}

fn isAutoLinkTrailingPunctuation(byte: u8) bool {
    return byte == '.' or byte == ',' or byte == ';' or byte == ':' or byte == '!' or byte == '?' or byte == ')';
}

fn isSafeLanguageName(language: []const u8) bool {
    if (language.len == 0) return false;
    for (language) |byte| {
        if (isAsciiAlphaNumeric(byte) or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

fn isAsciiAlphaNumeric(byte: u8) bool {
    return isAsciiDigit(byte) or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn isAsciiDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn escapeByte(writer: *Writer, byte: u8) !void {
    switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    }
}

test "plain text keeps legacy line breaks as br and escapes raw html" {
    const html = try renderBody(std.testing.allocator, "line <one>\nline & two");
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<p>line &lt;one&gt;<br>\nline &amp; two</p>\n", html);
}

test "inline markdown renders only hardcoded safe tags" {
    const html = try renderBody(std.testing.allocator, "**bold** _em_ `code <x>` [link](/post/a) ![alt](/statics/a.png)");
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<p><strong>bold</strong> <em>em</em> <code>code &lt;x&gt;</code> <a href=\"/post/a\" rel=\"noopener noreferrer\">link</a> <img src=\"/statics/a.png\" alt=\"alt\" loading=\"lazy\" decoding=\"async\"></p>\n", html);
}

test "headings render as body headings" {
    const html = try renderBody(std.testing.allocator,
        \\# One
        \\## Two
        \\### Three
    );
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<h1>One</h1>\n<h2>Two</h2>\n<h3>Three</h3>\n", html);
}

test "bare http and mailto links become readable active links" {
    const html = try renderBody(std.testing.allocator, "See https://example.com/docs, [https://openai.com](https://openai.com), and mailto:hello@example.com.");
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<p>See <a href=\"https://example.com/docs\" rel=\"noopener noreferrer\">example.com/docs</a>, <a href=\"https://openai.com\" rel=\"noopener noreferrer\">openai.com</a>, and <a href=\"mailto:hello@example.com\" rel=\"noopener noreferrer\">hello@example.com</a>.</p>\n", html);
}

test "unsafe urls do not become active links or images" {
    const html = try renderBody(std.testing.allocator, "[bad](javascript:alert(1)) ![bad](/public/a.png) <script>x</script>");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;x&lt;/script&gt;") != null);
}

test "code fences preserve whitespace and language class" {
    const html = try renderBody(std.testing.allocator,
        \\```zig
        \\const x = "<tag>";
        \\  return x;
        \\```
    );
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<pre class=\"code-block\"><code class=\"language-zig\">const x = &quot;&lt;tag&gt;&quot;;\n  return x;\n</code></pre>\n", html);
}

test "lists render as explicit list tags" {
    const html = try renderBody(std.testing.allocator,
        \\- **one**
        \\- two
        \\
        \\1. first
        \\2. second
    );
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<ul>\n<li><strong>one</strong></li>\n<li>two</li>\n</ul>\n<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n", html);
}

test "plain text removes markdown wrappers for descriptions" {
    const text = try plainText(std.testing.allocator, "## Hello **bold** [site](https://example.com)\n![image alt](/statics/a.png)\nhttps://example.com/docs");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Hello bold site\nimage alt\nexample.com/docs", text);
}
