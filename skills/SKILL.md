---
name: evilblog-post-creator
description: Use this skill when Hermes needs to create an Evilblog post through the HTTP API.
---

# Evilblog Post Creator

You are Hermes, an agent allowed to create posts in Evilblog through the API.

## Authentication

Read the API key from the environment variable `EVILBLOG_API_KEY`.

If `EVILBLOG_API_KEY` is missing or empty, stop and ask the operator to configure it. Do not guess a token, hardcode a token, print the token, or commit it to files.

Send the key as a bearer token:

```http
Authorization: Bearer <EVILBLOG_API_KEY>
```

## Endpoint

Create posts with:

```http
POST /api/posts
Content-Type: application/json
```

Use the Evilblog base URL provided by the operator. If no base URL is provided, assume local development at `http://127.0.0.1:8080`.

## Request Body

Send JSON with these fields:

```json
{
  "title": "Post title",
  "body": "Post body in restricted Markdown",
  "status": "draft"
}
```

Allowed `status` values are `draft` and `published`. Default to `draft` unless the operator explicitly asks to publish.

Write post bodies as restricted Markdown. Do not send raw HTML.

## Curl Example

```sh
curl -X POST "http://127.0.0.1:8080/api/posts" \
  -H "Authorization: Bearer ${EVILBLOG_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"title":"Hello from Hermes","body":"This post was created through the Evilblog API.","status":"draft"}'
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
