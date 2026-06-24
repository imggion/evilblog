# easynews

easynews is a small Zig 0.16.0 blog engine inspired by Lamer News and Hacker News. It renders server-side HTML, stores posts in Redis, and intentionally keeps the code direct enough to read end-to-end.

## Routes

- `GET /` lists published posts.
- `GET /post/:slug` shows one post.
- `GET /latest/:page` shows the paginated archive.
- `GET /rss` emits an RSS feed.
- `GET /signin` shows the signin form.
- `POST /signin` creates a signed session cookie.
- `POST /signout` clears the signed session cookie.
- `GET /admin` shows the session-protected post form.
- `POST /admin/post` creates or updates a post when the session token is valid.

## Run Redis

With Docker:

```sh
docker run --rm -d --name easynews-redis -p 6379:6379 redis:7-alpine
```

Stop it when you are done:

```sh
docker stop easynews-redis
```

Or with a local Redis install:

```sh
redis-server
```

## Run the app

`zig build run` starts only the Zig web app. Redis must already be running,
because the homepage reads the published post list from Redis.

```sh
zig build
ADMIN_USER=admin ADMIN_PASSWORD=secret zig build run
```

Then open `http://127.0.0.1:8080`.

On a fresh Redis database the homepage is valid but empty. Create the first
post by clicking `signin`, using the credentials from `ADMIN_USER` and
`ADMIN_PASSWORD`, and then submitting the protected post form.

Signin uses an `HttpOnly` session cookie containing a signed token. Direct
requests to `POST /admin/post` fail with `401 Unauthorized` unless that token is
present and valid.

## Environment

Application-facing settings can be edited in `easynews.zon`:

```zig
.{
    .site_title = "easynews",
    .site_base_url = "https://example.com",
    .footer_text = "easynews: small Redis-backed Zig blog",
}
```

`site_base_url` is the public domain used for RSS links, canonical URLs, and
social metadata. The file is parsed with Zig's standard `std.zon` parser, so no
YAML or external config dependency is needed.

Environment variables still work and override `easynews.zon` when present:

- `BLOG_HOST`, default `127.0.0.1`
- `BLOG_PORT`, default `8080`
- `REDIS_HOST`, default `127.0.0.1`
- `REDIS_PORT`, default `6379`
- `ADMIN_USER`, required for admin access
- `ADMIN_PASSWORD`, required for admin access
- `SITE_TITLE`, default `easynews`
- `SITE_BASE_URL`, default `http://BLOG_HOST:BLOG_PORT`
- `SITE_DESCRIPTION`, default `Latest posts from SITE_TITLE.`
- `SITE_DEFAULT_OG_IMAGE`, default `SITE_BASE_URL/static/og-default.png`
- `SITE_FOOTER_TEXT`, default `SITE_TITLE: small Redis-backed Zig blog`

`BLOG_HOST` and `REDIS_HOST` are currently expected to be IP literals, such as `127.0.0.1`.

## SEO and social metadata

HTML pages include canonical URLs, meta descriptions, Open Graph tags, and
Twitter card tags. `SITE_BASE_URL` must be the public production URL for
canonical and social URLs to be correct.

The global social image comes from `SITE_DEFAULT_OG_IMAGE`. If you keep the
default `/static/og-default.png` path, serve that asset from nginx or set the
env var to an absolute image URL.

Posts also store optional `excerpt` and `og_image` fields. If `excerpt` is
blank, easynews generates a short description from the body. If `og_image` is
blank, the global `SITE_DEFAULT_OG_IMAGE` is used.

## Notes

The Redis client is a tiny RESP client that implements only the commands this app uses. It opens short-lived TCP connections per command, which is simple and fine for the MVP behind nginx. A production version would likely add connection reuse, stronger date formatting, CSRF protection, tag pages, and a richer edit workflow.
