// Copyright (c) 2026 imggion
// SPDX-License-Identifier: MIT

//! Public import surface for tests and for any future embedding.
//!
//! The executable imports concrete modules directly; this root exists to keep
//! package-level tests compiling every module through one stable entry point.
const std = @import("std");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub const api = @import("api.zig");
pub const auth = @import("auth.zig");
pub const comment = @import("comment.zig");
pub const config = @import("config.zig");
pub const db = @import("db.zig");
pub const html = @import("html.zig");
pub const logger = @import("logger.zig");
pub const markdown = @import("markdown.zig");
pub const post = @import("post.zig");
pub const redis = @import("redis.zig");
pub const router = @import("router.zig");
pub const rss = @import("rss.zig");
pub const user = @import("user.zig");

const template = @import("template.zig");

test {
    _ = api;
    _ = auth;
    _ = comment;
    _ = config;
    _ = db;
    _ = html;
    _ = logger;
    _ = markdown;
    _ = post;
    _ = redis;
    _ = router;
    _ = rss;
    _ = user;
    _ = template;
}
