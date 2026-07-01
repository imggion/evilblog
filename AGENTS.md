# Repository Guidelines

## Quick Context

evilblog is a single-package Zig 0.16 blog engine inspired by Hacker News/Lamer
News. It uses `std.http.Server` with `std.Io.net`, explicit route branching in
`src/router.zig`, SQLite as the authoritative store, optional Redis caching, and
structured logging through `src/logger.zig`. Server-rendered HTML is assembled
from embedded files in `src/templates/`. CSS and tiny browser scripts live in
`src/templates/styles/` and `src/templates/scripts/`. Public assets, including
the default social image, are served from `statics/`; donation buttons are
rendered as CSS-only links, with an optional README-backed about section fetched
from `donate_about_readme_url` and an optional profile image from
`donate_about_profile_image_url`.
Redis host/port live in `evilblog.zon`; `REDIS_USERNAME`/`REDIS_PASSWORD` are
environment-only credentials, with `REDIS_HOST`/`REDIS_PORT` available as runtime
overrides.

Anonymous post comments are stored in SQLite through `src/comment.zig` and
rendered server-side under each post. Replies are represented by `parent_id` and
displayed as nested comment lists.

Viewer roles live in `src/auth.zig` as `admin` and `member`. Users are stored in
SQLite through `src/user.zig`. On first startup with an empty `users` table, the
app creates an `admin` user with a random generated password, stores only its
Argon2id hash, prints the one-time password to the console, and forces a password
change before admin routes can be used. `SESSION_SECRET` is required for signed
session cookies; Zig does not load `.env` files by itself.

Post bodies are stored as a restricted Markdown source in SQLite and rendered by
`src/markdown.zig`. Do not store raw HTML in posts; the renderer escapes
user-controlled text and emits only its small whitelist of hardcoded tags.

Optional agent post creation lives in `src/api.zig` behind `POST /api/posts`.
It is exposed only when `api_gateway_enabled` is true in `evilblog.zon`, requires
`Authorization: Bearer <api_token>`, accepts JSON post source, and writes through
`post.Store.save()` without changing storage or rendering paths.

There is no Next.js, React, Vue, Node, Bun, client state library, ORM, or CSS
framework in this repository. Keep future work aligned with the existing direct
Zig style.

## Documentation Map

- [agents-files/README.md](agents-files/README.md): what these agent docs are
  for and when to update them.
- [agents-files/project-structure.md](agents-files/project-structure.md): stack,
  boot flow, package boundaries, and commands.
- [agents-files/file-tree.md](agents-files/file-tree.md): high-signal tree for
  navigation.
- [agents-files/where-things-live.md](agents-files/where-things-live.md): where
  routes, templates, assets, config, tests, and services belong.
- [agents-files/code-patterns.md](agents-files/code-patterns.md): repo-specific
  coding patterns and readability rules.

## Core Commands

Use the local `rtk` prefix for shell commands.

- `rtk zig fmt build.zig build.zig.zon evilblog.zon src/*.zig` formats Zig and
  ZON files.
- `rtk zig build test` runs package and executable tests.
- `rtk zig build` builds the application.
- `rtk zig build -Dversion=1.2.3-test` overrides the generated app version for
  release or CI builds.
- `rtk make build-all` builds versioned ReleaseSmall Linux and Windows binaries
  into `dist/`; use `BUILD_ALL_VERSION=v1.2.3` to override the tag-derived name.
- `rtk make docker-build VERSION=1.2.3` builds Docker image `evilblog:1.2.3`
  and passes the same value to `-Dversion`.
- `rtk make up` starts Docker Compose with Redis, tags the image from Git, and
  lets `build.zig` derive the app version unless `VERSION=v1.2.3` is passed.
- `rtk docker compose --env-file .env.prod up --build` starts Evilblog and Redis
  together; compose overrides `REDIS_HOST=redis` for the app container.
- `rtk env SESSION_SECRET=0123456789abcdef0123456789abcdef zig build run` starts
  the server on `http://127.0.0.1:8080`.
- `rtk make debug`, `rtk make release`, `rtk make build-all`, `rtk make test`,
  and `rtk make serve` are Makefile aliases around Zig commands.

## CI Workflows

GitHub Actions live in `.github/workflows/` and Forgejo Actions live in
`.forgejo/workflows/`. Both use one workflow per supported release target:
Linux x86_64, Linux aarch64, Linux armv7, Windows x86_64, and Windows x86.
GitHub workflows use `ubuntu-latest`; Forgejo workflows use the local `docker`
runner label. The Linux x86_64 workflow also runs
`zig fmt --check` and `zig build test`; all workflows cross-build with
`-Doptimize=ReleaseSmall` and `-Dversion=0.0.0-ci`.

## Working Rules

Prefer maintainable, explicit, human-readable code. Keep routes explicit, keep
post storage in `src/post.zig`, keep comment storage in `src/comment.zig`, keep
SQLite setup and migrations in `src/db.zig`, keep auth in `src/auth.zig`, keep
user storage and password hashing in `src/user.zig`, keep RSS in `src/rss.zig`,
and keep restricted post-body Markdown rendering in `src/markdown.zig`. Keep
static markup/CSS/JS in `src/templates/` unless the current pattern no longer fits.
Admin draft listing and draft-form hydration should stay in the explicit
`/admin/drafts` and `/admin/draft/:id` routes.
The optional agent API should stay in `src/api.zig`, with `src/router.zig` doing
only the explicit `/api/posts` branch and feature flag check.
Published post editing should reuse the same admin form through
`/admin/post/:id/edit`, and post deletion should stay behind authenticated
author checks in `/admin/post/:id/delete`. Comment deletion should stay admin-only
through `/admin/comment/:id/delete`.
Build-time app versioning is generated in `build.zig` from `-Dversion`, Git
tags, or commit metadata, then exposed through `build_options.version`.
Keep app logs structured through `src/logger.zig`; do not log request bodies,
cookies, passwords, session tokens, or full form payloads.

DRY repeated behavior when it clarifies ownership, but do not introduce generic
framework-like abstractions for one-off flows. Avoid nested ternaries, clever
control flow, giant multi-purpose files, duplicated parsing/rendering logic, and
new folder patterns that the repository does not already use.

## Documentation Maintenance

Update `AGENTS.md` and the relevant `agents-files/` page whenever commands,
entrypoints, routing, storage/cache behavior, templates, assets, config, or test
strategy change. If something is uncertain, document it as uncertain instead of
inventing a convention.
