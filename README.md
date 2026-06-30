<p align="center">
  <img src="statics/evilblog-logo.png" alt="Evilblog logo" width="96">
</p>

<h1 align="center">Evilblog</h1>

<p align="center">
  A tiny dependency-free Zig blog engine.
</p>

## What It Is

Evilblog is a small blog engine written in Zig 0.16.

It is inspired by [Lamer News](https://github.com/antirez/lamernews), the blog/news engine by Salvatore Sanfilippo, [@antirez](https://github.com/antirez).

The extra idea is agent-friendly writing: posts are plain Markdown, routes are explicit, and the project structure is documented so an agent can be delegated to draft or write a blog post without needing a JavaScript stack.

## Design

- No package-manager dependencies: `build.zig.zon` has `.dependencies = .{}`.
- SQLite is vendored and compiled into the executable.
- Redis is optional and used only as a best-effort cache.
- HTML is rendered server-side.
- CSS and small browser scripts are embedded at build time.
- Post bodies are stored as restricted Markdown, not raw HTML.
- The app runs as a single native binary.

On macOS the release binary still links Apple's system runtime (`/usr/lib/libSystem.B.dylib`). SQLite is not a runtime dependency because it is compiled in from `vendor/sqlite`.

## Features

- Public post list and single post pages.
- Admin-only post creation and editing.
- Drafts.
- Anonymous comments with nested replies.
- RSS feed.
- Upvotes for signed-in users.
- Optional Redis cache.
- Donate page with optional README-backed `about me` section.
- Built-in social metadata and default Open Graph image.

## Real Local Measurement

Measured on Apple Silicon macOS with Zig 0.16.0 using:

```sh
zig build -Doptimize=ReleaseSmall
```

Then the server was started with a temporary SQLite database and hit once on `/`, `/rss`, and `/donate`.

| Metric | Result |
| --- | ---: |
| Binary size | 16,030,200 bytes, about 15.3 MiB |
| Idle RSS | 13,360 KiB, about 13.0 MiB |
| RSS after `/`, `/rss`, `/donate` | 13,360 KiB, about 13.0 MiB |
| Dynamic links on macOS | `/usr/lib/libSystem.B.dylib` |

This is a small idle sample, not a load test.

## Requirements

- Zig 0.16.0
- `SESSION_SECRET` with at least 32 bytes
- Redis only if you want cache

Zig does not load `.env` files by itself. Export environment variables or prefix the run command.

## Build

```sh
zig build test
zig build -Doptimize=ReleaseSmall
```

The binary is written to:

```sh
./zig-out/bin/evilblog
```

For a faster optimized build instead of the smallest one:

```sh
zig build -Doptimize=ReleaseFast
```

## Run

Generate a session secret:

```sh
openssl rand -hex 32
```

Start the server:

```sh
SESSION_SECRET=0123456789abcdef0123456789abcdef zig build run
```

Open:

```text
http://127.0.0.1:8080
```

On first startup with an empty users table, Evilblog creates an `admin` user, prints a one-time password to the console, and forces a password change before admin routes can be used.

## Configuration

Most public settings live in `evilblog.zon`:

```zig
.{
    .log_level = .info,
    .site_title = "evilblog",
    .site_logo_light = "/statics/evilblog-logo-light.png",
    .site_logo_dark = "/statics/evilblog-logo.png",
    .site_base_url = "https://example.com",

    .donate_paypal_url = "https://www.paypal.com/donate",
    .donate_kofi_url = "https://ko-fi.com/example",
    .donate_bitcoin_url = "bitcoin:bc1qexample",
    .donate_about_readme_url = "https://raw.githubusercontent.com/user/user/refs/heads/main/README.md",
    .donate_about_profile_image_url = "https://avatars.githubusercontent.com/u/19678157?v=4",

    .footer_text = "evilblog",
}
```

Useful environment variables:

- `BLOG_HOST`, default `127.0.0.1`
- `BLOG_PORT`, default `8080`
- `SQLITE_PATH`, default `evilblog.sqlite3`
- `REDIS_HOST`, default `127.0.0.1`
- `REDIS_PORT`, default `6379`
- `SESSION_SECRET`, required
- `SITE_BASE_URL`, used for canonical URLs, RSS, and social metadata

## Redis

Redis is optional. Without Redis, Evilblog reads and writes through SQLite.

Run Redis locally with Docker:

```sh
docker run --rm -d --name evilblog-redis -p 6379:6379 redis:7-alpine
```

Stop it:

```sh
docker stop evilblog-redis
```

## Markdown

Posts are written in a small safe Markdown subset:

- paragraphs and line breaks
- `#`, `##`, `###` headings
- `**bold**`, `_italic_`, and inline code
- links and bare URLs
- images by URL
- fenced code blocks
- simple ordered and unordered lists

Raw HTML is escaped.
