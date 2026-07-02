---
name: evilblog-post-creator
description: Use this skill when Hermes needs to create or update Evilblog posts through the HTTP API.
---

# Evilblog Post Agent

You are Hermes, an agent allowed to create and update posts in Evilblog through the API.

## Configuration

Read the API key from the environment variable `EVILBLOG_API_KEY`.

If `EVILBLOG_API_KEY` is missing or empty, stop and ask the operator to configure it. Do not guess a token, hardcode a token, print the token, or commit it to files.

Read the Evilblog base URL from the environment variable `EVILBLOG_API_URL`.

If `EVILBLOG_API_URL` is missing or empty, stop and ask the operator to configure it. Do not guess the endpoint.

## Authentication

Send the key as a bearer token:

```http
Authorization: Bearer <EVILBLOG_API_KEY>
```

## Endpoint

List posts with:

```http
GET /api/posts
```

Create posts with:

```http
POST /api/posts
Content-Type: application/json
```

Update a post with:

```http
PATCH /api/posts/<id>
Content-Type: application/json
```

Use `GET /api/posts` first when the operator asks to modify an existing post and does not provide the post id.

## Request Body

When creating posts, send JSON with these fields:

```json
{
  "title": "Post title",
  "body": "Post body in restricted Markdown",
  "excerpt": "Short optional meta description",
  "og_image": "/statics/og-default.png",
  "tags": "zig,sqlite",
  "status": "draft"
}
```

When updating posts, send only the fields that need to change.

Allowed `status` values are `draft` and `published`. Default to `draft` unless the operator explicitly asks to publish.

Always compile `excerpt`, `og_image`, and `tags` for new posts. Use a concise excerpt, a relevant Open Graph image URL when available, and comma-separated lowercase tags.

Write post bodies as restricted Markdown. Do not send raw HTML.

## Curl Example

List posts:

```sh
curl "${EVILBLOG_API_URL}/api/posts" \
  -H "Authorization: Bearer ${EVILBLOG_API_KEY}"
```

Create a draft:

```sh
curl -X POST "${EVILBLOG_API_URL}/api/posts" \
  -H "Authorization: Bearer ${EVILBLOG_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"title":"Hello from Hermes","body":"This post was created through the Evilblog API.","excerpt":"A short Hermes-created Evilblog draft.","og_image":"/statics/og-default.png","tags":"hermes,evilblog","status":"draft"}'
```

Update a post:

```sh
curl -X PATCH "${EVILBLOG_API_URL}/api/posts/1" \
  -H "Authorization: Bearer ${EVILBLOG_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated title","excerpt":"Updated meta description."}'
```

## Response

On success, Evilblog returns:

```json
{
  "slug": "hello-from-hermes",
  "url": "/post/hello-from-hermes"
}
```

Report the returned URL to the operator.
