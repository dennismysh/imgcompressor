# Sigil Rust Production Codec — Design Spec

**Date**: 2026-03-28
**Scope**: Rust library crate + CLI binary, byte-for-byte conformant with sigil-hs
**Parent spec**: `docs/superpowers/specs/2026-03-25-sigil-hs-reference-design.md`

---

## 1. Goals

Port the Sigil image codec from the Haskell reference implementation to a production-quality Rust crate. The Rust version must:

- Produce byte-identical `.sgl` files to sigil-hs for the same input
- Decode any valid `.sgl` file produced by sigil-hs
- Be usable as a library crate (`sigil`) for embedding in Rust applications
- Include a CLI binary (`sigil-cli`) for manual use and testing
- Include `image` crate integration for PNG/JPEG/BMP I/O

---

## 2. Project Structure

Cargo workspace in `sigil-rs/` alongside the existing `sigil-hs/`:

```
sigil-rs/
├── Cargo.toml                    # workspace root
├── sigil/                        # library crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                # public API re-exports
│       ├── types.rs              # Header, ColorSpace, BitDepth, PredictorId, SigilError
│       ├── chunk.rs              # Tag, Chunk, CRC32, makeChunk, verifyChunk
│       ├── predict.rs            # predict, residual, predictRow, unpredictRow, predictImage, unpredictImage, adaptiveRow
│       ├── zigzag.rs             # zigzag, unzigzag
│       ├── token.rs              # Token, tokenize, untokenize
│       ├── rice.rs               # BitWriter, BitReader, riceEncode, riceDecode, optimalK
│       ├── pipeline.rs           # compress, decompress, encodeData, decodeData, encodeTokenStream, decodeTokenStream
│       ├── reader.rs             # decodeSigilFile, readSigilFile
│       ├── writer.rs             # encodeSigilFile, writeSigilFile
│       └── convert.rs            # image crate DynamicImage <-> Sigil pixel data
├── sigil-cli/                    # CLI binary
│   ├── Cargo.toml
│   └── src/
│       └── main.rs               # clap subcommands: encode, decode, info, verify, bench, generate-corpus
└── benches/
    └── codec.rs                  # criterion benchmarks
```

One Rust module per Haskell module for direct mapping and conformance tracing.

---

## 3. Public API

### High-level (file I/O)

```rust
/// Encode a PNG/JPEG/BMP file to .sgl format
pub fn encode_file(input: &Path, output: &Path) -> Result<(), SigilError>;

/// Decode a .sgl file to PNG
pub fn decode_file(input: &Path, output: &Path) -> Result<(), SigilError>;
```

### Mid-level (bytes)

```rust
/// Encode raw pixel data to .sgl bytes
pub fn encode(header: &Header, pixels: &[u8]) -> Result<Vec<u8>, SigilError>;

/// Decode .sgl bytes to header + raw pixel data
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError>;

/// Read header without decoding pixel data
pub fn read_header(data: &[u8]) -> Result<Header, SigilError>;
```

### Types

```rust
pub struct Header {
    pub width: u32,
    pub height: u32,
    pub color_space: ColorSpace,
    pub bit_depth: BitDepth,
    pub predictor: PredictorId,
}

pub enum ColorSpace { Grayscale, GrayscaleAlpha, Rgb, Rgba }
pub enum BitDepth { Depth8, Depth16 }
pub enum PredictorId { None, Sub, Up, Average, Paeth, Gradient, Adaptive }

pub struct Metadata {
    pub entries: Vec<(String, Vec<u8>)>,
}
```

All fallible operations return `Result<T, SigilError>`.

---

## 4. Image Storage

Images are stored as a flat contiguous `Vec<u8>` of row-major interleaved samples. For an RGB 3x2 image:

```
[r,g,b, r,g,b, r,g,b,  r,g,b, r,g,b, r,g,b]
 -------- row 0 --------  -------- row 1 --------
```

Row access is by slice: `&pixels[row * row_bytes..(row + 1) * row_bytes]` where `row_bytes = width * channels * bytes_per_channel`.

This is logically equivalent to the Haskell `Vector (Vector Word8)` but avoids per-row heap allocations.

---

## 5. Codec Modules

Each module is a direct port of the corresponding Haskell module with identical algorithms. The Rust versions use mutable buffers and index arithmetic instead of immutable vectors with `V.snoc`.

### zigzag.rs

```rust
pub fn zigzag(n: i16) -> u16;
pub fn unzigzag(n: u16) -> i16;
```

Identical bit formulas to Haskell: `(n << 1) ^ (n >> 15)` and `(n >> 1) ^ -(n & 1)`.

### predict.rs

```rust
pub fn predict(pid: PredictorId, a: u8, b: u8, c: u8) -> u8;
pub fn residual(pid: PredictorId, a: u8, b: u8, c: u8, x: u8) -> i16;
pub fn predict_row(pid: PredictorId, prev: &[u8], cur: &[u8], ch: usize) -> Vec<i16>;
pub fn unpredict_row(pid: PredictorId, prev: &[u8], residuals: &[i16], ch: usize) -> Vec<u8>;
pub fn predict_image(header: &Header, pixels: &[u8]) -> (Vec<PredictorId>, Vec<Vec<i16>>);
pub fn unpredict_image(header: &Header, pids: &[PredictorId], residuals: &[Vec<i16>]) -> Vec<u8>;
pub fn adaptive_row(prev: &[u8], cur: &[u8], ch: usize) -> (PredictorId, Vec<i16>);
```

Key difference from Haskell: `unpredict_row` writes into a pre-allocated `Vec<u8>` instead of using `V.unfoldrExactN` with `V.snoc`. Each pixel reads from the already-written prefix of the output buffer — same causal access pattern, O(n) instead of O(n^2).

### token.rs

```rust
pub enum Token { ZeroRun(u16), Value(u16) }
pub fn tokenize(values: &[u16]) -> Vec<Token>;
pub fn untokenize(tokens: &[Token]) -> Vec<u16>;
```

### rice.rs

```rust
pub struct BitWriter { bytes: Vec<u8>, current: u8, bit_pos: u8 }
pub struct BitReader<'a> { data: &'a [u8], byte_ix: usize, bit_pos: u8 }

pub fn rice_encode(k: u8, val: u16, w: &mut BitWriter);
pub fn rice_decode(k: u8, r: &mut BitReader) -> u16;
pub fn optimal_k(block: &[u16]) -> u8;
```

BitWriter/BitReader use mutable references instead of returning new copies. MSB-first bit ordering, identical to Haskell.

### pipeline.rs

```rust
pub fn compress(header: &Header, pixels: &[u8]) -> Vec<u8>;
pub fn decompress(header: &Header, data: &[u8]) -> Result<Vec<u8>, SigilError>;
```

Composes: predict -> zigzag -> tokenize -> Rice encode. The SDAT payload format matches Haskell exactly:

```
[predictor IDs if adaptive] [16-bit numBlocks] [4-bit k per block] [token bitstream]
```

Token bitstream: 1-bit flag per token. Flag 1 = TValue (Rice-coded), Flag 0 = TZeroRun (16-bit length).

### chunk.rs

```rust
pub fn crc32(data: &[u8]) -> u32;
```

Hand-rolled CRC32 with polynomial 0xEDB88320 (reflected, ISO 3309). Lookup table computed at compile time via `const fn`.

### reader.rs / writer.rs

Binary serialization using manual byte manipulation (no serde). Big-endian integers. Magic bytes: `0x89 S G L \r \n`. Version: 0.2.

---

## 6. Error Handling

```rust
#[derive(Debug, thiserror::Error)]
pub enum SigilError {
    #[error("invalid magic bytes")]
    InvalidMagic,
    #[error("unsupported version {major}.{minor}")]
    UnsupportedVersion { major: u8, minor: u8 },
    #[error("CRC mismatch: expected {expected:#010x}, got {actual:#010x}")]
    CrcMismatch { expected: u32, actual: u32 },
    #[error("invalid predictor: {0}")]
    InvalidPredictor(u8),
    #[error("truncated input")]
    TruncatedInput,
    #[error("invalid dimensions: {0}x{1}")]
    InvalidDimensions(u32, u32),
    #[error("invalid color space: {0}")]
    InvalidColorSpace(u8),
    #[error("invalid bit depth: {0}")]
    InvalidBitDepth(u8),
    #[error("invalid chunk tag")]
    InvalidTag,
    #[error("missing chunk: {0}")]
    MissingChunk(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("image error: {0}")]
    Image(#[from] image::ImageError),
}
```

---

## 7. CLI (sigil-cli)

Same subcommands as sigil-hs, using `clap` derive:

- `sigil encode <INPUT> -o <OUTPUT>` — encode PNG/JPEG to .sgl
- `sigil decode <INPUT> -o <OUTPUT>` — decode .sgl to PNG
- `sigil info <INPUT>` — print header metadata
- `sigil verify <INPUT>` — encode then decode, diff against original
- `sigil bench <INPUT> [--iterations N] [--compare DIR]` — per-predictor compression table with timing
- `sigil generate-corpus -o <DIR>` — generate synthetic test images

---

## 8. Dependencies

### sigil (library)

| Crate | Purpose |
|---|---|
| `image` | PNG/JPEG/BMP decode/encode |
| `thiserror` | Error type derivation |

### sigil-cli (binary)

| Crate | Purpose |
|---|---|
| `sigil` | The codec library (workspace dep) |
| `clap` (derive) | CLI argument parsing |

### Dev dependencies

| Crate | Purpose |
|---|---|
| `proptest` | Property-based testing (Rust QuickCheck equivalent) |
| `criterion` | Statistical micro-benchmarks |

---

## 9. Testing

### Unit tests (per module)

Each module has `#[cfg(test)] mod tests` with the same properties as the Haskell QuickCheck tests:

| Test | Property |
|---|---|
| `zigzag_round_trip` | `unzigzag(zigzag(n)) == n` for all n in [-255, 255] |
| `rice_round_trip` | encode then decode any value with any k in [0,8] |
| `tokenize_round_trip` | `untokenize(tokenize(v)) == v` for any Vec<u16> |
| `predictor_residual_law` | `predict(a,b,c) + residual(a,b,c,x) == x` |
| `adaptive_optimal` | adaptive cost <= every fixed predictor's cost |
| `pipeline_round_trip` | `decompress(compress(img)) == img` for random images |
| `chunk_crc` | `crc32("")` == 0x00000000, `crc32("IEND")` == 0xAE426082 |
| `header_round_trip` | serialize then deserialize header == original |

### Conformance tests (integration)

`sigil/tests/conformance.rs`:

1. Load each corpus PNG from `../../tests/corpus/`
2. Encode with `sigil::encode`
3. Compare byte-for-byte against `../../tests/corpus/expected/<name>.sgl`
4. Decode the golden `.sgl`
5. Compare pixels against the source PNG

### File I/O round-trip

Property test: generate random small images (1-16 x 1-16, all color spaces), encode to .sgl bytes, decode back, assert pixel equality.

---

## 10. Benchmarks

`sigil-rs/benches/codec.rs` using criterion:

| Group | What |
|---|---|
| `predict/<predictor>/<size>` | Each predictor on 64x64, 256x256, 1024x1024 |
| `zigzag/encode`, `zigzag/decode` | Bulk zigzag on 511 values |
| `tokenize/sparse,dense,uniform` | Tokenizer on different distributions |
| `rice/encode/k=N` | Rice coding for each k=0..8 |
| `pipeline/encode/<size>`, `pipeline/decode/<size>` | Full pipeline on 64x64 through 1024x1024 |

Synthetic images generated programmatically (gradient, noise, flat, checkerboard) — same as Haskell.

---

## 11. Conformance-Critical Details

These details must be identical between Rust and Haskell to achieve byte-for-byte conformance:

1. **Predictor tie-breaking in adaptive mode**: when two predictors have equal cost, `minimumBy` in Haskell picks the first in the list (`[PNone .. PGradient]`). Rust must use the same ordering.

2. **Rice optimal k tie-breaking**: `minimum` on `(cost, k)` tuples — lowest cost wins, ties broken by lowest k. Rust must match.

3. **BitWriter bit ordering**: MSB-first within each byte. Bit position 0 is the highest bit (bit 7).

4. **Token stream format**: `[16-bit numBlocks][4-bit k per block][token bits]`. TZeroRun tokens don't consume block budget. Decoder uses `totalSamples` from header to terminate.

5. **CRC32 polynomial**: 0xEDB88320 (reflected). CRC32 of empty input = 0x00000000.

6. **Header encoding**: BitDepth serialized as raw byte value (8 or 16), not enum index.

7. **Integer endianness**: All multi-byte integers in the file format are big-endian.
