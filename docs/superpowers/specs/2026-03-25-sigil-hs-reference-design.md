# Sigil Haskell Reference Implementation — Design Spec

**Date**: 2026-03-25
**Scope**: Phase 1 — Haskell reference implementation with CLI, benchmarks, and conformance corpus
**Parent spec**: `spec.md` (Sigil v0.2 full specification)

---

## 1. Project Structure

Monorepo with a single Haskell cabal package. The Rust production codec will be added later alongside it.

```
sigil/
├── sigil-hs/
│   ├── sigil-hs.cabal
│   ├── src/
│   │   └── Sigil/
│   │       ├── Core/
│   │       │   ├── Types.hs        -- Header, ColorSpace, BitDepth, Image
│   │       │   ├── Chunk.hs        -- Chunk, Tag, CRC32 verification
│   │       │   └── Error.hs        -- SigilError ADT
│   │       ├── Codec/
│   │       │   ├── Predict.hs      -- PredictorId, all 6 predictors, adaptive selection
│   │       │   ├── ZigZag.hs       -- zigzag/unzigzag
│   │       │   ├── Token.hs        -- Token ADT, tokenize/untokenize
│   │       │   ├── Rice.hs         -- BitWriter/BitReader, Rice-Golomb, optimal k
│   │       │   └── Pipeline.hs     -- Stage newtype, Category instance, composed pipelines
│   │       ├── IO/
│   │       │   ├── Reader.hs       -- .sgl file parser (chunks from ByteString)
│   │       │   ├── Writer.hs       -- .sgl file serializer
│   │       │   └── Convert.hs      -- JuicyPixels PNG/JPEG <-> Sigil Image
│   │       └── Sigil.hs            -- top-level re-exports: compress, decompress
│   ├── app/
│   │   └── Main.hs                 -- CLI: encode/decode/info/verify/bench
│   ├── test/
│   │   ├── Spec.hs                 -- test runner
│   │   ├── Test/
│   │   │   ├── Predict.hs          -- QuickCheck properties for predictors
│   │   │   ├── ZigZag.hs           -- round-trip properties
│   │   │   ├── Rice.hs             -- round-trip properties
│   │   │   ├── Token.hs            -- tokenize/untokenize round-trip
│   │   │   ├── Pipeline.hs         -- full compress/decompress round-trip
│   │   │   └── Conformance.hs      -- golden tests against corpus
│   │   └── Gen.hs                  -- QuickCheck generators (arbitrary images, headers)
│   └── bench/
│       └── Main.hs                 -- criterion benchmarks
├── tests/
│   └── corpus/                     -- shared test images (raw + expected .sgl)
│       └── expected/               -- golden .sgl files
└── spec.md                         -- Sigil v0.2 full specification
```

**Build tool**: Stack (hpack). `package.yaml` defines the project in YAML; Stack auto-generates the `.cabal` file. `stack.yaml` pins the Stackage resolver for reproducible builds (important for conformance — both Haskell and Rust must produce byte-identical `.sgl` files).

Components:
- `library` — all `Sigil.*` modules
- `executable sigil-hs` — the CLI
- `test-suite sigil-hs-test` — QuickCheck + conformance tests
- `benchmark sigil-hs-bench` — criterion benchmarks

**Dependencies**:
- `bytestring` — binary data
- `vector` — contiguous arrays for Image storage
- `JuicyPixels` — PNG/JPEG decode/encode
- `optparse-applicative` — CLI argument parsing
- `QuickCheck` + `hspec` — property tests + test runner
- `criterion` — statistical micro-benchmarking
- `binary` — `Data.Binary.Get` / `Data.Binary.Put` for chunk serialization
- Hand-rolled CRC32 via `Data.Bits` — standard CRC32 (ISO 3309, same as PNG), not CRC32C

---

## 2. Core Types & Image Representation

### Image storage

Images are stored as `Vector Row` — a vector of rows, where each row is a flat `Vector Word8` of interleaved channel samples. For an RGB 3x2 image, the structure is:

```
[[r,g,b, r,g,b, r,g,b],
 [r,g,b, r,g,b, r,g,b]]
```

This matches how row-by-row prediction works — `zipWith` over adjacent rows reads naturally. Performance is not a concern; clarity is.

### Header

```haskell
data Header = Header
  { width      :: !Word32
  , height     :: !Word32
  , colorSpace :: !ColorSpace
  , bitDepth   :: !BitDepth
  , predictor  :: !PredictorId
  } deriving (Eq, Show)
```

All fields use bang patterns (`!`) for strict evaluation, preventing space leaks from unevaluated thunks. This is idiomatic for data types that are always fully computed.

### ADTs

```haskell
data ColorSpace = Grayscale | GrayscaleAlpha | RGB | RGBA
  deriving (Eq, Show, Enum, Bounded)

data BitDepth = Depth8 | Depth16
  deriving (Eq, Show, Enum, Bounded)

data PredictorId = PNone | PSub | PUp | PAverage | PPaeth | PGradient | PAdaptive
  deriving (Eq, Show, Enum, Bounded)
```

`Enum` and `Bounded` are derived so QuickCheck can generate arbitrary values automatically via `arbitraryBoundedEnum`.

### Error type

```haskell
data SigilError
  = InvalidMagic ByteString
  | UnsupportedVersion Word8 Word8
  | CrcMismatch { expected :: Word32, actual :: Word32 }
  | InvalidPredictor Word8
  | TruncatedInput
  | InvalidDimensions Word32 Word32
  deriving (Show, Eq)
```

Fallible operations return `Either SigilError a`. No exceptions — everything stays pure and composable.

### Metadata

```haskell
data Metadata = Metadata
  { metaEntries :: [(Text, ByteString)]
  } deriving (Eq, Show)
```

Optional key-value pairs stored in the SMTA chunk. Keys are UTF-8 text, values are raw bytes. Reserved keys: `sigil:encoder`, `sigil:source`, `icc:profile`.

---

## 3. Pipeline Architecture

### Stage newtype with Category instance

```haskell
newtype Stage a b = Stage { runStage :: a -> b }

instance Category Stage where
  id  = Stage Prelude.id
  (.) = \(Stage f) (Stage g) -> Stage (f Prelude.. g)
```

`Stage` wraps a pure function and enables left-to-right composition via `>>>` from `Control.Category`. The type system prevents mismatched stage wiring — connecting a stage that outputs `Residuals` to one expecting `TokenStream` is a compile error.

### Pipeline composition

```haskell
compressPipeline :: Header -> Stage Image ByteString
compressPipeline hdr =
      Stage (predictImage hdr)          -- Image -> (Vector PredictorId, Residuals)
  >>> Stage flattenWithPredictors       -- ... -> (Vector PredictorId, Vector Word16)
  >>> Stage (uncurry encodeData)        -- ... -> ByteString

decompressPipeline :: Header -> Stage ByteString Image
decompressPipeline hdr =
      Stage decodeData                  -- ByteString -> (Vector PredictorId, Vector Word16)
  >>> Stage unflattenWithPredictors     -- ... -> (Vector PredictorId, Residuals)
  >>> Stage (unpredictImage hdr)        -- ... -> Image
```

### Adaptive predictor ID threading

The adaptive predictor produces per-row predictor IDs that must be carried through the pipeline and written into the SDAT chunk. The intermediate types are tuples: `(Vector PredictorId, Residuals)`. For fixed (non-adaptive) predictors, the `Vector PredictorId` is a uniform vector of the same ID repeated — no special casing required.

The `flattenWithPredictors` stage handles zig-zag encoding and tokenization internally, converting `Residuals` (signed `Int16` per channel) into a flat `Vector Word16` of zig-zag-encoded values.

---

## 4. Codec Modules

### Predict (`Sigil.Codec.Predict`)

Six fixed predictors, each a pure function `Word8 -> Word8 -> Word8 -> Word8` taking left (a), above (b), and above-left (c) neighbors:

| Id | Name | Formula |
|---|---|---|
| PNone | None | `0` |
| PSub | Sub | `a` |
| PUp | Up | `b` |
| PAverage | Average | `(a + b) / 2` |
| PPaeth | Paeth | Paeth predictor (closest of a, b, c to `a + b - c`) |
| PGradient | Gradient | `clamp(a + b - c)` to [0, 255] |

**Adaptive selection**: Tries all six fixed predictors on a row, picks the one with the lowest sum of absolute residuals.

**Edge handling**: Row 0 has no "above" neighbor (`b = 0`, `c = 0`). Column 0 has no "left" neighbor (`a = 0`). Pixel 0,0 has no neighbors at all (`a = b = c = 0`).

**Residual computation**: `residual pred a b c x = fromIntegral x - fromIntegral (pred a b c)`. Residuals are signed `Int16` in the range [-255, 255].

`predictImage` walks rows top-to-bottom, producing `(Vector PredictorId, Vector (Vector Int16))`. The inverse `unpredictImage` reconstructs pixels from residuals and predictor IDs.

### ZigZag (`Sigil.Codec.ZigZag`)

Maps signed residuals to unsigned values via zig-zag encoding:

```haskell
zigzag :: Int16 -> Word16
zigzag n = fromIntegral ((n `shiftL` 1) `xor` (n `shiftR` 15))

unzigzag :: Word16 -> Int16
unzigzag n = fromIntegral ((n `shiftR` 1) `xor` negate (n .&. 1))
```

Mapping: `0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4, ...`

### Token (`Sigil.Codec.Token`)

Converts zig-zagged values into a token stream for entropy coding:

```haskell
data Token = TZeroRun Word16 | TValue Word16
  deriving (Eq, Show)

tokenize :: Vector Word16 -> [Token]
untokenize :: [Token] -> Vector Word16
```

Consecutive zero values are collapsed into `TZeroRun` tokens. Non-zero values become `TValue` tokens.

### Rice (`Sigil.Codec.Rice`)

Rice-Golomb entropy coding with bit-level I/O.

**BitWriter / BitReader**: Accumulate/consume individual bits. BitWriter uses a strict `State` monad internally for readability. BitReader parses from a `ByteString`.

**Rice encoding**: For a value `val` with parameter `k`:
- Quotient `q = val >> k` encoded as unary (q ones + one zero)
- Remainder `r = val & ((1 << k) - 1)` encoded as k-bit binary

**Optimal k selection**: Per block of 64 values, try k=0..8, pick the k that minimizes total encoded bits. Cost formula: `sum(val >> k) + blockSize + k * blockSize`.

**Token stream encoding**:
- `TZeroRun`: 1-bit flag `0` + 16-bit run length
- `TValue`: 1-bit flag `1` + Rice-Golomb coded value

---

## 5. File I/O

### Chunk format

Every chunk follows the Sigil spec:

```
Tag (4 bytes) | Length (u32) | Payload (Length bytes) | CRC32 (u32)
```

Tags: SHDR, SMTA, SPAL, SDAT, SEND. CRC32 is computed over the payload bytes only.

### Reader (`Sigil.IO.Reader`)

Parses a `.sgl` file from a lazy `ByteString` using `Data.Binary.Get`:
1. Validate magic bytes (`0x89 S G L \r \n`)
2. Read version bytes (major, minor)
3. Read chunks in sequence: tag + length + payload + CRC
4. Verify each chunk's CRC
5. Parse SHDR payload into `Header`
6. Parse optional SMTA into `Metadata`
7. Concatenate SDAT payloads, decode into `Image`
8. Expect SEND as final chunk

Returns `Either SigilError (Header, Metadata, Image)`.

### Writer (`Sigil.IO.Writer`)

Serializes using `Data.Binary.Put`:
1. Write magic bytes and version
2. Serialize `Header` into SHDR chunk payload, compute CRC, write chunk
3. If metadata present, serialize SMTA chunk
4. Encode image data, split into one or more SDAT chunks
5. Write SEND chunk (empty payload)

All multi-byte integers are big-endian.

### Convert (`Sigil.IO.Convert`)

Thin wrapper around JuicyPixels:
- `loadImage :: FilePath -> IO (Either SigilError (Header, Image))` — reads PNG/JPEG, extracts pixel data and color space, builds `Header` and row vectors
- `saveImage :: FilePath -> Header -> Image -> IO ()` — converts Sigil `Image` back to PNG via JuicyPixels

This module is the only place JuicyPixels is imported. The rest of the codebase works exclusively with Sigil's own `Image` type.

---

## 6. CLI

Five commands via `optparse-applicative`:

### `sigil-hs encode <input> -o <output.sgl>`
Load image (PNG/JPEG), compress through the full pipeline, write `.sgl` file. Optional `--predictor` flag (default: adaptive).

### `sigil-hs decode <input.sgl> -o <output.png>`
Read `.sgl` file, decompress, write PNG via JuicyPixels.

### `sigil-hs info <input.sgl>`
Print header metadata: dimensions, color space, bit depth, predictor, chunk count and sizes. No decompression.

### `sigil-hs verify <input>`
Encode then decode, diff pixels against original. Reports pass/fail and any differing pixel count.

### `sigil-hs bench <input> [--iterations N] [--compare DIR]`
Full benchmark and compression analysis. See Section 8.

Each command is a pure function wrapped in `IO` at the edges — read file, run pure pipeline, write output. Errors print `SigilError` and exit with failure code.

---

## 7. SDAT Layout

The data chunk payload follows the format from the spec:

```
[Per-row predictor IDs (1 byte each)]   -- only if header predictor = PAdaptive
[Per-block Rice k values (4 bits each)]  -- for each block of 64 residuals
[Token bitstream (variable length)]      -- Rice-Golomb encoded tokens
[Byte-aligned padding]                   -- pad final byte with zero bits
```

Multiple SDAT chunks may be used for large images. The decoder concatenates payloads before decoding.

---

## 8. Benchmarking

Two layers: criterion micro-benchmarks and CLI comparison tool.

### Criterion benchmarks (`bench/Main.hs`)

Statistical micro-benchmarks for each pipeline stage in isolation plus full pipeline. Criterion runs each benchmark many times, computes mean/stddev, detects outliers, and generates HTML reports.

| Benchmark group | What it measures |
|---|---|
| `predict/<predictor>/<size>` | Each of 6 fixed predictors + adaptive on 64x64, 256x256, 1024x1024, 3840x2160, 7680x4320 |
| `zigzag/encode`, `zigzag/decode` | Bulk zig-zag on 10k, 100k, 1M samples |
| `tokenize/sparse`, `tokenize/dense`, `tokenize/uniform` | Tokenizer on different residual distributions |
| `rice/encode/<k>`, `rice/decode/<k>` | Rice coding for each k=0..8 on block of 64 |
| `rice/optimal-k` | The k selection loop |
| `pipeline/encode/<size>`, `pipeline/decode/<size>` | Full compress/decompress on 64x64 through 7680x4320 |
| `io/read-sgl`, `io/write-sgl` | Chunk parsing and serialization overhead |

Test images for benchmarks are generated programmatically (gradient, noise, flat, checkerboard) so benchmarks are self-contained.

### CLI `bench` command

Given a real image file, the bench command performs:

**1. Per-predictor compression table:**

```
Image: photo.png (640x480, RGB, 8-bit)
Raw size: 921,600 bytes

Predictor     Encoded     Ratio    Encode ms    Decode ms
--------------------------------------------------------------
None          845,200     1.09x      12.3         8.1
Sub           412,800     2.23x      14.1         9.2
Up            398,400     2.31x      13.8         9.0
Average       385,600     2.39x      15.2         9.5
Paeth         378,900     2.43x      16.8        10.1
Gradient      381,200     2.42x      15.5         9.7
Adaptive      371,400     2.48x      28.3        10.4

PNG (JuicyPixels)  389,100     2.37x      45.2        22.1

Best: Adaptive (2.48x compression ratio)
```

**2. Per-predictor residual analysis:** For each predictor, compute mean/median/stddev of absolute residuals and the number of zero residuals (zero-run friendliness). This explains why one predictor beats another on a given image.

**3. `--iterations N`:** Repeat encode/decode N times for stable timing. Report min/mean/max.

**4. `--compare DIR`:** Run the full table on every image in a directory. Produce corpus summary:

```
Corpus summary (5 images):
                 Mean ratio    Best predictor wins
Adaptive         2.41x         5/5
Paeth            2.35x         0/5
PNG              2.28x         0/5
```

### Test image sizes

Benchmarks and CLI bench run across these sizes:
- Synthetic (generated): gradient 256x256, flat white 100x100, noise 128x128, checkerboard 64x64
- Photos (supplied manually): 640x480, 1920x1080 (HD), 3840x2160 (4K), 7680x4320 (8K)

The 8K images (~100MB raw RGB 8-bit) also serve as a stress test for space leaks in the Haskell implementation.

---

## 9. Testing

### QuickCheck property tests

Each law from the Sigil spec is a QuickCheck property:

| Property | Law |
|---|---|
| `prop_zigzagRoundTrip` | `unzigzag (zigzag n) == n` for all n in [-255, 255] |
| `prop_riceRoundTrip` | Encode then decode any value with any k=0..8 yields original |
| `prop_tokenizeRoundTrip` | `untokenize (tokenize xs) == xs` for any `[Word16]` |
| `prop_predictorResidual` | `predict(a,b,c) + residual(a,b,c,x) == x` for all predictor/pixel combos |
| `prop_adaptiveOptimal` | Adaptive's residual sum <= every fixed predictor's residual sum |
| `prop_pipelineRoundTrip` | `decompress (compress img) == img` for arbitrary images up to 64x64 |
| `prop_chunkCRC` | Serialized chunk's CRC matches recomputed CRC on deserialization |
| `prop_headerSerialize` | Serialize then deserialize header yields the original |

Custom `Arbitrary` instances in `Gen.hs` generate random `Header` values (constrained to valid dimension/colorspace combos), random `Image` values (correct row length for header), and random residual blocks.

### Conformance tests (golden tests)

For each test image in `tests/corpus/`:
1. Encode with `sigil-hs`, produce `.sgl`
2. Compare byte-for-byte against `tests/corpus/expected/<name>.sgl`
3. Decode the `.sgl`, compare pixels against original

First run generates the expected files (committed to git). Any encoder change that alters output is a test failure — guarantees determinism and detects accidental format changes.

### Corpus generation

A CLI subcommand `sigil-hs generate-corpus` creates synthetic test images programmatically:
- Gradient 256x256 — smooth ramps, good for prediction
- Flat white 100x100 — all zeros after prediction, tests RLE
- Noise 128x128 — pseudorandom with fixed seed for determinism, worst case
- Checkerboard 64x64 — periodic pattern, tests predictor selection

Photo test images (640x480, 1920x1080, 3840x2160, 7680x4320) are supplied manually and committed to the corpus.

---

## 10. Dependency Graph

```
Sigil.Core.Types      (no internal deps)
Sigil.Core.Error       (no internal deps)
Sigil.Core.Chunk       -> Types, Error
Sigil.Codec.Predict    -> Types
Sigil.Codec.ZigZag     (no internal deps)
Sigil.Codec.Token      (no internal deps)
Sigil.Codec.Rice       -> Token
Sigil.Codec.Pipeline   -> Types, Predict, ZigZag, Token, Rice
Sigil.IO.Reader        -> Types, Chunk, Error, Pipeline
Sigil.IO.Writer        -> Types, Chunk, Pipeline
Sigil.IO.Convert       -> Types, Error (+ JuicyPixels)
Sigil.Sigil            -> re-exports Pipeline, Reader, Writer, Convert
app/Main.hs            -> Sigil (+ optparse-applicative)
```

The core codec modules (`Predict`, `ZigZag`, `Token`, `Rice`) are pure — no IO, no external dependencies beyond `vector` and `bytestring`. This makes them independently testable and keeps the dependency graph clean.
