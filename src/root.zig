//! Public import surface for tests and for any future embedding.
//!
//! The executable imports concrete modules directly; this root exists to keep
//! package-level tests compiling every module through one stable entry point.
pub const auth = @import("auth.zig");
pub const config = @import("config.zig");
pub const html = @import("html.zig");
pub const post = @import("post.zig");
pub const redis = @import("redis.zig");
pub const router = @import("router.zig");
pub const rss = @import("rss.zig");

const template = @import("template.zig");

test {
    _ = auth;
    _ = config;
    _ = html;
    _ = post;
    _ = redis;
    _ = router;
    _ = rss;
    _ = template;
}
