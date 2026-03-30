# Sigil Server — Design Spec

**Date**: 2026-03-29
**Scope**: Scotty HTTP server for encoding images to `.sgl` format
**Part of**: Sigil web demo (backend component)

---

## 1. Purpose

Add an HTTP API server (`sigil-server`) to the `sigil-hs` package that accepts image uploads and returns `.sgl` encoded bytes. This enables a web demo where users can compress images using the Sigil codec from their browser.

---

## 2. Architecture

A new executable target in `sigil-hs/package.yaml` — separate from the existing `sigil-hs` CLI. The server uses Scotty (minimal Haskell web framework) and calls the existing `sigil-hs` library functions directly (no subprocess spawning).

```
Browser → POST /api/encode (image bytes) → Scotty handler
  → loadImage (JuicyPixels decode) → compress (Sigil pipeline) → encodeSigilFile
  → Response: .sgl bytes + metadata headers
```

Also serves static files from `sigil-hs/static/` for the frontend (added later).

---

## 3. API

### `POST /api/encode`

**Request:**
- Body: raw image bytes (PNG, JPEG, BMP)
- Content-Type: `image/png`, `image/jpeg`, or `application/octet-stream`

**Response (success):**
- Status: 200
- Content-Type: `application/octet-stream`
- Body: `.sgl` file bytes
- Headers:
  - `X-Sigil-Width`: image width
  - `X-Sigil-Height`: image height
  - `X-Sigil-Color-Space`: color space (e.g., "RGB")
  - `X-Sigil-Original-Size`: raw pixel data size in bytes
  - `X-Sigil-Compressed-Size`: .sgl file size in bytes
  - `X-Sigil-Ratio`: compression ratio (e.g., "2.48")

**Response (error):**
- Status: 400
- Content-Type: `text/plain`
- Body: error message

### `GET /` (and other static paths)

Serves files from `sigil-hs/static/`. Falls through to a 404 if file not found.

### `GET /health`

Returns 200 with body "ok". For deploy platform health checks.

---

## 4. File Changes

**New file:**
- `sigil-hs/app/Server.hs` — the Scotty server

**Modified files:**
- `sigil-hs/package.yaml` — add `sigil-server` executable target + scotty/wai-cors deps

**New directory:**
- `sigil-hs/static/` — placeholder for frontend files (added later)

---

## 5. Dependencies

Added to `sigil-hs/package.yaml`:

| Package | Purpose |
|---|---|
| `scotty` | Web framework |
| `wai-cors` | CORS middleware |
| `wai-extra` | Static file serving |
| `http-types` | HTTP status/header types |

These are only in the `sigil-server` executable's dependencies, not the library.

---

## 6. Server Implementation

The handler flow:

1. Read request body as lazy ByteString
2. Decode image with JuicyPixels (`JP.decodeImage`)
3. Convert to Sigil types (`dynamicToSigil` from Convert module — currently not exported, needs to be exposed)
4. Encode to `.sgl` (`encodeSigilFile`)
5. Set response headers with metadata
6. Return `.sgl` bytes

Error handling: JuicyPixels decode failure → 400. Empty body → 400.

---

## 7. CORS

Allow all origins during development. The `wai-cors` middleware handles preflight OPTIONS requests automatically.

---

## 8. Port

Default port 3000, configurable via `PORT` environment variable (standard for deploy platforms).

---

## 9. Testing

Manual testing with curl:

```bash
# Encode a PNG
curl -X POST --data-binary @tests/corpus/gradient_256x256.png \
  -H "Content-Type: image/png" \
  http://localhost:3000/api/encode -o test.sgl

# Verify the .sgl
sigil-hs info test.sgl

# Health check
curl http://localhost:3000/health
```

---

## 10. What Needs to Be Exposed from the Library

Currently `Sigil.IO.Convert` exports `loadImage` (file-based) but not the in-memory conversion functions. The server needs:

- `dynamicToSigil :: DynamicImage -> Either SigilError (Header, Image)` — already exists but not exported
- Need to expose it from `Sigil.IO.Convert` and re-export from `Sigil`

Alternatively, since `JP.decodeImage` returns `Either String DynamicImage` from raw bytes, we need a function like:

```haskell
decodeImageBytes :: BL.ByteString -> Either SigilError (Header, Image)
```

This wraps `JP.decodeImage` + `dynamicToSigil`.
