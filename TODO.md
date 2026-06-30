## Fatto

- API agenti implementata in `src/api.zig`.
- `POST /api/posts` è esposto solo con `api_gateway_enabled = true`.
- Auth via `Authorization: Bearer <api_token>`.
- Scrive con `post.Store.save()` senza toccare DB, schema, Markdown, cache o HTML.
