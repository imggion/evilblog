<p align="center">
  <img src="public/android-chrome-192x192.png" alt="Evilblog logo" width="96">
</p>

<h1 align="center">Evilblog</h1>

<p align="center">
  A tiny dependency-free Zig blog engine.
</p>

## Contents

- [What It Is](#what-it-is)
- [Design](#design)
- [Features](#features)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [Build](#build)
- [Production Docker Compose](#production-docker-compose)
- [Production Bare Metal](#production-bare-metal)
- [Configuration](#configuration)
- [Agent Post API](#agent-post-api)
- [Hermes Skill](#hermes-skill)
- [Markdown](#markdown)

## What It Is

Evilblog is a small blog engine written in Zig 0.16.0

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
- ReleaseSmall binaries are under 5 MB each.

SQLite is not a runtime dependency because it is compiled in from `vendor/sqlite`.

## Features

- Public post list and single post pages.
- Admin-only post creation and editing.
- Drafts.
- Anonymous comments with nested replies.
- RSS feed.
- Upvotes for signed-in users.
- Optional Redis cache.
- Optional token-authenticated post API for agents.
- Donate page with optional README-backed `about me` section.
- Built-in social metadata and default Open Graph image.

## Requirements

- Zig 0.16.0
- `SESSION_SECRET` with at least 32 bytes
- Redis only if you want cache

Zig does not load `.env` files by itself. Export environment variables, prefix the run command, or use Docker Compose with `.env.prod`.

## Contributing

Run tests:

```sh
zig build test
```

Generate a local development session secret:

```sh
make session-secret
```

Start the development server:

```sh
SESSION_SECRET=0123456789abcdef0123456789abcdef zig build run
```

Open:

```text
http://127.0.0.1:8080
```

On first startup with an empty users table, Evilblog creates an `admin` user, prints a one-time password to the console, and forces a password change before admin routes can be used.

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

## Production Docker Compose

Create the production env file from the example and set real secrets:

```sh
cp .env.prod.example .env.prod
```

Generate `SESSION_SECRET` with `make session-secret` and put it in `.env.prod`.

Start Evilblog and Redis:

```sh
make up
```

`make up` tags the Docker image with the current Git version.

To run the same stack behind Traefik (HTTP → HTTPS with Let's Encrypt) instead of
exposing Evilblog directly:

```sh
TRAEFIK_HOST=blog.example.com LETSENCRYPT_EMAIL=admin@example.com docker compose --env-file .env.prod -f docker-compose.traefik.yml up --build
```

`docker-compose.traefik.yml` starts Traefik with:
- HTTP on `TRAEFIK_HTTP_PORT` (default `80`), redirecting to HTTPS.
- HTTPS on `TRAEFIK_HTTPS_PORT` (default `443`) with a Let's Encrypt certificate
  for the `TRAEFIK_HOST`. Set `LETSENCRYPT_EMAIL` to receive expiry notices.
- Evilblog's app port is internal to the Docker network; only Traefik is exposed.

The compose file overrides `REDIS_HOST=redis` so the app reaches Redis on the
Docker network. Keep `REDIS_USERNAME` and `REDIS_PASSWORD` in `.env.prod`; leave
both empty for an unauthenticated Redis.

## Production Bare Metal

Build the binary or download it from the release page:

```sh
zig build -Doptimize=ReleaseSmall
```

Run the compiled binary from wherever you install it:

```sh
SESSION_SECRET=<VALUE> ./zig-out/bin/evilblog
```

For an installed copy, use its real path:

```sh
SESSION_SECRET=<VALUE> /opt/evilblog/evilblog
```

By default, SQLite is stored at `evilblog.sqlite3` in the working directory. Set
`SQLITE_PATH` if you want the database somewhere else.

Redis is optional. To use it, set `redis_host` and `redis_port` in `evilblog.zon`,
or override them at runtime with `REDIS_HOST` and `REDIS_PORT`. If Redis requires
auth, set `REDIS_USERNAME` and `REDIS_PASSWORD` in the environment.

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

## License

MIT. See [LICENSE.md](LICENSE.md).
