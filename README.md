<p align="center">
  <img src="public/android-chrome-192x192.png" alt="Evilblog logo" width="96">
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
- ReleaseSmall binaries produced by `make build-all` are under 5 MB each.

SQLite is not a runtime dependency because it is compiled in from `vendor/sqlite`.

## Features

- Public post list and single post pages.
- Admin-only post creation and editing.
- Drafts.
- Anonymous comments with nested replies.
- RSS feed.
- Upvotes for signed-in users.
- Optional Redis cache.
- Optional token-authenticated post creation API for agents.
- Donate page with optional README-backed `about me` section.
- Built-in social metadata and default Open Graph image.

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

Build release binaries for Linux and Windows:

```sh
make build-all
```

`make build-all` uses `ReleaseSmall` by default and writes:

- `dist/evilblog-v0.1.0-linux-x86_64`
- `dist/evilblog-v0.1.0-linux-aarch64`
- `dist/evilblog-v0.1.0-linux-armv7`
- `dist/evilblog-v0.1.0-windows-x86_64.exe`
- `dist/evilblog-v0.1.0-windows-x86.exe`

It gets the version from the latest `v*` Git tag. Override version or
optimization if needed:

```sh
make build-all BUILD_ALL_VERSION=v0.1.0 BUILD_ALL_OPTIMIZE=ReleaseFast
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

## Docker Compose

Create the production env file from the example and set real secrets:

```sh
cp .env.prod.example .env.prod
```

Start Evilblog with Redis:

```sh
make up
```

`make up` tags the Docker image with the current Git version. If `VERSION` is
not set, the binary version is computed by `build.zig` from Git tags and commit
metadata. Pin a specific version with:

```sh
make up VERSION=v0.1.0
```

The compose file overrides `REDIS_HOST=redis` so the app reaches Redis on the
Docker network. Keep `REDIS_USERNAME` and `REDIS_PASSWORD` in `.env.prod`; leave
both empty for an unauthenticated Redis.

## Configuration

Most public settings live in `evilblog.zon`:

```zig
.{
    .log_level = .info,
    .site_title = "evilblog",
    .site_logo_light = "/statics/evilblog-logo-light.png",
    .site_logo_dark = "/statics/evilblog-logo.png",
    .site_base_url = "https://example.com",
    .redis_host = "127.0.0.1",
    .redis_port = 6379,

    .api_gateway_enabled = false,
    .api_token = "",

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
- `REDIS_HOST`, optional override for `redis_host` in `evilblog.zon`
- `REDIS_PORT`, optional override for `redis_port` in `evilblog.zon`
- `REDIS_USERNAME`, optional Redis ACL username
- `REDIS_PASSWORD`, optional Redis password
- `SESSION_SECRET`, required
- `API_TOKEN`, optional override for the agent post API token
- `SITE_BASE_URL`, used for canonical URLs, RSS, and social metadata

## Agent Post API

Enable the API in `evilblog.zon` and set a token:

```zig
.api_gateway_enabled = true,
.api_token = "replace-with-a-long-random-token",
```

Then agents can read, create, and update posts using:

```http
Authorization: Bearer <api_token>
```

Endpoints:

```http
GET /api/posts
POST /api/posts
PATCH /api/posts/<id>
```

Create request body:

```json
{
  "title": "Post title",
  "body": "Post body in Markdown",
  "excerpt": "Optional meta description",
  "og_image": "/statics/og-default.png",
  "tags": "zig,sqlite",
  "status": "draft"
}
```

`PATCH /api/posts/<id>` accepts any subset of `title`, `slug`, `body`, `excerpt`, `og_image`, `tags`, and `status`.

## Hermes Skill

This repository includes a Hermes skill under `skills/` for delegating blog post creation and updates to an agent.

To install it, give Hermes this repository and tell it:

```text
Read the skill in this repository under /skills and install it into yourself.
```

After installing the skill, configure Hermes with `EVILBLOG_API_KEY` and `EVILBLOG_API_URL` in its environment. The key must match `api_token` in `evilblog.zon` or the `API_TOKEN` environment variable used by Evilblog.

## Redis

Redis is optional. Without Redis, Evilblog reads and writes through SQLite.
Set the cache endpoint in `evilblog.zon`:

```zig
.redis_host = "127.0.0.1",
.redis_port = 6379,
```

If Redis requires authentication, keep credentials out of the file and set
`REDIS_USERNAME`/`REDIS_PASSWORD` in the environment. `REDIS_HOST` and
`REDIS_PORT` can still override the file values at runtime.

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
