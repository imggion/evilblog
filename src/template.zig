//! Tiny placeholder renderer for embedded HTML fragments.
//!
//! The renderer is deliberately limited: templates cannot branch or loop, so
//! control flow stays in Zig where ownership and escaping are explicit.
const std = @import("std");

const Writer = std.Io.Writer;

pub const Binding = struct {
    name: []const u8,
    value: []const u8,
};

pub fn render(writer: *Writer, source: []const u8, bindings: []const Binding) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "{{")) |open| {
        try writer.writeAll(source[cursor..open]);

        const raw = open + 2 < source.len and source[open + 2] == '{';
        const open_len: usize = if (raw) 3 else 2;
        const close_pattern: []const u8 = if (raw) "}}}" else "}}";
        const name_start = open + open_len;
        const close = std.mem.indexOfPos(u8, source, name_start, close_pattern) orelse return error.MalformedTemplate;
        const name = std.mem.trim(u8, source[name_start..close], " \t\r\n");
        const value = findBinding(bindings, name) orelse return error.UnknownPlaceholder;

        if (raw) {
            // Triple braces are reserved for fragments produced by Zig code;
            // user-controlled values should stay on the escaped path.
            try writer.writeAll(value);
        } else {
            try escapeHtml(writer, value);
        }
        cursor = close + close_pattern.len;
    }
    try writer.writeAll(source[cursor..]);
}

pub fn renderAlloc(allocator: std.mem.Allocator, source: []const u8, bindings: []const Binding) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try render(&out.writer, source, bindings);
    return try out.toOwnedSlice();
}

pub fn escapeHtml(writer: *Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

pub fn containsPlaceholderToken(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "{{") != null;
}

fn findBinding(bindings: []const Binding, name: []const u8) ?[]const u8 {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding.value;
    }
    return null;
}

test "template renders escaped and raw placeholders" {
    const html = try renderAlloc(std.testing.allocator, "<p>{{title}}</p><div>{{{body}}}</div>", &.{
        .{ .name = "title", .value = "<Hello & Zig>" },
        .{ .name = "body", .value = "<strong>raw</strong>" },
    });
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings("<p>&lt;Hello &amp; Zig&gt;</p><div><strong>raw</strong></div>", html);
}

test "template rejects unknown placeholders" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.UnknownPlaceholder, render(&out.writer, "{{missing}}", &.{}));
}
