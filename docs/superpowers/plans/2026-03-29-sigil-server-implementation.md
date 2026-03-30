# Sigil Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Scotty HTTP server to sigil-hs that accepts image uploads and returns `.sgl` encoded bytes, enabling a web demo.

**Architecture:** New `sigil-server` executable in the existing `sigil-hs` package. Scotty handles HTTP, calls the sigil-hs library directly for in-memory encoding. Serves static files from `sigil-hs/static/` for the frontend (added later). CORS enabled for cross-origin requests.

**Tech Stack:** Haskell, Stack (lts-22.43), Scotty, wai-cors, JuicyPixels, sigil-hs library

**Spec:** `docs/superpowers/specs/2026-03-29-sigil-server-design.md`

---

## File Structure

```
sigil-hs/
├── app/
│   ├── Main.hs        -- existing CLI (unchanged)
│   └── Server.hs      -- NEW: Scotty HTTP server
├── src/Sigil/IO/
│   └── Convert.hs     -- MODIFIED: export dynamicToSigil
├── src/Sigil.hs        -- MODIFIED: re-exports dynamicToSigil via Convert
├── package.yaml        -- MODIFIED: add sigil-server executable + deps
└── static/             -- NEW: placeholder directory for frontend
    └── index.html      -- NEW: minimal placeholder page
```

---

### Task 1: Export `dynamicToSigil` from the Library

**Files:**
- Modify: `sigil-hs/src/Sigil/IO/Convert.hs`

The server needs to decode image bytes in-memory using JuicyPixels and convert to Sigil types. The `dynamicToSigil` function already exists in `Convert.hs` but isn't exported.

- [ ] **Step 1: Add `dynamicToSigil` to the export list**

In `sigil-hs/src/Sigil/IO/Convert.hs`, change the module header from:

```haskell
module Sigil.IO.Convert
  ( loadImage
  , saveImage
  , imageToSigil
  , sigilToImage
  ) where
```

to:

```haskell
module Sigil.IO.Convert
  ( loadImage
  , saveImage
  , imageToSigil
  , sigilToImage
  , dynamicToSigil
  ) where
```

- [ ] **Step 2: Verify build**

```bash
cd sigil-hs && stack build
```

Expected: compiles with no errors.

- [ ] **Step 3: Verify tests still pass**

```bash
stack test
```

Expected: 44 examples, 0 failures.

- [ ] **Step 4: Commit**

```bash
cd /Users/dennis/programming\ projects/imgcompressor
git add sigil-hs/src/Sigil/IO/Convert.hs
git commit -m "feat(sigil-hs): export dynamicToSigil from Convert module"
```

---

### Task 2: Add Server Dependencies and Executable Target

**Files:**
- Modify: `sigil-hs/package.yaml`

- [ ] **Step 1: Add the sigil-server executable to package.yaml**

Add this block after the existing `executables:` section's `sigil-hs:` entry (at the same indentation level as `sigil-hs:`):

```yaml
  sigil-server:
    source-dirs: app
    main: Server.hs
    dependencies:
      - sigil-hs
      - scotty >= 0.22
      - wai-cors
      - wai-extra
      - wai
      - http-types
      - bytestring
      - JuicyPixels >= 3.3
      - text
```

- [ ] **Step 2: Create a minimal stub Server.hs**

Create `sigil-hs/app/Server.hs`:

```haskell
module Main where

main :: IO ()
main = putStrLn "sigil-server: not yet implemented"
```

- [ ] **Step 3: Verify build**

```bash
cd sigil-hs && stack build
```

Expected: compiles. Stack will download scotty, wai-cors, wai-extra, http-types. This may take a few minutes the first time.

- [ ] **Step 4: Verify the server stub runs**

```bash
stack run sigil-server
```

Expected: prints `sigil-server: not yet implemented`

- [ ] **Step 5: Commit**

```bash
cd /Users/dennis/programming\ projects/imgcompressor
git add sigil-hs/package.yaml sigil-hs/app/Server.hs sigil-hs/sigil-hs.cabal
git commit -m "feat(sigil-hs): add sigil-server executable target with Scotty deps"
```

---

### Task 3: Implement the Server

**Files:**
- Modify: `sigil-hs/app/Server.hs`
- Create: `sigil-hs/static/index.html`

- [ ] **Step 1: Create static directory with placeholder**

Create `sigil-hs/static/index.html`:

```html
<!DOCTYPE html>
<html>
<head><title>Sigil</title></head>
<body><h1>Sigil Image Codec</h1><p>Demo coming soon.</p></body>
</html>
```

- [ ] **Step 2: Implement the full server**

Replace `sigil-hs/app/Server.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Network.Wai.Middleware.Cors (simpleCors)
import Network.Wai.Middleware.Static (staticPolicy, addBase)
import Network.HTTP.Types.Status (status400)

import qualified Codec.Picture as JP
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL

import Sigil.Core.Types
import Sigil.IO.Convert (dynamicToSigil)
import Sigil.IO.Writer (encodeSigilFile)

import System.Environment (lookupEnv)
import Text.Read (readMaybe)

main :: IO ()
main = do
  port <- maybe 3000 id . (>>= readMaybe) <$> lookupEnv "PORT"
  putStrLn $ "sigil-server starting on port " ++ show port
  scotty port $ do
    middleware simpleCors
    middleware $ staticPolicy (addBase "static")

    get "/health" $ do
      text "ok"

    post "/api/encode" $ do
      body' <- body
      case JP.decodeImage (BL.toStrict body') of
        Left err -> do
          status status400
          text (TL.pack $ "Failed to decode image: " ++ err)
        Right dynImg ->
          case dynamicToSigil dynImg of
            Left err -> do
              status status400
              text (TL.pack $ "Failed to convert image: " ++ show err)
            Right (hdr, img) -> do
              let sglBytes = encodeSigilFile hdr emptyMetadata img
                  originalSize = rowBytes hdr * fromIntegral (height hdr)
                  compressedSize = fromIntegral (BL.length sglBytes) :: Int
                  ratio = fromIntegral originalSize / fromIntegral compressedSize :: Double
              setHeader "Content-Type" "application/octet-stream"
              setHeader "X-Sigil-Width" (TL.pack $ show $ width hdr)
              setHeader "X-Sigil-Height" (TL.pack $ show $ height hdr)
              setHeader "X-Sigil-Color-Space" (TL.pack $ show $ colorSpace hdr)
              setHeader "X-Sigil-Original-Size" (TL.pack $ show originalSize)
              setHeader "X-Sigil-Compressed-Size" (TL.pack $ show compressedSize)
              setHeader "X-Sigil-Ratio" (TL.pack $ show ratio)
              raw sglBytes
```

- [ ] **Step 3: Build**

```bash
cd sigil-hs && stack build
```

Expected: compiles with no errors.

- [ ] **Step 4: Start the server**

```bash
stack run sigil-server &
```

Expected: prints `sigil-server starting on port 3000`

- [ ] **Step 5: Test health endpoint**

```bash
curl http://localhost:3000/health
```

Expected: `ok`

- [ ] **Step 6: Test encode endpoint**

```bash
curl -X POST --data-binary @../tests/corpus/gradient_256x256.png \
  -H "Content-Type: image/png" \
  http://localhost:3000/api/encode -o /tmp/test_server.sgl -v 2>&1 | grep "X-Sigil"
```

Expected: response headers showing dimensions, sizes, and ratio. The `/tmp/test_server.sgl` file should be valid.

- [ ] **Step 7: Verify the .sgl file is valid**

```bash
stack run sigil-hs -- info /tmp/test_server.sgl
```

Expected: prints dimensions (256x256), RGB, Depth8, PAdaptive.

- [ ] **Step 8: Test static file serving**

```bash
curl http://localhost:3000/index.html
```

Expected: the HTML placeholder content.

- [ ] **Step 9: Stop the background server**

```bash
kill %1
```

- [ ] **Step 10: Commit**

```bash
cd /Users/dennis/programming\ projects/imgcompressor
git add sigil-hs/app/Server.hs sigil-hs/static/index.html
git commit -m "feat(sigil-hs): Scotty HTTP server with /api/encode endpoint"
```

---

### Task 4: Verify Round-Trip with sigil-hs CLI

**Files:** None (verification only)

- [ ] **Step 1: Start server, encode, then decode with CLI**

```bash
cd sigil-hs
stack run sigil-server &
sleep 2

# Encode via server
curl -s -X POST --data-binary @../tests/corpus/checkerboard_64x64.png \
  -H "Content-Type: image/png" \
  http://localhost:3000/api/encode -o /tmp/checkerboard_server.sgl

# Decode with CLI
stack run sigil-hs -- decode /tmp/checkerboard_server.sgl -o /tmp/checkerboard_decoded.png

# Verify round-trip
stack run sigil-hs -- verify ../tests/corpus/checkerboard_64x64.png

kill %1
```

Expected: decode succeeds, verify prints PASS.

- [ ] **Step 2: Test all corpus images**

```bash
cd sigil-hs
stack run sigil-server &
sleep 2

for img in ../tests/corpus/*.png; do
  name=$(basename "$img" .png)
  curl -s -X POST --data-binary @"$img" \
    -H "Content-Type: image/png" \
    http://localhost:3000/api/encode -o "/tmp/${name}_server.sgl"
  echo "$name: $(stat -f%z "/tmp/${name}_server.sgl") bytes"
done

kill %1
```

Expected: all 4 images encode successfully with reasonable file sizes.

- [ ] **Step 3: Commit verification results**

```bash
cd /Users/dennis/programming\ projects/imgcompressor
git add -A && git commit -m "chore: verify sigil-server round-trip with all corpus images"
```
