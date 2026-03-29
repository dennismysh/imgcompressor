# Sigil Decoder Library — Design Spec

**Date**: 2026-03-28
**Scope**: Rust decode-only library crate for reading `.sgl` files
**Parent**: Sigil v0.2 format (implemented in `sigil-hs/`)

---

## 1. Purpose

A Rust library crate (`sigil-decode`) that reads `.sgl` files and produces raw pixel data. This is the first step toward `.sgl` format adoption — before any app or browser can display Sigil images, something needs to decode them.

The encoder stays in Haskell (`sigil-hs`). This crate is **decode-only**.

---

## 2. Project Structure

Single crate (not a workspace — no CLI, no encoder):

```
sigil-rs/
├── Cargo.toml
├── src/
│   ├── lib.rs          -- public API: decode, read_header
│   ├── types.rs        -- Header, ColorSpace, BitDepth, PredictorId, SigilError
│   ├── chunk.rs        -- CRC32 verification, chunk parsing
│   ├── rice.rs         -- BitReader, riceDecode
│   ├── token.rs        -- untokenize only
│   ├── zigzag.rs       -- unzigzag only
│   ├── predict.rs      -- predict (all 6), unpredictRow, unpredictImage
│   ├── pipeline.rs     -- decompress (decode pipeline)
│   └── reader.rs       -- parse .sgl file: magic, version, chunks → pixels
└── tests/
    └── conformance.rs  -- decode golden .sgl files, verify pixel output
```

---

## 3. Public API

```rust
/// Decode a .sgl file from bytes. Returns header + raw pixel data.
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError>;

/// Read only the header without decoding pixel data.
pub fn read_header(data: &[u8]) -> Result<Header, SigilError>;
```

That's the entire public surface. Two functions.

Pixels are returned as a flat `Vec<u8>` of row-major interleaved samples. For RGB: `[r,g,b, r,g,b, ...]`. The caller uses `Header` to interpret dimensions, color space, and channel count.

No `image` crate dependency. No file I/O. The caller provides bytes, gets pixels back. This keeps the crate minimal and WASM-compatible.

---

## 4. Types

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub width: u32,
    pub height: u32,
    pub color_space: ColorSpace,
    pub bit_depth: BitDepth,
    pub predictor: PredictorId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSpace { Grayscale, GrayscaleAlpha, Rgb, Rgba }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BitDepth { Depth8, Depth16 }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PredictorId { None, Sub, Up, Average, Paeth, Gradient, Adaptive }

impl Header {
    pub fn channels(&self) -> usize { ... }
    pub fn bytes_per_channel(&self) -> usize { ... }
    pub fn row_bytes(&self) -> usize { ... }
}
```

---

## 5. Error Type

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SigilError {
    InvalidMagic,
    UnsupportedVersion { major: u8, minor: u8 },
    CrcMismatch { expected: u32, actual: u32 },
    InvalidPredictor(u8),
    TruncatedInput,
    InvalidDimensions(u32, u32),
    InvalidColorSpace(u8),
    InvalidBitDepth(u8),
    InvalidTag,
    MissingChunk,
}
```

No `thiserror` dependency — hand-implement `Display` and `Error`. Zero dependencies keeps WASM builds tiny. `std::error::Error` impl is behind `#[cfg(feature = "std")]` with `std` enabled by default for native, disabled for `no_std` + `alloc` WASM builds.

---

## 6. Dependencies

**Runtime: none.** Zero external dependencies. CRC32 is hand-rolled (same as Haskell). All bit I/O is manual.

**Dev only:**
- `proptest` — property-based testing

This means the crate compiles to WASM with zero bloat.

---

## 7. Decode Pipeline (decode-only half of sigil-hs)

```
.sgl bytes
  → parse magic + version
  → read chunks (verify CRC32 each)
  → parse SHDR → Header
  → concatenate SDAT payloads
  → decode SDAT:
      → read predictor IDs (if adaptive)
      → decode token stream (BitReader + Rice decode)
      → untokenize → flat zigzag values
      → unzigzag → signed residuals
      → unpredict rows → raw pixels
  → return (Header, Vec<u8>)
```

Each step is a direct port of the corresponding Haskell decode function.

---

## 8. Codec Modules (decode-only)

### chunk.rs
- `crc32(data: &[u8]) -> u32` — polynomial 0xEDB88320, lookup table via `const fn`
- `parse_chunks(data: &[u8]) -> Result<Vec<Chunk>, SigilError>` — read tag + length + payload + CRC, verify CRC, collect until SEND

### rice.rs
- `BitReader` struct with `read_bit()` and `read_bits(n)`
- `rice_decode(k: u8, reader: &mut BitReader) -> u16`
- MSB-first bit ordering (bit 7 is position 0)

### token.rs
- `Token` enum: `ZeroRun(u16)` | `Value(u16)`
- `untokenize(tokens: &[Token]) -> Vec<u16>` — expand ZeroRun to zeros, Value to value

### zigzag.rs
- `unzigzag(n: u16) -> i16` — `(n >> 1) ^ -(n & 1)`

### predict.rs
- `predict(pid, a, b, c) -> u8` — all 6 fixed predictors (needed for reconstruction)
- `unpredict_row(pid, prev_row, residuals, channels) -> Vec<u8>` — builds left-to-right, causal access
- `unpredict_image(header, predictor_ids, residuals) -> Vec<u8>` — reconstruct all rows

### pipeline.rs
- `decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError>`
- Composes: read predictor IDs → decode token stream → untokenize → unzigzag → unpredict

### reader.rs
- `decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError>` — full .sgl parse
- `read_header(data: &[u8]) -> Result<Header, SigilError>` — header only, skip pixel decode

---

## 9. Token Stream Decode Format

The SDAT payload (after optional predictor IDs):

```
[16-bit numBlocks] [4-bit k per block] [token bitstream]
```

Token bitstream: read 1-bit flag per token.
- Flag 1 → TValue: Rice-decode value using current block's k
- Flag 0 → TZeroRun: read 16-bit run length

Block k tracking: advance to next k after every `blockSize` (64) TValues decoded. TZeroRun tokens don't affect block position. Decoder uses `totalSamples` from the header to know when to stop.

---

## 10. Testing

### Conformance tests (`tests/conformance.rs`)

The golden `.sgl` files in `tests/corpus/expected/` were produced by sigil-hs. The decoder must produce pixel-identical output to sigil-hs's decode of the same files.

For each golden `.sgl`:
1. Decode with `sigil_decode::decode()`
2. Verify header fields match expected values
3. Verify pixel data matches sigil-hs's decode output

To get the expected pixel data: run `sigil-hs decode` on each golden `.sgl` to produce a PNG, then use the `image` crate (dev-dependency only) to load the PNG and compare raw pixels.

### Unit tests (per module, inline `#[cfg(test)]`)

- `unzigzag` round-trip: `unzigzag(zigzag(n)) == n` for known values
- `rice_decode` round-trip: encode with a test BitWriter, decode, verify value
- `untokenize` expansion: known token lists produce expected output
- `predict` values: verify each predictor matches expected output for known inputs
- `unpredict_row` reconstruction: predict a known row, then unpredict and verify identity
- `crc32` known values: empty → 0x00000000, "IEND" → 0xAE426082

### Property tests (proptest)

- `unpredict_row(predict_row(row)) == row` for random rows (requires implementing predict_row as a test helper)
- `untokenize(tokenize(values)) == values` (requires implementing tokenize as a test helper)

---

## 11. WASM Compatibility

The crate is designed for WASM from the start:
- Zero dependencies (no system libs, no I/O)
- `#![no_std]` compatible with `alloc` (Vec, String)
- `std` feature (default) adds `std::error::Error` impl
- Public API takes `&[u8]` and returns `Vec<u8>` — trivial to bridge via `wasm-bindgen`

Future work (not this spec): a `sigil-wasm` wrapper with `wasm-bindgen` that exposes `decode()` to JavaScript.
