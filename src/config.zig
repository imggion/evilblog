//! Runtime configuration from `easynews.zon` plus environment overrides.
//!
//! File config owns site metadata for deploys; env vars stay highest priority
//! for secrets and platform-specific host/port settings.
const std = @import("std");

pub const Config = struct {
    blog_host: []const u8,
    blog_port: u16,
    redis_host: []const u8,
    redis_port: u16,
    admin_user: ?[]const u8,
    admin_password: ?[]const u8,
    site_title: []const u8,
    site_base_url: []const u8,
    site_description: []const u8,
    site_default_og_image: []const u8,
    footer_text: []const u8,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Config {
        const file_config = try loadFileConfig(allocator, io);
        const blog_host = try envOrDefault(allocator, environ, "BLOG_HOST", "127.0.0.1");
        const blog_port = try envPort(allocator, environ, "BLOG_PORT", 8080);
        const redis_host = try envOrDefault(allocator, environ, "REDIS_HOST", "127.0.0.1");
        const site_title = try envOrFileDefault(allocator, environ, "SITE_TITLE", file_config.site_title, "easynews");

        const default_base = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ blog_host, blog_port });
        const site_base_url = try envOrFileOwnedDefault(allocator, environ, "SITE_BASE_URL", file_config.site_base_url, default_base);
        const default_description = try std.fmt.allocPrint(allocator, "Latest posts from {s}.", .{site_title});
        const site_description = try envOrFileOwnedDefault(allocator, environ, "SITE_DESCRIPTION", file_config.site_description, default_description);
        const default_og_image = try std.fmt.allocPrint(allocator, "{s}/static/og-default.png", .{site_base_url});
        const site_default_og_image = try envOrFileOwnedDefault(allocator, environ, "SITE_DEFAULT_OG_IMAGE", file_config.site_default_og_image, default_og_image);
        const default_footer = try std.fmt.allocPrint(allocator, "{s}: small Redis-backed Zig blog", .{site_title});
        const footer_text = try envOrFileOwnedDefault(allocator, environ, "SITE_FOOTER_TEXT", file_config.footer_text, default_footer);

        return .{
            .blog_host = blog_host,
            .blog_port = blog_port,
            .redis_host = redis_host,
            .redis_port = try envPort(allocator, environ, "REDIS_PORT", 6379),
            .admin_user = try optionalEnv(allocator, environ, "ADMIN_USER"),
            .admin_password = try optionalEnv(allocator, environ, "ADMIN_PASSWORD"),
            .site_title = site_title,
            .site_base_url = site_base_url,
            .site_description = site_description,
            .site_default_og_image = site_default_og_image,
            .footer_text = footer_text,
        };
    }

    pub fn adminConfigured(self: Config) bool {
        return self.admin_user != null and self.admin_password != null;
    }
};

const FileConfig = struct {
    site_title: ?[]const u8 = null,
    site_base_url: ?[]const u8 = null,
    site_description: ?[]const u8 = null,
    site_default_og_image: ?[]const u8 = null,
    footer_text: ?[]const u8 = null,
};

fn loadFileConfig(allocator: std.mem.Allocator, io: std.Io) !FileConfig {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "easynews.zon",
        allocator,
        .limited(64 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);
    return std.zon.parse.fromSliceAlloc(FileConfig, allocator, source, &diag, .{
        // Config files can safely carry fields from newer versions of the app.
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.ParseZon => {
            std.log.err("failed to parse easynews.zon:\n{f}", .{diag});
            return err;
        },
        else => |e| return e,
    };
}

fn envOrDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    return std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, default_value),
        else => |e| return e,
    };
}

fn envOrFileDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    file_value: ?[]const u8,
    default_value: []const u8,
) ![]const u8 {
    return std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => file_value orelse try allocator.dupe(u8, default_value),
        else => |e| return e,
    };
}

fn envOrFileOwnedDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    file_value: ?[]const u8,
    default_value: []u8,
) ![]const u8 {
    // Computed defaults are already owned; keep that allocation only when no
    // environment or file value replaces it.
    return std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => file_value orelse default_value,
        else => |e| return e,
    };
}

fn optionalEnv(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
) !?[]u8 {
    const value = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => |e| return e,
    };
    if (value.len == 0) return null;
    return value;
}

fn envPort(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    default_value: u16,
) !u16 {
    const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return default_value,
        else => |e| return e,
    };
    return std.fmt.parseInt(u16, raw, 10);
}
