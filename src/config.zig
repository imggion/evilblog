//! Runtime configuration from `evilblog.zon` plus environment overrides.
//!
//! File config owns site metadata for deploys; env vars stay highest priority
//! for secrets and platform-specific host/port settings.
const std = @import("std");
const logger = @import("logger.zig");

pub const Config = struct {
    blog_host: []const u8,
    blog_port: u16,
    log_level: logger.Level,
    sqlite_path: []const u8,
    redis_host: []const u8,
    redis_port: u16,
    session_secret: []const u8,
    api_gateway_enabled: bool,
    api_token: []const u8,
    site_title: []const u8,
    site_logo: []const u8,
    site_logo_light: []const u8,
    site_logo_dark: []const u8,
    site_base_url: []const u8,
    site_description: []const u8,
    site_default_og_image: []const u8,
    donate_paypal_url: []const u8,
    donate_kofi_url: []const u8,
    donate_bitcoin_url: []const u8,
    donate_about_readme_url: []const u8,
    donate_about_profile_image_url: []const u8,
    footer_text: []const u8,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Config {
        const file_config = try loadFileConfig(allocator, io);
        const blog_host = try envOrDefault(allocator, environ, "BLOG_HOST", "127.0.0.1");
        const blog_port = try envPort(allocator, environ, "BLOG_PORT", 8080);
        const sqlite_path = try envOrDefault(allocator, environ, "SQLITE_PATH", "evilblog.sqlite3");
        const redis_host = try envOrDefault(allocator, environ, "REDIS_HOST", "127.0.0.1");
        const site_title = try envOrFileDefault(allocator, environ, "SITE_TITLE", file_config.site_title, "evilblog");
        const site_logo = try envOrFileDefault(allocator, environ, "SITE_LOGO", file_config.site_logo, "");
        const site_logo_light = try envOrFileDefault(allocator, environ, "SITE_LOGO_LIGHT", file_config.site_logo_light, site_logo);
        const site_logo_dark = try envOrFileDefault(allocator, environ, "SITE_LOGO_DARK", file_config.site_logo_dark, site_logo);

        const default_base = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ blog_host, blog_port });
        const site_base_url = try envOrFileOwnedDefault(allocator, environ, "SITE_BASE_URL", file_config.site_base_url, default_base);
        const default_description = try std.fmt.allocPrint(allocator, "Latest posts from {s}.", .{site_title});
        const site_description = try envOrFileOwnedDefault(allocator, environ, "SITE_DESCRIPTION", file_config.site_description, default_description);
        const default_og_image = try std.fmt.allocPrint(allocator, "{s}/statics/og-default.png", .{site_base_url});
        const site_default_og_image = try envOrFileOwnedDefault(allocator, environ, "SITE_DEFAULT_OG_IMAGE", file_config.site_default_og_image, default_og_image);
        const donate_paypal_url = try envOrFileDefault(allocator, environ, "DONATE_PAYPAL_URL", file_config.donate_paypal_url, "");
        const donate_kofi_url = try envOrFileDefault(allocator, environ, "DONATE_KOFI_URL", file_config.donate_kofi_url, "");
        const donate_bitcoin_url = try envOrFileDefault(allocator, environ, "DONATE_BITCOIN_URL", file_config.donate_bitcoin_url, "");
        const donate_about_readme_url = try envOrFileDefault(allocator, environ, "DONATE_ABOUT_README_URL", file_config.donate_about_readme_url, "");
        const donate_about_profile_image_url = try envOrFileDefault(allocator, environ, "DONATE_ABOUT_PROFILE_IMAGE_URL", file_config.donate_about_profile_image_url, "");
        const default_footer = try std.fmt.allocPrint(allocator, "{s}: small SQLite-backed Zig blog", .{site_title});
        const footer_text = try envOrFileOwnedDefault(allocator, environ, "SITE_FOOTER_TEXT", file_config.footer_text, default_footer);

        return .{
            .blog_host = blog_host,
            .blog_port = blog_port,
            .log_level = file_config.log_level orelse .info,
            .sqlite_path = sqlite_path,
            .redis_host = redis_host,
            .redis_port = try envPort(allocator, environ, "REDIS_PORT", 6379),
            .session_secret = try sessionSecretEnv(allocator, environ),
            .api_gateway_enabled = file_config.api_gateway_enabled orelse false,
            .api_token = try envOrFileDefault(allocator, environ, "API_TOKEN", file_config.api_token, ""),
            .site_title = site_title,
            .site_logo = site_logo,
            .site_logo_light = site_logo_light,
            .site_logo_dark = site_logo_dark,
            .site_base_url = site_base_url,
            .site_description = site_description,
            .site_default_og_image = site_default_og_image,
            .donate_paypal_url = donate_paypal_url,
            .donate_kofi_url = donate_kofi_url,
            .donate_bitcoin_url = donate_bitcoin_url,
            .donate_about_readme_url = donate_about_readme_url,
            .donate_about_profile_image_url = donate_about_profile_image_url,
            .footer_text = footer_text,
        };
    }
};

const FileConfig = struct {
    log_level: ?logger.Level = null,
    site_title: ?[]const u8 = null,
    site_logo: ?[]const u8 = null,
    site_logo_light: ?[]const u8 = null,
    site_logo_dark: ?[]const u8 = null,
    site_base_url: ?[]const u8 = null,
    site_description: ?[]const u8 = null,
    site_default_og_image: ?[]const u8 = null,
    donate_paypal_url: ?[]const u8 = null,
    donate_kofi_url: ?[]const u8 = null,
    donate_bitcoin_url: ?[]const u8 = null,
    donate_about_readme_url: ?[]const u8 = null,
    donate_about_profile_image_url: ?[]const u8 = null,
    footer_text: ?[]const u8 = null,
    api_gateway_enabled: ?bool = null,
    api_token: ?[]const u8 = null,
};

fn loadFileConfig(allocator: std.mem.Allocator, io: std.Io) !FileConfig {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "evilblog.zon",
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
            logger.Logger.init(.info).err("config.parse_failed", "file=evilblog.zon diagnostics=\n{f}", .{diag});
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

fn sessionSecretEnv(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) ![]u8 {
    const value = std.process.Environ.getAlloc(environ, allocator, "SESSION_SECRET") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingRequiredEnv,
        else => |e| return e,
    };
    if (value.len == 0) return error.MissingRequiredEnv;
    if (value.len < 32) return error.SessionSecretTooShort;
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
