# Mutable DWT + Progress Reporting

**Date:** 2026-04-01
**Status:** Approved
**Scope:** Encoder performance (memory), web UI progress feedback

## Problem

The Haskell encoder cannot process real-world photos. A 3.1MB JPEG (roughly 2500x2000, 5MP) decompresses to ~15MB of raw pixels. The immutable Vector-based DWT in `Wavelet.hs` allocates a new Vector for every lifting step — per row, per column, per level, per channel. On a 5MP image this creates thousands of intermediate Vectors totaling 20GB+ of memory, causing the server process to balloon and stall indefinitely.

The web UI also provides no feedback during encoding — just a static spinner.

## Goals

1. Make the encoder complete on real-world photos (5MP+) without excessive memory usage
2. Show encoding progress in the web UI with stage labels and a progress bar

## Non-Goals

- Speed optimization (getting it fast is a separate effort — this is about getting it to finish)
- Changing the `.sgl` output format (the mutable DWT must produce bit-identical output)
- Modifying the Rust decoder
- Tiling or strip-based processing

---

## Part 1: Mutable DWT

### Approach

Create a new module `Sigil.Codec.WaveletMut` that implements the same 5/3 Le Gall lifting transform using `Data.Vector.Unboxed.Mutable` inside the `ST` monad.

### Key Decisions

- **Keep `Wavelet.hs` unchanged.** It remains the readable reference implementation. The mutable version is a performance-equivalent replacement used by the pipeline.
- **Use `Data.Vector.Unboxed` (not boxed `Data.Vector`).** Unboxed Int32 vectors store values contiguously without pointer indirection — critical for large images.
- **Run in `ST` monad.** Pure interface (`runST`), mutable internals. No `IO` needed for the transform itself.
- **One temporary buffer per transform dimension.** Row transforms share one buffer, column transforms share another. Each buffer is allocated once and reused across rows/columns.

### Module API

```haskell
module Sigil.Codec.WaveletMut
  ( dwt2DForwardMut
  , dwt2DInverseMut
  , dwtForwardMultiMut
  , dwtInverseMultiMut
  ) where

-- | Forward 2D DWT using mutable arrays.
-- Same semantics as dwt2DForward but O(n) memory.
dwt2DForwardMut :: Int -> Int -> VU.Vector Int32
                -> (VU.Vector Int32, VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)

-- | Inverse 2D DWT using mutable arrays.
dwt2DInverseMut :: Int -> Int -> (VU.Vector Int32, VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)
                -> VU.Vector Int32

-- | Forward multi-level DWT using mutable arrays.
dwtForwardMultiMut :: Int -> Int -> Int -> VU.Vector Int32
                   -> (VU.Vector Int32, [(VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)])

-- | Inverse multi-level DWT using mutable arrays.
dwtInverseMultiMut :: Int -> Int -> Int -> VU.Vector Int32
                   -> [(VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)]
                   -> VU.Vector Int32
```

### Algorithm (Forward 2D, single level)

1. **Allocate** a mutable output buffer of size `w * h` (Int32).
2. **Row transforms:** For each row y in [0..h-1]:
   - Read the row from the input into a temporary row buffer (size w).
   - Perform the 5/3 predict step in-place: `d[i] = row[2i+1] - (row[2i] + row[2i+2]) / 2`
   - Perform the 5/3 update step in-place: `a[i] = row[2i] + (d[i-1] + d[i] + 2) / 4`
   - Write low-pass coefficients to columns [0..wLow-1] of row y in the output buffer.
   - Write high-pass coefficients to columns [wLow..w-1] of row y in the output buffer.
3. **Column transforms:** For each column x in [0..w-1]:
   - Read the column from the output buffer into a temporary column buffer (size h).
   - Perform the same predict/update steps.
   - Write low-pass to rows [0..hLow-1], high-pass to rows [hLow..h-1] of the column in the output buffer.
4. **Extract subbands:** Slice the output buffer into LL, LH, HL, HH regions and freeze into immutable Unboxed Vectors.

### Memory Budget

For a 2500x2000 RGB image:
- Input: 3 channels x 5M x 4 bytes = 60MB
- Output buffer: 5M x 4 bytes = 20MB (reused per channel)
- Row temp buffer: 2500 x 4 bytes = 10KB
- Column temp buffer: 2000 x 4 bytes = 8KB
- **Total: ~80MB** (vs 20GB+ with immutable Vectors)

### Pipeline Integration

`Pipeline.hs` changes:
- Import `WaveletMut` instead of `Wavelet` for the forward/inverse DWT calls
- Convert between boxed `Vector` (used by rest of pipeline) and unboxed `VU.Vector` (used by DWT) at the boundary
- `computeLevels` stays in `Wavelet.hs` (pure arithmetic, no allocation issue)

Over time, the rest of the pipeline (RCT, serialize, deinterleave) can also migrate to unboxed vectors, but that's out of scope here.

---

## Part 2: Progress Reporting

### Architecture

```
Frontend                    Server
--------                    ------
EventSource(/api/progress)  -->  SSE endpoint (TChan)
                                      |
POST /api/encode            -->  encode handler
                                      |
                                 compress(callback)
                                      |
                              callback writes to TChan
                                      |
                            <--  SSE pushes events
```

### Protocol

The frontend opens an SSE connection to `/api/progress` before uploading. The server creates a `TChan` for that session. The encode handler calls `compress` with a progress callback. The callback writes JSON events to the `TChan`. The SSE endpoint reads from the `TChan` and sends them as SSE `data:` lines.

### Event Format

```json
{"stage": "decoding",        "pct": 0}
{"stage": "color_transform", "pct": 10}
{"stage": "dwt",             "pct": 15, "detail": "channel 1/3, level 1/4"}
{"stage": "dwt",             "pct": 35, "detail": "channel 1/3, level 4/4"}
{"stage": "dwt",             "pct": 55, "detail": "channel 2/3, level 1/4"}
{"stage": "dwt",             "pct": 75, "detail": "channel 3/3, level 4/4"}
{"stage": "serialize",       "pct": 80}
{"stage": "compress",        "pct": 90}
{"stage": "done",            "pct": 100}
```

The DWT stage spans pct 15-80 (65% of the bar) since it's the bottleneck. Progress within DWT is distributed evenly across channels and levels.

### Progress Callback Type

```haskell
type ProgressCallback = Text -> Int -> Maybe Text -> IO ()
--                      stage   pct   detail (optional)
```

For the CLI, the callback prints to stderr:
```
[decoding]        0%
[color_transform] 10%
[dwt]             15%  channel 1/3, level 1/4
...
```

For pure/non-IO contexts, the callback is `\_ _ _ -> pure ()` (no-op).

### Server Changes

- New SSE endpoint: `GET /api/progress/:sessionId` — creates a `TChan` keyed by `sessionId`, returns SSE stream
- Modified encode endpoint: accepts a `X-Session-Id` header, looks up the `TChan`, passes progress callback to `compress`
- Session ID: generated client-side as a random UUID before each encode. The frontend opens `EventSource('/api/progress/' + sessionId)`, then sends `POST /api/encode` with header `X-Session-Id: <sessionId>`.
- Session management: a simple `TVar (Map SessionId (TChan Text))` — sessions are created on SSE connect and cleaned up when the SSE connection closes or after a 5-minute timeout

### Frontend Changes

- Replace the static spinner with a progress bar (thin accent-colored bar) and a stage label
- On file drop: open `EventSource('/api/progress')`, then `POST /api/encode`
- On each SSE message: update bar width to `pct%`, update label to stage name + detail
- On `"done"` or fetch completion: close EventSource, show results as before
- Fallback: if SSE fails to connect, fall back to the current spinner behavior

### UI Design

```
[===================>          ] 55%
DWT -- channel 2/3, level 1/4
```

Styled to match existing UI: accent color bar, dim text label, JetBrains Mono for the percentage.

---

## Part 3: Testing

### Correctness (Mutable DWT)

1. **QuickCheck equivalence:** For arbitrary images up to 64x64, `dwtForwardMultiMut` produces the same subbands as `dwtForwardMulti` (after converting between boxed/unboxed).
2. **Golden file conformance:** Re-encode the entire golden corpus with the new pipeline. Output `.sgl` files must be byte-identical to existing ones.
3. **Sample photo round-trip:** Encode the 3.1MB JPEG (`sample photos/`), decode with Rust decoder, verify pixel-exact match.

### Memory (Mutable DWT)

4. **Completion test:** Encode the sample photo via CLI and confirm it completes without error.
5. **Memory check:** Run with `+RTS -s` and confirm peak memory stays under 200MB.

### Progress Reporting

6. **Manual web UI test:** Drop the sample photo, confirm the progress bar advances through all stages and the label updates.
7. **SSE endpoint test:** `curl` the SSE endpoint during an encode and verify events arrive in order with increasing pct values.

### Unchanged

- Existing 44 Haskell tests remain and must pass
- Rust conformance tests remain and must pass (format unchanged)

---

## Files Changed

| File | Change |
|------|--------|
| `Sigil/Codec/WaveletMut.hs` | **New** — mutable DWT implementation |
| `Sigil/Codec/Pipeline.hs` | Switch DWT calls to mutable versions, add progress callback |
| `server/Main.hs` | Add SSE endpoint, session management, wire progress callback |
| `static/index.html` | Replace spinner with progress bar + stage label, add SSE client |
| `test/Test/WaveletMut.hs` | **New** — QuickCheck equivalence tests |
| `package.yaml` | Add `vector` (unboxed) dependency if not already present |

## Files Unchanged

| File | Reason |
|------|--------|
| `Sigil/Codec/Wavelet.hs` | Kept as readable reference |
| `sigil-rs/` | Format unchanged, decoder unaffected |
| `Sigil/Codec/Serialize.hs` | No changes needed |
| `Sigil/IO/Reader.hs`, `Writer.hs` | No changes needed |
