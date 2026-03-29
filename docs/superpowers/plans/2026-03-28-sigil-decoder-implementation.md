# Sigil Decoder (Rust) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a zero-dependency, WASM-compatible Rust library crate (`sigil-decode`) that reads `.sgl` files produced by `sigil-hs` and returns raw pixel data.

**Architecture:** Single library crate at `sigil-rs/` with 8 internal modules mirroring the Haskell decode path: types + error, CRC32 + chunk parsing, zigzag, token, Rice bitreader, predict, pipeline decompress, and file reader. Public API is two functions: `decode(&[u8]) -> Result<(Header, Vec<u8>), SigilError>` and `read_header(&[u8]) -> Result<Header, SigilError>`. Every codec stage is a direct port of the corresponding Haskell decode function. Conformance tests decode golden `.sgl` files and compare pixel output against source PNGs.

**Tech Stack:** Rust (stable), no runtime dependencies, `proptest` (dev-dependency), `image` (dev-dependency, conformance tests only)

**Spec:** `docs/superpowers/specs/2026-03-28-sigil-decoder-design.md`

**Haskell Reference:** `sigil-hs/src/Sigil/` (decode path in Reader.hs, Pipeline.hs, Rice.hs, Token.hs, ZigZag.hs, Predict.hs, Chunk.hs)

---

## File Structure

```
sigil-rs/
├── Cargo.toml
├── src/
│   ├── lib.rs          -- public API: decode(), read_header(), re-exports
│   ├── types.rs        -- Header, ColorSpace, BitDepth, PredictorId
│   ├── error.rs        -- SigilError enum, Display + Error impls
│   ├── crc32.rs        -- CRC32 lookup table + compute function
│   ├── chunk.rs        -- Chunk struct, parse_chunks, verify CRC
│   ├── zigzag.rs       -- unzigzag only
│   ├── token.rs        -- Token enum, untokenize only
│   ├── rice.rs         -- BitReader, rice_decode, decode_token_stream
│   ├── predict.rs      -- predict (6 fixed), unpredict_row, unpredict_image
│   ├── pipeline.rs     -- decompress: ties rice → untokenize → unzigzag → unpredict
│   └── reader.rs       -- parse .sgl file: magic, version, chunks → Header + pixels
└── tests/
    └── conformance.rs  -- decode golden .sgl files, compare against PNG pixel data
```

Each module has one clear responsibility. The dependency graph is strictly acyclic:
- `lib.rs` → `reader.rs` → `pipeline.rs` → `rice.rs`, `token.rs`, `zigzag.rs`, `predict.rs`
- `reader.rs` → `chunk.rs` → `crc32.rs`
- Everything uses `types.rs` and `error.rs`

---

### Task 1: Project Scaffold

**Files:**
- Create: `sigil-rs/Cargo.toml`
- Create: `sigil-rs/src/lib.rs`

- [ ] **Step 1: Create directory structure**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
mkdir -p sigil-rs/src
mkdir -p sigil-rs/tests
```

- [ ] **Step 2: Write Cargo.toml**

Create `sigil-rs/Cargo.toml`:

```toml
[package]
name = "sigil-decode"
version = "0.1.0"
edition = "2021"
description = "Decode-only library for Sigil (.sgl) image files"
license = "MIT"

[dependencies]
# Zero runtime dependencies

[dev-dependencies]
proptest = "1"
image = "0.25"
```

- [ ] **Step 3: Write minimal lib.rs**

Create `sigil-rs/src/lib.rs`:

```rust
//! Sigil decoder — reads `.sgl` files and returns raw pixel data.
//!
//! # Usage
//! ```ignore
//! let bytes = std::fs::read("image.sgl").unwrap();
//! let (header, pixels) = sigil_decode::decode(&bytes).unwrap();
//! ```

mod types;
mod error;

pub use types::{Header, ColorSpace, BitDepth, PredictorId};
pub use error::SigilError;
```

- [ ] **Step 4: Write stub types.rs**

Create `sigil-rs/src/types.rs`:

```rust
/// Color space of the image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSpace {
    Grayscale,
    GrayscaleAlpha,
    Rgb,
    Rgba,
}

/// Bits per channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BitDepth {
    Eight,
    Sixteen,
}

/// Prediction filter applied during encoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PredictorId {
    None,
    Sub,
    Up,
    Average,
    Paeth,
    Gradient,
    Adaptive,
}

/// Image header parsed from the SHDR chunk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub width: u32,
    pub height: u32,
    pub color_space: ColorSpace,
    pub bit_depth: BitDepth,
    pub predictor: PredictorId,
}

impl Header {
    /// Number of channels for this color space.
    pub fn channels(&self) -> usize {
        match self.color_space {
            ColorSpace::Grayscale => 1,
            ColorSpace::GrayscaleAlpha => 2,
            ColorSpace::Rgb => 3,
            ColorSpace::Rgba => 4,
        }
    }

    /// Bytes per channel sample.
    pub fn bytes_per_channel(&self) -> usize {
        match self.bit_depth {
            BitDepth::Eight => 1,
            BitDepth::Sixteen => 2,
        }
    }

    /// Total bytes per row (width * channels * bytes_per_channel).
    pub fn row_bytes(&self) -> usize {
        self.width as usize * self.channels() * self.bytes_per_channel()
    }
}
```

- [ ] **Step 5: Write stub error.rs**

Create `sigil-rs/src/error.rs`:

```rust
use core::fmt;

/// All errors that can occur during `.sgl` decoding.
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
    MissingChunk(&'static str),
}

impl fmt::Display for SigilError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SigilError::InvalidMagic => write!(f, "invalid magic bytes"),
            SigilError::UnsupportedVersion { major, minor } => {
                write!(f, "unsupported version {major}.{minor}")
            }
            SigilError::CrcMismatch { expected, actual } => {
                write!(f, "CRC mismatch: expected {expected:#010x}, got {actual:#010x}")
            }
            SigilError::InvalidPredictor(n) => write!(f, "invalid predictor id: {n}"),
            SigilError::TruncatedInput => write!(f, "truncated input"),
            SigilError::InvalidDimensions(w, h) => {
                write!(f, "invalid dimensions: {w}x{h}")
            }
            SigilError::InvalidColorSpace(n) => write!(f, "invalid color space: {n}"),
            SigilError::InvalidBitDepth(n) => write!(f, "invalid bit depth: {n}"),
            SigilError::InvalidTag => write!(f, "invalid chunk tag"),
            SigilError::MissingChunk(name) => write!(f, "missing required chunk: {name}"),
        }
    }
}

impl std::error::Error for SigilError {}
```

- [ ] **Step 6: Verify the crate compiles**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo build
```

Expected: compiles with no errors. May show warnings about unused items — that is fine.

- [ ] **Step 7: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/Cargo.toml sigil-rs/src/lib.rs sigil-rs/src/types.rs sigil-rs/src/error.rs
git commit -m "feat(sigil-rs): scaffold decoder crate with types and error"
```

---

### Task 2: Types & Error — Unit Tests

**Files:**
- Modify: `sigil-rs/src/types.rs`
- Modify: `sigil-rs/src/error.rs`

- [ ] **Step 1: Add ColorSpace and PredictorId conversion methods to types.rs**

These are needed by the chunk parser later. Append to the bottom of `sigil-rs/src/types.rs`, after the existing `impl Header` block:

```rust
impl ColorSpace {
    /// Decode from on-wire byte (enum index: 0=Grayscale, 1=GrayscaleAlpha, 2=RGB, 3=RGBA).
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(ColorSpace::Grayscale),
            1 => Some(ColorSpace::GrayscaleAlpha),
            2 => Some(ColorSpace::Rgb),
            3 => Some(ColorSpace::Rgba),
            _ => None,
        }
    }
}

impl BitDepth {
    /// Decode from on-wire byte (literal: 8 or 16).
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            8 => Some(BitDepth::Eight),
            16 => Some(BitDepth::Sixteen),
            _ => None,
        }
    }
}

impl PredictorId {
    /// Decode from on-wire byte (enum index: 0-6).
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(PredictorId::None),
            1 => Some(PredictorId::Sub),
            2 => Some(PredictorId::Up),
            3 => Some(PredictorId::Average),
            4 => Some(PredictorId::Paeth),
            5 => Some(PredictorId::Gradient),
            6 => Some(PredictorId::Adaptive),
            _ => None,
        }
    }

    /// Convert to on-wire byte (enum index).
    pub fn to_byte(self) -> u8 {
        match self {
            PredictorId::None => 0,
            PredictorId::Sub => 1,
            PredictorId::Up => 2,
            PredictorId::Average => 3,
            PredictorId::Paeth => 4,
            PredictorId::Gradient => 5,
            PredictorId::Adaptive => 6,
        }
    }
}
```

- [ ] **Step 2: Add unit tests to types.rs**

Append to the bottom of `sigil-rs/src/types.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_channels() {
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight, predictor: PredictorId::None }.channels(), 1);
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::GrayscaleAlpha, bit_depth: BitDepth::Eight, predictor: PredictorId::None }.channels(), 2);
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight, predictor: PredictorId::None }.channels(), 3);
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::Rgba, bit_depth: BitDepth::Eight, predictor: PredictorId::None }.channels(), 4);
    }

    #[test]
    fn header_bytes_per_channel() {
        let h8 = Header { width: 1, height: 1, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight, predictor: PredictorId::None };
        let h16 = Header { width: 1, height: 1, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Sixteen, predictor: PredictorId::None };
        assert_eq!(h8.bytes_per_channel(), 1);
        assert_eq!(h16.bytes_per_channel(), 2);
    }

    #[test]
    fn header_row_bytes() {
        let h = Header { width: 100, height: 50, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight, predictor: PredictorId::None };
        assert_eq!(h.row_bytes(), 300);
    }

    #[test]
    fn colorspace_from_byte() {
        assert_eq!(ColorSpace::from_byte(0), Some(ColorSpace::Grayscale));
        assert_eq!(ColorSpace::from_byte(1), Some(ColorSpace::GrayscaleAlpha));
        assert_eq!(ColorSpace::from_byte(2), Some(ColorSpace::Rgb));
        assert_eq!(ColorSpace::from_byte(3), Some(ColorSpace::Rgba));
        assert_eq!(ColorSpace::from_byte(4), None);
    }

    #[test]
    fn bitdepth_from_byte() {
        assert_eq!(BitDepth::from_byte(8), Some(BitDepth::Eight));
        assert_eq!(BitDepth::from_byte(16), Some(BitDepth::Sixteen));
        assert_eq!(BitDepth::from_byte(0), None);
        assert_eq!(BitDepth::from_byte(32), None);
    }

    #[test]
    fn predictor_from_byte_roundtrip() {
        for b in 0..=6u8 {
            let pid = PredictorId::from_byte(b).unwrap();
            assert_eq!(pid.to_byte(), b);
        }
        assert_eq!(PredictorId::from_byte(7), None);
    }
}
```

- [ ] **Step 3: Add unit test to error.rs**

Append to the bottom of `sigil-rs/src/error.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_formats() {
        assert_eq!(SigilError::InvalidMagic.to_string(), "invalid magic bytes");
        assert_eq!(
            SigilError::UnsupportedVersion { major: 1, minor: 3 }.to_string(),
            "unsupported version 1.3"
        );
        assert_eq!(
            SigilError::CrcMismatch { expected: 0xAABBCCDD, actual: 0x11223344 }.to_string(),
            "CRC mismatch: expected 0xaabbccdd, got 0x11223344"
        );
    }

    #[test]
    fn error_is_error_trait() {
        let e: Box<dyn std::error::Error> = Box::new(SigilError::TruncatedInput);
        assert_eq!(e.to_string(), "truncated input");
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/types.rs sigil-rs/src/error.rs
git commit -m "feat(sigil-rs): types with conversions and error Display impls"
```

---

### Task 3: CRC32

**Files:**
- Create: `sigil-rs/src/crc32.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod crc32;`)

The CRC32 algorithm uses polynomial 0xEDB88320 (reflected ISO 3309), init 0xFFFFFFFF, finalize XOR 0xFFFFFFFF. This is the same polynomial as PNG. The Haskell reference is in `sigil-hs/src/Sigil/Core/Chunk.hs` lines 52-69.

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/crc32.rs` with tests only (implementation placeholder returns 0):

```rust
/// Compute CRC32 (ISO 3309 / PNG polynomial 0xEDB88320).
pub fn crc32(_data: &[u8]) -> u32 {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_is_zero() {
        assert_eq!(crc32(&[]), 0x00000000);
    }

    #[test]
    fn iend_matches_png_reference() {
        // "IEND" = [0x49, 0x45, 0x4E, 0x44]
        assert_eq!(crc32(&[0x49, 0x45, 0x4E, 0x44]), 0xAE426082);
    }

    #[test]
    fn known_ascii_string() {
        // CRC32 of "123456789" is 0xCBF43926 (standard test vector)
        assert_eq!(crc32(b"123456789"), 0xCBF43926);
    }

    #[test]
    fn single_byte() {
        // CRC32 of [0x00] is 0xD202EF8D
        assert_eq!(crc32(&[0x00]), 0xD202EF8D);
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod error;`:

```rust
mod crc32;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test crc32
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement CRC32**

Replace the entire `sigil-rs/src/crc32.rs` with:

```rust
/// CRC32 lookup table, polynomial 0xEDB88320 (reflected ISO 3309).
/// Built at compile time via const evaluation.
const CRC_TABLE: [u32; 256] = {
    let mut table = [0u32; 256];
    let mut i = 0u32;
    while i < 256 {
        let mut crc = i;
        let mut j = 0;
        while j < 8 {
            if crc & 1 == 1 {
                crc = 0xEDB88320 ^ (crc >> 1);
            } else {
                crc >>= 1;
            }
            j += 1;
        }
        table[i as usize] = crc;
        i += 1;
    }
    table
};

/// Compute CRC32 (ISO 3309 / PNG polynomial 0xEDB88320).
///
/// Matches the Haskell reference: `crc32` in `sigil-hs/src/Sigil/Core/Chunk.hs`.
/// Init: 0xFFFFFFFF, finalize: XOR 0xFFFFFFFF.
/// `crc32(&[]) == 0x00000000`, `crc32(b"IEND") == 0xAE426082`.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        let idx = ((crc ^ byte as u32) & 0xFF) as usize;
        crc = (crc >> 8) ^ CRC_TABLE[idx];
    }
    crc ^ 0xFFFF_FFFF
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_is_zero() {
        assert_eq!(crc32(&[]), 0x00000000);
    }

    #[test]
    fn iend_matches_png_reference() {
        assert_eq!(crc32(&[0x49, 0x45, 0x4E, 0x44]), 0xAE426082);
    }

    #[test]
    fn known_ascii_string() {
        assert_eq!(crc32(b"123456789"), 0xCBF43926);
    }

    #[test]
    fn single_byte() {
        assert_eq!(crc32(&[0x00]), 0xD202EF8D);
    }
}
```

- [ ] **Step 5: Run tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test crc32
```

Expected: all 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/crc32.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): CRC32 with const lookup table"
```

---

### Task 4: Chunk Parsing

**Files:**
- Create: `sigil-rs/src/chunk.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod chunk;`)

Chunk format (from Haskell `Reader.hs`): 4-byte ASCII tag + u32 BE payload length + payload bytes + u32 BE CRC32. Tags: SHDR, SMTA, SPAL, SDAT, SEND. Parsing reads chunks until SEND is found.

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/chunk.rs`:

```rust
use crate::crc32::crc32;
use crate::error::SigilError;

/// Known chunk tags in the Sigil format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Shdr,
    Smta,
    Spal,
    Sdat,
    Send,
}

/// A parsed chunk: tag + payload + stored CRC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    pub tag: Tag,
    pub payload: Vec<u8>,
    pub crc: u32,
}

pub fn tag_from_bytes(b: &[u8; 4]) -> Result<Tag, SigilError> {
    todo!()
}

pub fn verify_chunk(chunk: &Chunk) -> Result<(), SigilError> {
    todo!()
}

pub fn parse_chunks(data: &[u8]) -> Result<Vec<Chunk>, SigilError> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_from_bytes_known() {
        assert_eq!(tag_from_bytes(b"SHDR"), Ok(Tag::Shdr));
        assert_eq!(tag_from_bytes(b"SMTA"), Ok(Tag::Smta));
        assert_eq!(tag_from_bytes(b"SPAL"), Ok(Tag::Spal));
        assert_eq!(tag_from_bytes(b"SDAT"), Ok(Tag::Sdat));
        assert_eq!(tag_from_bytes(b"SEND"), Ok(Tag::Send));
    }

    #[test]
    fn tag_from_bytes_invalid() {
        assert_eq!(tag_from_bytes(b"XXXX"), Err(SigilError::InvalidTag));
    }

    #[test]
    fn verify_chunk_good() {
        let payload = vec![1, 2, 3];
        let crc = crc32(&payload);
        let chunk = Chunk { tag: Tag::Shdr, payload, crc };
        assert_eq!(verify_chunk(&chunk), Ok(()));
    }

    #[test]
    fn verify_chunk_bad() {
        let chunk = Chunk { tag: Tag::Shdr, payload: vec![1, 2, 3], crc: 0xDEADBEEF };
        assert!(verify_chunk(&chunk).is_err());
    }

    #[test]
    fn parse_chunks_send_only() {
        // SEND with 0-length payload, CRC of empty = 0x00000000
        let mut data = Vec::new();
        data.extend_from_slice(b"SEND");
        data.extend_from_slice(&0u32.to_be_bytes()); // length 0
        data.extend_from_slice(&0u32.to_be_bytes()); // CRC of empty
        let chunks = parse_chunks(&data).unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].tag, Tag::Send);
        assert!(chunks[0].payload.is_empty());
    }

    #[test]
    fn parse_chunks_shdr_then_send() {
        let payload = vec![0xAA, 0xBB];
        let payload_crc = crc32(&payload);
        let mut data = Vec::new();
        // SHDR chunk
        data.extend_from_slice(b"SHDR");
        data.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        data.extend_from_slice(&payload);
        data.extend_from_slice(&payload_crc.to_be_bytes());
        // SEND chunk
        data.extend_from_slice(b"SEND");
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(&0u32.to_be_bytes());

        let chunks = parse_chunks(&data).unwrap();
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].tag, Tag::Shdr);
        assert_eq!(chunks[0].payload, vec![0xAA, 0xBB]);
        assert_eq!(chunks[1].tag, Tag::Send);
    }

    #[test]
    fn parse_chunks_truncated() {
        let data = b"SHD"; // too short for tag
        assert_eq!(parse_chunks(data), Err(SigilError::TruncatedInput));
    }

    #[test]
    fn parse_chunks_bad_crc() {
        let payload = vec![0x01];
        let mut data = Vec::new();
        data.extend_from_slice(b"SHDR");
        data.extend_from_slice(&1u32.to_be_bytes());
        data.extend_from_slice(&payload);
        data.extend_from_slice(&0xDEADBEEFu32.to_be_bytes()); // wrong CRC
        data.extend_from_slice(b"SEND");
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(&0u32.to_be_bytes());

        let result = parse_chunks(&data);
        assert!(matches!(result, Err(SigilError::CrcMismatch { .. })));
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod crc32;`:

```rust
mod chunk;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test chunk
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement chunk.rs**

Replace `sigil-rs/src/chunk.rs` (keeping the tests at the bottom) — replace only the three `todo!()` functions:

```rust
use crate::crc32::crc32;
use crate::error::SigilError;

/// Known chunk tags in the Sigil format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Shdr,
    Smta,
    Spal,
    Sdat,
    Send,
}

/// A parsed chunk: tag + payload + stored CRC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    pub tag: Tag,
    pub payload: Vec<u8>,
    pub crc: u32,
}

/// Helper: read a u32 big-endian from a slice at the given offset.
/// Returns TruncatedInput if not enough bytes.
fn read_u32_be(data: &[u8], offset: usize) -> Result<u32, SigilError> {
    if offset + 4 > data.len() {
        return Err(SigilError::TruncatedInput);
    }
    Ok(u32::from_be_bytes([
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
    ]))
}

pub fn tag_from_bytes(b: &[u8; 4]) -> Result<Tag, SigilError> {
    match b {
        b"SHDR" => Ok(Tag::Shdr),
        b"SMTA" => Ok(Tag::Smta),
        b"SPAL" => Ok(Tag::Spal),
        b"SDAT" => Ok(Tag::Sdat),
        b"SEND" => Ok(Tag::Send),
        _ => Err(SigilError::InvalidTag),
    }
}

pub fn verify_chunk(chunk: &Chunk) -> Result<(), SigilError> {
    let computed = crc32(&chunk.payload);
    if computed == chunk.crc {
        Ok(())
    } else {
        Err(SigilError::CrcMismatch {
            expected: chunk.crc,
            actual: computed,
        })
    }
}

/// Parse a sequence of chunks from raw bytes. Verifies each chunk's CRC.
/// Stops after reading the SEND chunk.
pub fn parse_chunks(data: &[u8]) -> Result<Vec<Chunk>, SigilError> {
    let mut chunks = Vec::new();
    let mut pos = 0;

    loop {
        // Read 4-byte tag
        if pos + 4 > data.len() {
            return Err(SigilError::TruncatedInput);
        }
        let tag_bytes: [u8; 4] = [data[pos], data[pos + 1], data[pos + 2], data[pos + 3]];
        let tag = tag_from_bytes(&tag_bytes)?;
        pos += 4;

        // Read u32 BE payload length
        let len = read_u32_be(data, pos)? as usize;
        pos += 4;

        // Read payload
        if pos + len > data.len() {
            return Err(SigilError::TruncatedInput);
        }
        let payload = data[pos..pos + len].to_vec();
        pos += len;

        // Read u32 BE CRC
        let crc = read_u32_be(data, pos)?;
        pos += 4;

        let chunk = Chunk { tag, payload, crc };
        verify_chunk(&chunk)?;
        let is_end = tag == Tag::Send;
        chunks.push(chunk);

        if is_end {
            break;
        }
    }

    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_from_bytes_known() {
        assert_eq!(tag_from_bytes(b"SHDR"), Ok(Tag::Shdr));
        assert_eq!(tag_from_bytes(b"SMTA"), Ok(Tag::Smta));
        assert_eq!(tag_from_bytes(b"SPAL"), Ok(Tag::Spal));
        assert_eq!(tag_from_bytes(b"SDAT"), Ok(Tag::Sdat));
        assert_eq!(tag_from_bytes(b"SEND"), Ok(Tag::Send));
    }

    #[test]
    fn tag_from_bytes_invalid() {
        assert_eq!(tag_from_bytes(b"XXXX"), Err(SigilError::InvalidTag));
    }

    #[test]
    fn verify_chunk_good() {
        let payload = vec![1, 2, 3];
        let crc = crc32(&payload);
        let chunk = Chunk { tag: Tag::Shdr, payload, crc };
        assert_eq!(verify_chunk(&chunk), Ok(()));
    }

    #[test]
    fn verify_chunk_bad() {
        let chunk = Chunk { tag: Tag::Shdr, payload: vec![1, 2, 3], crc: 0xDEADBEEF };
        assert!(verify_chunk(&chunk).is_err());
    }

    #[test]
    fn parse_chunks_send_only() {
        let mut data = Vec::new();
        data.extend_from_slice(b"SEND");
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(&0u32.to_be_bytes());
        let chunks = parse_chunks(&data).unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].tag, Tag::Send);
        assert!(chunks[0].payload.is_empty());
    }

    #[test]
    fn parse_chunks_shdr_then_send() {
        let payload = vec![0xAA, 0xBB];
        let payload_crc = crc32(&payload);
        let mut data = Vec::new();
        data.extend_from_slice(b"SHDR");
        data.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        data.extend_from_slice(&payload);
        data.extend_from_slice(&payload_crc.to_be_bytes());
        data.extend_from_slice(b"SEND");
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(&0u32.to_be_bytes());

        let chunks = parse_chunks(&data).unwrap();
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].tag, Tag::Shdr);
        assert_eq!(chunks[0].payload, vec![0xAA, 0xBB]);
        assert_eq!(chunks[1].tag, Tag::Send);
    }

    #[test]
    fn parse_chunks_truncated() {
        let data = b"SHD";
        assert_eq!(parse_chunks(data), Err(SigilError::TruncatedInput));
    }

    #[test]
    fn parse_chunks_bad_crc() {
        let payload = vec![0x01];
        let mut data = Vec::new();
        data.extend_from_slice(b"SHDR");
        data.extend_from_slice(&1u32.to_be_bytes());
        data.extend_from_slice(&payload);
        data.extend_from_slice(&0xDEADBEEFu32.to_be_bytes());
        data.extend_from_slice(b"SEND");
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(&0u32.to_be_bytes());

        let result = parse_chunks(&data);
        assert!(matches!(result, Err(SigilError::CrcMismatch { .. })));
    }
}
```

- [ ] **Step 5: Run tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test chunk
```

Expected: all 7 chunk tests pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/chunk.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): chunk parsing with CRC32 verification"
```

---

### Task 5: Unzigzag

**Files:**
- Create: `sigil-rs/src/zigzag.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod zigzag;`)

The Haskell reference is in `sigil-hs/src/Sigil/Codec/ZigZag.hs`. The decode direction only needs `unzigzag`. The formula: `unzigzag(n) = (n >> 1) ^ -(n & 1)`, mapping unsigned to signed (0->0, 1->-1, 2->1, 3->-2, 4->2, ...).

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/zigzag.rs`:

```rust
/// Decode a zigzag-encoded unsigned value back to a signed residual.
///
/// Mapping: 0->0, 1->-1, 2->1, 3->-2, 4->2, ...
/// Formula: `(n >> 1) ^ -(n & 1)` (arithmetic, using wrapping ops for u16->i16).
///
/// Matches Haskell: `unzigzag` in `sigil-hs/src/Sigil/Codec/ZigZag.hs`.
pub fn unzigzag(n: u16) -> i16 {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_values() {
        assert_eq!(unzigzag(0), 0);
        assert_eq!(unzigzag(1), -1);
        assert_eq!(unzigzag(2), 1);
        assert_eq!(unzigzag(3), -2);
        assert_eq!(unzigzag(4), 2);
        assert_eq!(unzigzag(5), -3);
        assert_eq!(unzigzag(510), 255);
        assert_eq!(unzigzag(511), -256);
    }

    #[test]
    fn zero_maps_to_zero() {
        assert_eq!(unzigzag(0), 0);
    }

    #[test]
    fn odd_inputs_are_negative() {
        for n in (1..=99u16).step_by(2) {
            assert!(unzigzag(n) < 0, "unzigzag({n}) should be negative");
        }
    }

    #[test]
    fn even_nonzero_inputs_are_positive() {
        for n in (2..=100u16).step_by(2) {
            assert!(unzigzag(n) > 0, "unzigzag({n}) should be positive");
        }
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod chunk;`:

```rust
mod zigzag;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test zigzag
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement unzigzag**

Replace the `unzigzag` function body in `sigil-rs/src/zigzag.rs` (keep the doc comment and tests unchanged):

```rust
pub fn unzigzag(n: u16) -> i16 {
    ((n >> 1) as i16) ^ (-((n & 1) as i16))
}
```

- [ ] **Step 5: Add proptest for round-trip**

We need a `zigzag` test helper (encode direction) to verify the round-trip property. Append to the `mod tests` block in `sigil-rs/src/zigzag.rs`:

```rust
    /// Test helper: zigzag encode (not part of public API — encode-only).
    fn zigzag_encode(n: i16) -> u16 {
        ((n << 1) ^ (n >> 15)) as u16
    }

    use proptest::prelude::*;

    proptest! {
        #[test]
        fn roundtrip_unzigzag(n in -255i16..=255) {
            let encoded = zigzag_encode(n);
            let decoded = unzigzag(encoded);
            prop_assert_eq!(decoded, n);
        }

        #[test]
        fn roundtrip_full_range(n in i16::MIN..=i16::MAX) {
            let encoded = zigzag_encode(n);
            let decoded = unzigzag(encoded);
            prop_assert_eq!(decoded, n);
        }
    }
```

- [ ] **Step 6: Run all tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test zigzag
```

Expected: all tests pass (unit tests + proptest).

- [ ] **Step 7: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/zigzag.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): unzigzag decoder with proptest round-trip"
```

---

### Task 6: Untokenize

**Files:**
- Create: `sigil-rs/src/token.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod token;`)

The Haskell reference is in `sigil-hs/src/Sigil/Codec/Token.hs`. The decode direction only needs `untokenize`: expand `ZeroRun(n)` to `n` zeros, `Value(v)` to `[v]`.

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/token.rs`:

```rust
/// A token in the compressed stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Token {
    /// A run of `n` consecutive zero values.
    ZeroRun(u16),
    /// A single non-zero value (or zero in a non-run context).
    Value(u16),
}

/// Expand tokens back to a flat vector of u16 values.
///
/// `ZeroRun(n)` produces `n` zeros. `Value(v)` produces `[v]`.
///
/// Matches Haskell: `untokenize` in `sigil-hs/src/Sigil/Codec/Token.hs`.
pub fn untokenize(tokens: &[Token]) -> Vec<u16> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty() {
        assert_eq!(untokenize(&[]), vec![]);
    }

    #[test]
    fn single_value() {
        assert_eq!(untokenize(&[Token::Value(42)]), vec![42]);
    }

    #[test]
    fn single_zero_run() {
        assert_eq!(untokenize(&[Token::ZeroRun(5)]), vec![0, 0, 0, 0, 0]);
    }

    #[test]
    fn mixed() {
        let tokens = &[Token::ZeroRun(3), Token::Value(7), Token::ZeroRun(2), Token::Value(9)];
        assert_eq!(untokenize(tokens), vec![0, 0, 0, 7, 0, 0, 9]);
    }

    #[test]
    fn zero_run_of_one() {
        assert_eq!(untokenize(&[Token::ZeroRun(1)]), vec![0]);
    }

    #[test]
    fn multiple_values() {
        let tokens = &[Token::Value(1), Token::Value(2), Token::Value(3)];
        assert_eq!(untokenize(tokens), vec![1, 2, 3]);
    }

    #[test]
    fn value_zero_is_valid() {
        // TValue can hold zero — it's a distinct encoding from ZeroRun
        assert_eq!(untokenize(&[Token::Value(0)]), vec![0]);
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod zigzag;`:

```rust
mod token;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test token
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement untokenize**

Replace the `untokenize` function body in `sigil-rs/src/token.rs`:

```rust
pub fn untokenize(tokens: &[Token]) -> Vec<u16> {
    let mut out = Vec::new();
    for &tok in tokens {
        match tok {
            Token::ZeroRun(n) => {
                out.extend(std::iter::repeat(0u16).take(n as usize));
            }
            Token::Value(v) => {
                out.push(v);
            }
        }
    }
    out
}
```

- [ ] **Step 5: Add proptest round-trip**

Append to the `mod tests` block in `sigil-rs/src/token.rs`:

```rust
    /// Test helper: tokenize (encode direction, not public API).
    fn tokenize(values: &[u16]) -> Vec<Token> {
        let mut tokens = Vec::new();
        let mut i = 0;
        while i < values.len() {
            if values[i] == 0 {
                let start = i;
                while i < values.len() && values[i] == 0 && (i - start) < u16::MAX as usize {
                    i += 1;
                }
                tokens.push(Token::ZeroRun((i - start) as u16));
            } else {
                tokens.push(Token::Value(values[i]));
                i += 1;
            }
        }
        tokens
    }

    use proptest::prelude::*;

    proptest! {
        #[test]
        fn roundtrip(values in proptest::collection::vec(0u16..512, 0..200)) {
            let tokens = tokenize(&values);
            let recovered = untokenize(&tokens);
            prop_assert_eq!(recovered, values);
        }
    }
```

- [ ] **Step 6: Run all tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test token
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/token.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): untokenize with proptest round-trip"
```

---

### Task 7: Rice Decode (BitReader + Token Stream Decoder)

**Files:**
- Create: `sigil-rs/src/rice.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod rice;`)

The Haskell reference is in `sigil-hs/src/Sigil/Codec/Rice.hs` (BitReader, riceDecode) and `sigil-hs/src/Sigil/Codec/Pipeline.hs` (decodeTokenStream, decodeSamples). The block size is 64.

This is the most complex module. It contains:
1. `BitReader` — MSB-first bit reader over a byte slice
2. `rice_decode` — decode one Rice-coded value
3. `decode_token_stream` — decode the entire token stream from SDAT payload bytes

- [ ] **Step 1: Write BitReader tests**

Create `sigil-rs/src/rice.rs`:

```rust
use crate::token::Token;

pub const BLOCK_SIZE: usize = 64;

/// MSB-first bit reader over a byte slice.
///
/// Bit ordering matches Haskell: bit position 0 = bit 7 of byte (MSB first).
/// `readBit` in `sigil-hs/src/Sigil/Codec/Rice.hs`.
pub struct BitReader<'a> {
    data: &'a [u8],
    byte_idx: usize,
    bit_pos: u8, // 0..7, next bit to read within current byte
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BitReader { data, byte_idx: 0, bit_pos: 0 }
    }

    /// Read a single bit. Returns true for 1, false for 0.
    pub fn read_bit(&mut self) -> bool {
        todo!()
    }

    /// Read `n` bits as a u16 (MSB first, max 16 bits).
    pub fn read_bits(&mut self, n: u8) -> u16 {
        todo!()
    }
}

/// Rice-decode a single value with parameter `k`.
///
/// Reads unary-coded quotient (count 1-bits until 0-bit), then `k` bits of remainder.
/// `val = (q << k) | remainder`
///
/// Matches Haskell: `riceDecode` in `sigil-hs/src/Sigil/Codec/Rice.hs`.
pub fn rice_decode(k: u8, reader: &mut BitReader) -> u16 {
    todo!()
}

/// Decode the full token stream from SDAT payload bytes.
///
/// Format: [16-bit numBlocks] [4-bit k per block] [token bitstream]
/// Token bitstream: 1-bit flag per token. 1 = TValue (Rice-decode with current k),
/// 0 = TZeroRun (read 16-bit run length).
/// Block tracking: advance to next k after every BLOCK_SIZE (64) TValues.
///
/// Matches Haskell: `decodeTokenStream` + `decodeSamples` in
/// `sigil-hs/src/Sigil/Codec/Pipeline.hs`.
pub fn decode_token_stream(data: &[u8], total_samples: usize) -> Vec<Token> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitreader_single_byte() {
        // 0xB2 = 1011_0010
        let mut r = BitReader::new(&[0xB2]);
        assert!(r.read_bit());   // 1
        assert!(!r.read_bit());  // 0
        assert!(r.read_bit());   // 1
        assert!(r.read_bit());   // 1
        assert!(!r.read_bit());  // 0
        assert!(!r.read_bit());  // 0
        assert!(r.read_bit());   // 1
        assert!(!r.read_bit());  // 0
    }

    #[test]
    fn bitreader_crosses_byte_boundary() {
        // [0xFF, 0x00] = 1111_1111 0000_0000
        let mut r = BitReader::new(&[0xFF, 0x00]);
        for _ in 0..8 { assert!(r.read_bit()); }
        for _ in 0..8 { assert!(!r.read_bit()); }
    }

    #[test]
    fn bitreader_read_bits() {
        // 0xAB = 1010_1011, read 4 bits = 0b1010 = 10, then 4 bits = 0b1011 = 11
        let mut r = BitReader::new(&[0xAB]);
        assert_eq!(r.read_bits(4), 10);
        assert_eq!(r.read_bits(4), 11);
    }

    #[test]
    fn bitreader_read_16_bits() {
        // [0x12, 0x34] -> read_bits(16) = 0x1234
        let mut r = BitReader::new(&[0x12, 0x34]);
        assert_eq!(r.read_bits(16), 0x1234);
    }

    #[test]
    fn rice_decode_k0_value0() {
        // k=0: unary for q, 0 bits of remainder. Value 0 = just a 0-bit (q=0).
        let mut r = BitReader::new(&[0x00]); // 0000_0000
        assert_eq!(rice_decode(0, &mut r), 0);
    }

    #[test]
    fn rice_decode_k0_value3() {
        // k=0: value 3 = unary 111_0 (q=3, remainder=0)
        let mut r = BitReader::new(&[0xE0]); // 1110_0000
        assert_eq!(rice_decode(0, &mut r), 3);
    }

    #[test]
    fn rice_decode_k2_value5() {
        // k=2: value 5. q = 5 >> 2 = 1. remainder = 5 & 0b11 = 0b01.
        // Encoded: unary 1_0 (q=1) then 2-bit remainder 01 = 1_0_01 = 0b1001_....
        let mut r = BitReader::new(&[0b1001_0000]);
        assert_eq!(rice_decode(2, &mut r), 5);
    }

    #[test]
    fn rice_decode_k4_value0() {
        // k=4: value 0. q=0. unary: 0. remainder: 0000.
        // Encoded: 0_0000_... = 0b0000_0...
        let mut r = BitReader::new(&[0b0000_0000]);
        assert_eq!(rice_decode(4, &mut r), 0);
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod token;`:

```rust
mod rice;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test rice
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement BitReader**

Replace the `read_bit` and `read_bits` method bodies in `sigil-rs/src/rice.rs`:

```rust
impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BitReader { data, byte_idx: 0, bit_pos: 0 }
    }

    pub fn read_bit(&mut self) -> bool {
        let byte = self.data[self.byte_idx];
        let bit = (byte >> (7 - self.bit_pos)) & 1 == 1;
        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.byte_idx += 1;
            self.bit_pos = 0;
        }
        bit
    }

    pub fn read_bits(&mut self, n: u8) -> u16 {
        let mut val: u16 = 0;
        for _ in 0..n {
            val = (val << 1) | (self.read_bit() as u16);
        }
        val
    }
}
```

- [ ] **Step 5: Run BitReader tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test rice::tests::bitreader
```

Expected: all 4 bitreader tests pass; rice_decode tests still fail.

- [ ] **Step 6: Implement rice_decode**

Replace the `rice_decode` function body in `sigil-rs/src/rice.rs`:

```rust
pub fn rice_decode(k: u8, reader: &mut BitReader) -> u16 {
    // Read unary: count 1-bits until a 0-bit
    let mut q: u16 = 0;
    while reader.read_bit() {
        q += 1;
    }
    // Read k-bit remainder
    let remainder = if k > 0 { reader.read_bits(k) } else { 0 };
    (q << k) | remainder
}
```

- [ ] **Step 7: Run rice_decode tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test rice::tests::rice_decode
```

Expected: all 4 rice_decode tests pass.

- [ ] **Step 8: Add decode_token_stream tests**

Append these tests to the `mod tests` block in `sigil-rs/src/rice.rs`:

```rust
    #[test]
    fn decode_token_stream_empty() {
        // 0 blocks, 0 total samples → no tokens
        // numBlocks = 0 (16-bit): 0x0000
        let data = [0x00, 0x00];
        let tokens = decode_token_stream(&data, 0);
        assert!(tokens.is_empty());
    }

    #[test]
    fn decode_token_stream_single_zero_run() {
        // We need: numBlocks=1, k[0]=0 (4 bits), then flag=0 (TZeroRun), runLen=5 (16 bits)
        // Bit layout:
        //   numBlocks: 0000_0000_0000_0001 (16 bits)
        //   k[0]:      0000                (4 bits)
        //   flag:      0                   (1 bit = TZeroRun)
        //   runLen:    0000_0000_0000_0101  (16 bits = 5)
        // Total: 16 + 4 + 1 + 16 = 37 bits = 5 bytes (padded)
        //
        // Byte 0-1: 0000_0001 = numBlocks high byte 0x00, low byte 0x01
        // Then 4 bits k=0: 0000
        // Then 1 bit flag=0: 0
        // Then 16 bits runLen=5: 0000_0000_0000_0101
        //
        // Bit stream after numBlocks (starting byte 2):
        //   0000 | 0 | 0000_0000_0000_0101
        //   byte2: 0000_0000 = 0x00
        //   byte3: 0000_0010 = 0x02
        //   byte4: 1000_0000 = 0x80 (the '1' from runLen=5 bit, then pad)
        //
        // Wait, let me be more careful. After reading 16 bits for numBlocks:
        //   we consumed bytes 0,1 (all 16 bits used). bit_pos=0 on byte 2.
        //   k[0] = 4 bits from byte 2: top 4 bits of byte 2.
        //   flag = 1 bit: bit 4 of byte 2.
        //   runLen = 16 bits: bit 5,6,7 of byte 2 + all of byte 3 + bits 0..4 of byte 4
        //
        // k[0]=0: 0000
        // flag=0: 0
        // runLen=5 = 0b0000000000000101
        //   bits: 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 1
        //
        // byte 2: [k=0000] [flag=0] [runLen bits 0-2 = 000] = 0000_0000 = 0x00
        // byte 3: [runLen bits 3-10 = 0000_0000] = 0x00
        // byte 4: [runLen bits 11-15 = 00101] [pad 000] = 0010_1000 = 0x28
        let data = [0x00, 0x01, 0x00, 0x00, 0x28];
        let tokens = decode_token_stream(&data, 5);
        assert_eq!(tokens, vec![Token::ZeroRun(5)]);
    }

    #[test]
    fn decode_token_stream_single_value_k0() {
        // numBlocks=1, k[0]=0, flag=1 (TValue), rice_decode(k=0): unary for val.
        // Value=0: unary 0 (just a 0-bit, q=0)
        //
        // numBlocks=1: 0x00 0x01
        // k[0]=0: 0000
        // flag=1: 1
        // rice value=0: 0 (unary: single 0-bit, q=0, k=0 so no remainder)
        //
        // byte 2: [0000] [1] [0] [pad 00] = 0000_1000 = 0x08
        let data = [0x00, 0x01, 0x08];
        let tokens = decode_token_stream(&data, 1);
        assert_eq!(tokens, vec![Token::Value(0)]);
    }
```

- [ ] **Step 9: Implement decode_token_stream**

Replace the `decode_token_stream` function body in `sigil-rs/src/rice.rs`:

```rust
pub fn decode_token_stream(data: &[u8], total_samples: usize) -> Vec<Token> {
    if total_samples == 0 {
        return Vec::new();
    }
    let mut reader = BitReader::new(data);

    // Read number of blocks (16-bit)
    let num_blocks = reader.read_bits(16) as usize;

    // Read k values (4 bits each)
    let mut ks: Vec<u8> = Vec::with_capacity(num_blocks);
    for _ in 0..num_blocks {
        ks.push(reader.read_bits(4) as u8);
    }

    // Decode tokens
    let mut tokens = Vec::new();
    let mut remaining = total_samples as isize;
    let mut k_idx: usize = 0;
    let mut tval_pos: usize = 0;

    while remaining > 0 {
        let k = if k_idx < ks.len() { ks[k_idx] } else { 0 };
        let flag = reader.read_bit();

        if flag {
            // TValue: Rice-decode value
            let val = rice_decode(k, &mut reader);
            tokens.push(Token::Value(val));
            remaining -= 1;
            tval_pos += 1;
            if tval_pos >= BLOCK_SIZE {
                k_idx += 1;
                tval_pos = 0;
            }
        } else {
            // TZeroRun: read 16-bit run length
            let run_len = reader.read_bits(16);
            tokens.push(Token::ZeroRun(run_len));
            remaining -= run_len as isize;
        }
    }

    tokens
}
```

- [ ] **Step 10: Run all rice tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test rice
```

Expected: all tests pass.

- [ ] **Step 11: Add proptest for Rice round-trip**

Append to the `mod tests` block in `sigil-rs/src/rice.rs`:

```rust
    /// Test helper: Rice-encode a single value (not public API — encode direction).
    fn rice_encode(k: u8, val: u16) -> Vec<u8> {
        let q = val >> k;
        let remainder = val & ((1u16 << k) - if k > 0 { 0 } else { 1 });
        // We need a simple bit writer
        let mut bits: Vec<bool> = Vec::new();
        // Unary: q ones then a zero
        for _ in 0..q {
            bits.push(true);
        }
        bits.push(false);
        // k-bit remainder, MSB first
        for i in (0..k).rev() {
            bits.push((remainder >> i) & 1 == 1);
        }
        // Pack into bytes
        let mut bytes = Vec::new();
        for chunk in bits.chunks(8) {
            let mut byte = 0u8;
            for (i, &b) in chunk.iter().enumerate() {
                if b {
                    byte |= 1 << (7 - i);
                }
            }
            bytes.push(byte);
        }
        bytes
    }

    use proptest::prelude::*;

    proptest! {
        #[test]
        fn rice_roundtrip(k in 0u8..=8, val in 0u16..4096) {
            let encoded = rice_encode(k, val);
            let mut reader = BitReader::new(&encoded);
            let decoded = rice_decode(k, &mut reader);
            prop_assert_eq!(decoded, val);
        }
    }
```

- [ ] **Step 12: Run all tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test rice
```

Expected: all tests pass.

- [ ] **Step 13: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/rice.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): BitReader, rice_decode, decode_token_stream"
```

---

### Task 8: Predict & Unpredict

**Files:**
- Create: `sigil-rs/src/predict.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod predict;`)

The Haskell reference is in `sigil-hs/src/Sigil/Codec/Predict.hs`. We need:
- `predict(pid, a, b, c) -> u8` — all 6 fixed predictors
- `paeth(a, b, c) -> u8`
- `unpredict_row(pid, prev_row, residuals, channels) -> Vec<u8>` — builds output left-to-right
- `unpredict_image(header, predictor_ids, residual_rows) -> Vec<u8>` — all rows to flat pixels

Key subtlety: `unpredict_row` uses the **already-built** output as the left neighbor `a`, not the residuals. This is causal reconstruction.

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/predict.rs`:

```rust
use crate::types::{Header, PredictorId};

/// Predict a pixel value given its neighbors.
///
/// - `a`: left neighbor (same row, `channels` positions earlier in output)
/// - `b`: above neighbor (same column in previous row)
/// - `c`: above-left neighbor
///
/// Matches Haskell: `predict` in `sigil-hs/src/Sigil/Codec/Predict.hs`.
pub fn predict(pid: PredictorId, a: u8, b: u8, c: u8) -> u8 {
    todo!()
}

/// Paeth predictor — pick the neighbor closest to p = a + b - c.
pub fn paeth(a: u8, b: u8, c: u8) -> u8 {
    todo!()
}

/// Reconstruct one row from residuals and the previous row.
///
/// Builds output left-to-right. For each position `i`:
/// - `a` = output[i - channels] if i >= channels, else 0 (from already-built output)
/// - `b` = prev_row[i] (above neighbor)
/// - `c` = prev_row[i - channels] if i >= channels, else 0
/// - `output[i] = (predict(pid, a, b, c) as i16 + residuals[i]) as u8`
pub fn unpredict_row(pid: PredictorId, prev_row: &[u8], residuals: &[i16], ch: usize) -> Vec<u8> {
    todo!()
}

/// Reconstruct the full image from per-row residuals.
///
/// Returns flat row-major pixel data.
pub fn unpredict_image(
    header: &Header,
    predictor_ids: &[PredictorId],
    residual_rows: &[Vec<i16>],
) -> Vec<u8> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::*;

    // ── predict tests ─────────────────────────

    #[test]
    fn predict_none_always_zero() {
        assert_eq!(predict(PredictorId::None, 100, 200, 50), 0);
        assert_eq!(predict(PredictorId::None, 0, 0, 0), 0);
    }

    #[test]
    fn predict_sub_returns_a() {
        assert_eq!(predict(PredictorId::Sub, 42, 200, 50), 42);
    }

    #[test]
    fn predict_up_returns_b() {
        assert_eq!(predict(PredictorId::Up, 42, 200, 50), 200);
    }

    #[test]
    fn predict_average() {
        // (100 + 200) / 2 = 150
        assert_eq!(predict(PredictorId::Average, 100, 200, 50), 150);
        // (1 + 0) / 2 = 0 (integer division)
        assert_eq!(predict(PredictorId::Average, 1, 0, 0), 0);
        // (255 + 255) / 2 = 255
        assert_eq!(predict(PredictorId::Average, 255, 255, 0), 255);
    }

    #[test]
    fn predict_paeth_basic() {
        // p = 100 + 100 - 100 = 100. pa=0, pb=0, pc=0. pa<=pb && pa<=pc → a=100
        assert_eq!(predict(PredictorId::Paeth, 100, 100, 100), 100);
        // p = 10 + 200 - 5 = 205. pa=|205-10|=195, pb=|205-200|=5, pc=|205-5|=200
        // pb <= pc → b=200
        assert_eq!(predict(PredictorId::Paeth, 10, 200, 5), 200);
    }

    #[test]
    fn predict_gradient() {
        // a + b - c = 100 + 200 - 50 = 250, clamp(250, 0, 255) = 250
        assert_eq!(predict(PredictorId::Gradient, 100, 200, 50), 250);
        // a + b - c = 200 + 200 - 50 = 350, clamp to 255
        assert_eq!(predict(PredictorId::Gradient, 200, 200, 50), 255);
        // a + b - c = 0 + 0 - 50 = -50, clamp to 0
        assert_eq!(predict(PredictorId::Gradient, 0, 0, 50), 0);
    }

    #[test]
    fn paeth_selects_a() {
        // p = 10 + 10 - 10 = 10. pa=0, pb=0, pc=0. pa<=pb && pa<=pc → a
        assert_eq!(paeth(10, 10, 10), 10);
    }

    #[test]
    fn paeth_selects_b() {
        // p = 0 + 100 - 0 = 100. pa=|100-0|=100, pb=|100-100|=0, pc=|100-0|=100
        // pb <= pc → b=100
        assert_eq!(paeth(0, 100, 0), 100);
    }

    #[test]
    fn paeth_selects_c() {
        // p = 0 + 0 - 100 = -100. pa=|-100-0|=100, pb=|-100-0|=100, pc=|-100-100|=200
        // pa <= pb && pa <= pc → a=0
        // Actually: pa=100, pb=100, pc=200. pa<=pb(100<=100=true) && pa<=pc(100<=200=true) → a=0
        assert_eq!(paeth(0, 0, 100), 0);
    }

    // ── unpredict_row tests ───────────────────

    #[test]
    fn unpredict_row_none_is_residuals() {
        // PNone predicts 0, so output = residuals (cast i16 -> u8)
        let prev = vec![0, 0, 0];
        let residuals = vec![10, 20, 30];
        let result = unpredict_row(PredictorId::None, &prev, &residuals, 3);
        assert_eq!(result, vec![10, 20, 30]);
    }

    #[test]
    fn unpredict_row_sub_first_pixel_no_left() {
        // First pixel: a=0 (no left neighbor), so predict=0, output=residual
        // Second pixel: a=output[0], so predict=output[0]
        let prev = vec![0, 0]; // single-channel, 2 pixels
        let residuals = vec![100, 5]; // ch=1
        let result = unpredict_row(PredictorId::Sub, &prev, &residuals, 1);
        // pixel 0: predict(Sub, a=0, b=0, c=0) = 0. output[0] = (0 + 100) as u8 = 100
        // pixel 1: predict(Sub, a=100, b=0, c=0) = 100. output[1] = (100 + 5) as u8 = 105
        assert_eq!(result, vec![100, 105]);
    }

    #[test]
    fn unpredict_row_up() {
        let prev = vec![50, 60, 70];
        let residuals = vec![1, 2, 3];
        let result = unpredict_row(PredictorId::Up, &prev, &residuals, 1);
        // pixel 0: predict(Up, 0, 50, 0) = 50. output = 50 + 1 = 51
        // pixel 1: predict(Up, 51, 60, 50) = 60. output = 60 + 2 = 62
        // pixel 2: predict(Up, 62, 70, 60) = 70. output = 70 + 3 = 73
        assert_eq!(result, vec![51, 62, 73]);
    }

    #[test]
    fn unpredict_row_rgb_channels() {
        // 2 pixels, 3 channels (RGB). channels=3.
        // a = output[i-3] for i>=3, else 0
        let prev = vec![0, 0, 0, 0, 0, 0];
        let residuals = vec![10, 20, 30, 5, 5, 5];
        let result = unpredict_row(PredictorId::Sub, &prev, &residuals, 3);
        // pixel 0 (i=0,1,2): a=0 each. output = [10, 20, 30]
        // pixel 1 (i=3,4,5): a=output[0]=10, a=output[1]=20, a=output[2]=30.
        //   output[3] = 10 + 5 = 15, output[4] = 20 + 5 = 25, output[5] = 30 + 5 = 35
        assert_eq!(result, vec![10, 20, 30, 15, 25, 35]);
    }

    // ── unpredict_image tests ─────────────────

    #[test]
    fn unpredict_image_single_row() {
        let header = Header {
            width: 3, height: 1,
            color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        };
        let pids = vec![PredictorId::None];
        let residuals = vec![vec![10, 20, 30]];
        let pixels = unpredict_image(&header, &pids, &residuals);
        assert_eq!(pixels, vec![10, 20, 30]);
    }

    #[test]
    fn unpredict_image_two_rows_up() {
        let header = Header {
            width: 2, height: 2,
            color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight,
            predictor: PredictorId::Up,
        };
        let pids = vec![PredictorId::Up, PredictorId::Up];
        // Row 0 (prev=zeros): residuals=[100, 200] → pixels=[100, 200]
        // Row 1 (prev=[100,200]): residuals=[1, 2]
        //   pixel 0: predict(Up,a=0,b=100,c=0)=100. 100+1=101
        //   pixel 1: predict(Up,a=101,b=200,c=100)=200. 200+2=202
        let residuals = vec![vec![100, 200], vec![1, 2]];
        let pixels = unpredict_image(&header, &pids, &residuals);
        assert_eq!(pixels, vec![100, 200, 101, 202]);
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod rice;`:

```rust
mod predict;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test predict
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement predict, paeth, unpredict_row, unpredict_image**

Replace the function bodies in `sigil-rs/src/predict.rs` (keep signatures, doc comments, and tests):

```rust
use crate::types::{Header, PredictorId};

pub fn predict(pid: PredictorId, a: u8, b: u8, c: u8) -> u8 {
    match pid {
        PredictorId::None => 0,
        PredictorId::Sub => a,
        PredictorId::Up => b,
        PredictorId::Average => {
            ((a as u16 + b as u16) / 2) as u8
        }
        PredictorId::Paeth => paeth(a, b, c),
        PredictorId::Gradient => {
            let v = a as i32 + b as i32 - c as i32;
            v.clamp(0, 255) as u8
        }
        PredictorId::Adaptive => {
            panic!("adaptive is resolved per-row, not used directly in predict()")
        }
    }
}

pub fn paeth(a: u8, b: u8, c: u8) -> u8 {
    let p = a as i32 + b as i32 - c as i32;
    let pa = (p - a as i32).abs();
    let pb = (p - b as i32).abs();
    let pc = (p - c as i32).abs();
    if pa <= pb && pa <= pc {
        a
    } else if pb <= pc {
        b
    } else {
        c
    }
}

pub fn unpredict_row(pid: PredictorId, prev_row: &[u8], residuals: &[i16], ch: usize) -> Vec<u8> {
    let len = residuals.len();
    let mut output = Vec::with_capacity(len);
    for i in 0..len {
        let a = if i >= ch { output[i - ch] } else { 0u8 };
        let b = prev_row[i];
        let c = if i >= ch { prev_row[i - ch] } else { 0u8 };
        let predicted = predict(pid, a, b, c);
        let x = (predicted as i16).wrapping_add(residuals[i]) as u8;
        output.push(x);
    }
    output
}

pub fn unpredict_image(
    header: &Header,
    predictor_ids: &[PredictorId],
    residual_rows: &[Vec<i16>],
) -> Vec<u8> {
    let ch = header.channels();
    let row_len = header.row_bytes();
    let zero_row = vec![0u8; row_len];
    let mut pixels = Vec::with_capacity(row_len * header.height as usize);
    let mut prev_row: &[u8] = &zero_row;
    // We need to keep rows around to reference as prev_row
    let mut built_rows: Vec<Vec<u8>> = Vec::with_capacity(header.height as usize);

    for i in 0..residual_rows.len() {
        let pid = predictor_ids[i];
        let row = unpredict_row(pid, prev_row, &residual_rows[i], ch);
        pixels.extend_from_slice(&row);
        built_rows.push(row);
        prev_row = &built_rows[i];
    }

    pixels
}
```

- [ ] **Step 5: Run tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test predict
```

Expected: all tests pass.

- [ ] **Step 6: Add proptest for unpredict round-trip**

Append to the `mod tests` block in `sigil-rs/src/predict.rs`:

```rust
    /// Test helper: predict_row (encode direction, not public API).
    fn predict_row(pid: PredictorId, prev_row: &[u8], cur_row: &[u8], ch: usize) -> Vec<i16> {
        let mut residuals = Vec::with_capacity(cur_row.len());
        for i in 0..cur_row.len() {
            let a = if i >= ch { cur_row[i - ch] } else { 0 };
            let b = prev_row[i];
            let c = if i >= ch { prev_row[i - ch] } else { 0 };
            let predicted = predict(pid, a, b, c);
            residuals.push(cur_row[i] as i16 - predicted as i16);
        }
        residuals
    }

    use proptest::prelude::*;

    fn arb_fixed_predictor() -> impl Strategy<Value = PredictorId> {
        prop_oneof![
            Just(PredictorId::None),
            Just(PredictorId::Sub),
            Just(PredictorId::Up),
            Just(PredictorId::Average),
            Just(PredictorId::Paeth),
            Just(PredictorId::Gradient),
        ]
    }

    proptest! {
        #[test]
        fn unpredict_roundtrip(
            pid in arb_fixed_predictor(),
            row in proptest::collection::vec(0u8..=255, 1..50),
        ) {
            let ch = 1;
            let prev_row = vec![0u8; row.len()];
            let residuals = predict_row(pid, &prev_row, &row, ch);
            let recovered = unpredict_row(pid, &prev_row, &residuals, ch);
            prop_assert_eq!(recovered, row);
        }

        #[test]
        fn unpredict_roundtrip_with_prev(
            pid in arb_fixed_predictor(),
            prev in proptest::collection::vec(0u8..=255, 3..30),
            row_vals in proptest::collection::vec(0u8..=255, 0..1),
        ) {
            // Make row same length as prev
            let row: Vec<u8> = (0..prev.len()).map(|i| {
                if i < row_vals.len() { row_vals[i] } else { ((i * 37) % 256) as u8 }
            }).collect();
            let ch = 1;
            let residuals = predict_row(pid, &prev, &row, ch);
            let recovered = unpredict_row(pid, &prev, &residuals, ch);
            prop_assert_eq!(recovered, row);
        }
    }
```

- [ ] **Step 7: Run all tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test predict
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/predict.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): predict + unpredict with proptest round-trip"
```

---

### Task 9: Pipeline Decompress

**Files:**
- Create: `sigil-rs/src/pipeline.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod pipeline;`)

This module ties together: read predictor IDs (if adaptive) -> decode token stream -> untokenize -> unzigzag -> split into rows -> unpredict image -> flat pixels.

The Haskell reference is in `sigil-hs/src/Sigil/Codec/Pipeline.hs`, specifically `decodeData` and `decompressPipeline`.

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/pipeline.rs`:

```rust
use crate::error::SigilError;
use crate::predict::unpredict_image;
use crate::rice::decode_token_stream;
use crate::token::untokenize;
use crate::types::{Header, PredictorId};
use crate::zigzag::unzigzag;

/// Decompress an SDAT payload into raw pixel data.
///
/// Pipeline: read predictor IDs (if adaptive) → decode token stream
/// → untokenize → unzigzag → split into rows → unpredict → pixels.
///
/// Matches Haskell: `decompress` via `decompressPipeline` + `decodeData`
/// in `sigil-hs/src/Sigil/Codec/Pipeline.hs`.
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::*;

    // To test decompress, we need encoded payloads. The easiest way is to build
    // them by hand for tiny images, or validate against golden files (Task 12).
    // Here we test the pipeline with a known minimal case.

    #[test]
    fn decompress_all_zeros_grayscale() {
        // A 2x2 grayscale image of all zeros.
        // predictor=PNone, so no predictor ID bytes.
        // All residuals are 0 → all zigzag values are 0 → one big ZeroRun.
        // Total samples = 2 * 2 * 1 * 1 = 4
        //
        // Token stream: numBlocks=1, k[0]=0, then TZeroRun(4).
        // Bit layout:
        //   numBlocks=1: 0x00 0x01
        //   k[0]=0: 4 bits = 0000
        //   flag=0 (TZeroRun): 1 bit
        //   runLen=4: 16 bits = 0b0000_0000_0000_0100
        //
        // Byte 2: [0000][0][000] = 0x00
        // Byte 3: [0000_0000] = 0x00
        // Byte 4: [0010_0000] = 0x20
        let payload = vec![0x00, 0x01, 0x00, 0x00, 0x20];
        let header = Header {
            width: 2, height: 2,
            color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        };
        let pixels = decompress(&header, &payload).unwrap();
        assert_eq!(pixels, vec![0, 0, 0, 0]);
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod predict;`:

```rust
mod pipeline;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test pipeline
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement decompress**

Replace the `decompress` function body in `sigil-rs/src/pipeline.rs`:

```rust
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    let num_rows = header.height as usize;
    let ch = header.channels();
    let row_len = header.row_bytes();
    let total_samples = num_rows * row_len;

    // Step 1: Read predictor IDs (if adaptive)
    let (predictor_ids, token_data) = if header.predictor == PredictorId::Adaptive {
        if sdat_payload.len() < num_rows {
            return Err(SigilError::TruncatedInput);
        }
        let pids: Vec<PredictorId> = sdat_payload[..num_rows]
            .iter()
            .map(|&b| PredictorId::from_byte(b).ok_or(SigilError::InvalidPredictor(b)))
            .collect::<Result<Vec<_>, _>>()?;
        (pids, &sdat_payload[num_rows..])
    } else {
        (vec![header.predictor; num_rows], sdat_payload)
    };

    // Step 2: Decode token stream
    let tokens = decode_token_stream(token_data, total_samples);

    // Step 3: Untokenize → flat zigzag values
    let zigzag_values = untokenize(&tokens);

    // Step 4: Unzigzag → signed residuals
    let residuals: Vec<i16> = zigzag_values.iter().map(|&v| unzigzag(v)).collect();

    // Step 5: Split residuals into rows
    let residual_rows: Vec<Vec<i16>> = (0..num_rows)
        .map(|i| residuals[i * row_len..(i + 1) * row_len].to_vec())
        .collect();

    // Step 6: Unpredict → raw pixels
    let pixels = unpredict_image(header, &predictor_ids, &residual_rows);

    Ok(pixels)
}
```

- [ ] **Step 5: Run tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test pipeline
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/pipeline.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): pipeline decompress tying all codec stages"
```

---

### Task 10: Reader (.sgl File Parser)

**Files:**
- Create: `sigil-rs/src/reader.rs`
- Modify: `sigil-rs/src/lib.rs` (add `mod reader;`)

The Haskell reference is in `sigil-hs/src/Sigil/IO/Reader.hs`. This module parses the full `.sgl` file: magic, version, chunks, SHDR header decode, SDAT concatenation, decompress.

- [ ] **Step 1: Write tests first**

Create `sigil-rs/src/reader.rs`:

```rust
use crate::chunk::{parse_chunks, Tag};
use crate::error::SigilError;
use crate::pipeline::decompress;
use crate::types::*;

/// Six-byte magic: 0x89 S G L \r \n
const MAGIC: [u8; 6] = [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A];

/// Expected version: 0.2
const VERSION_MAJOR: u8 = 0;
const VERSION_MINOR: u8 = 2;

/// Decode a complete `.sgl` file from bytes.
///
/// Returns the header and flat row-major pixel data.
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError> {
    todo!()
}

/// Read only the header from a `.sgl` file (without decoding pixels).
pub fn read_header(data: &[u8]) -> Result<Header, SigilError> {
    todo!()
}

/// Parse a Header from an SHDR chunk payload (11 bytes).
fn decode_header(payload: &[u8]) -> Result<Header, SigilError> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crc32::crc32;

    /// Build a minimal valid .sgl file in memory.
    fn build_sgl(header: &Header, sdat_payload: &[u8]) -> Vec<u8> {
        let mut file = Vec::new();
        // Magic
        file.extend_from_slice(&MAGIC);
        // Version
        file.push(VERSION_MAJOR);
        file.push(VERSION_MINOR);
        // SHDR chunk
        let shdr_payload = encode_header(header);
        file.extend_from_slice(b"SHDR");
        file.extend_from_slice(&(shdr_payload.len() as u32).to_be_bytes());
        file.extend_from_slice(&shdr_payload);
        file.extend_from_slice(&crc32(&shdr_payload).to_be_bytes());
        // SDAT chunk
        file.extend_from_slice(b"SDAT");
        file.extend_from_slice(&(sdat_payload.len() as u32).to_be_bytes());
        file.extend_from_slice(sdat_payload);
        file.extend_from_slice(&crc32(sdat_payload).to_be_bytes());
        // SEND chunk
        file.extend_from_slice(b"SEND");
        file.extend_from_slice(&0u32.to_be_bytes());
        file.extend_from_slice(&crc32(&[]).to_be_bytes());
        file
    }

    /// Encode a header to SHDR payload bytes (test helper matching Writer.hs).
    fn encode_header(h: &Header) -> Vec<u8> {
        let mut v = Vec::with_capacity(11);
        v.extend_from_slice(&h.width.to_be_bytes());
        v.extend_from_slice(&h.height.to_be_bytes());
        v.push(match h.color_space {
            ColorSpace::Grayscale => 0,
            ColorSpace::GrayscaleAlpha => 1,
            ColorSpace::Rgb => 2,
            ColorSpace::Rgba => 3,
        });
        v.push(match h.bit_depth {
            BitDepth::Eight => 8,
            BitDepth::Sixteen => 16,
        });
        v.push(h.predictor.to_byte());
        v
    }

    #[test]
    fn decode_header_valid() {
        let h = Header {
            width: 100, height: 64,
            color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight,
            predictor: PredictorId::Paeth,
        };
        let payload = encode_header(&h);
        assert_eq!(payload.len(), 11);
        let parsed = decode_header(&payload).unwrap();
        assert_eq!(parsed, h);
    }

    #[test]
    fn decode_header_invalid_colorspace() {
        let mut payload = encode_header(&Header {
            width: 1, height: 1,
            color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        });
        payload[8] = 99; // corrupt colorspace byte
        assert_eq!(decode_header(&payload), Err(SigilError::InvalidColorSpace(99)));
    }

    #[test]
    fn decode_header_invalid_bitdepth() {
        let mut payload = encode_header(&Header {
            width: 1, height: 1,
            color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        });
        payload[9] = 32; // corrupt bitdepth byte
        assert_eq!(decode_header(&payload), Err(SigilError::InvalidBitDepth(32)));
    }

    #[test]
    fn decode_header_zero_dimensions() {
        let mut payload = encode_header(&Header {
            width: 1, height: 1,
            color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        });
        // Set width to 0
        payload[0..4].copy_from_slice(&0u32.to_be_bytes());
        assert!(matches!(decode_header(&payload), Err(SigilError::InvalidDimensions(0, _))));
    }

    #[test]
    fn decode_header_truncated() {
        assert_eq!(decode_header(&[1, 2, 3]), Err(SigilError::TruncatedInput));
    }

    #[test]
    fn read_header_from_sgl() {
        let header = Header {
            width: 10, height: 10,
            color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        };
        // SDAT payload: all-zeros image. total_samples=10*10=100.
        // Token stream: numBlocks=1, k=0, ZeroRun(100)
        // numBlocks=1: 0x00, 0x01
        // k=0: 4 bits = 0000
        // flag=0: 1 bit
        // runLen=100=0x0064: 16 bits
        // Byte 2: [0000][0][000] = 0x00
        // Byte 3: [0000_0000] = 0x00
        // Byte 4: [0110_0100] = 0x64
        let sdat = vec![0x00, 0x01, 0x00, 0x00, 0x64];
        let file = build_sgl(&header, &sdat);
        let parsed = read_header(&file).unwrap();
        assert_eq!(parsed, header);
    }

    #[test]
    fn decode_full_all_zeros() {
        let header = Header {
            width: 10, height: 10,
            color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        };
        let sdat = vec![0x00, 0x01, 0x00, 0x00, 0x64];
        let file = build_sgl(&header, &sdat);
        let (parsed_header, pixels) = decode(&file).unwrap();
        assert_eq!(parsed_header, header);
        assert_eq!(pixels.len(), 100);
        assert!(pixels.iter().all(|&p| p == 0));
    }

    #[test]
    fn decode_invalid_magic() {
        let mut file = vec![0x00; 20];
        assert_eq!(decode(&file), Err(SigilError::InvalidMagic));
    }

    #[test]
    fn decode_unsupported_version() {
        let mut file = Vec::new();
        file.extend_from_slice(&MAGIC);
        file.push(1); // major=1
        file.push(0); // minor=0
        // We need some more bytes but the error should fire first
        file.extend_from_slice(&[0; 50]);
        assert_eq!(decode(&file), Err(SigilError::UnsupportedVersion { major: 1, minor: 0 }));
    }
}
```

- [ ] **Step 2: Add module to lib.rs**

Add this line to `sigil-rs/src/lib.rs` after `mod pipeline;`:

```rust
mod reader;
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test reader
```

Expected: FAIL — `todo!()` panics.

- [ ] **Step 4: Implement reader.rs functions**

Replace the function bodies in `sigil-rs/src/reader.rs` (keep signatures, doc comments, and tests):

```rust
use crate::chunk::{parse_chunks, Tag};
use crate::error::SigilError;
use crate::pipeline::decompress;
use crate::types::*;

const MAGIC: [u8; 6] = [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A];
const VERSION_MAJOR: u8 = 0;
const VERSION_MINOR: u8 = 2;

/// Size of file header before chunks: 6 (magic) + 2 (version) = 8 bytes.
const FILE_HEADER_SIZE: usize = 8;

pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError> {
    // Validate magic
    if data.len() < FILE_HEADER_SIZE {
        return Err(SigilError::TruncatedInput);
    }
    if data[..6] != MAGIC {
        return Err(SigilError::InvalidMagic);
    }
    // Validate version
    let major = data[6];
    let minor = data[7];
    if major != VERSION_MAJOR || minor != VERSION_MINOR {
        return Err(SigilError::UnsupportedVersion { major, minor });
    }
    // Parse chunks (CRC verified inside parse_chunks)
    let chunks = parse_chunks(&data[FILE_HEADER_SIZE..])?;

    // Find SHDR
    let shdr = chunks.iter()
        .find(|c| c.tag == Tag::Shdr)
        .ok_or(SigilError::MissingChunk("SHDR"))?;
    let header = decode_header(&shdr.payload)?;

    // Concatenate all SDAT payloads
    let sdat_payload: Vec<u8> = chunks.iter()
        .filter(|c| c.tag == Tag::Sdat)
        .flat_map(|c| c.payload.iter().copied())
        .collect();

    // Decompress
    let pixels = decompress(&header, &sdat_payload)?;

    Ok((header, pixels))
}

pub fn read_header(data: &[u8]) -> Result<Header, SigilError> {
    if data.len() < FILE_HEADER_SIZE {
        return Err(SigilError::TruncatedInput);
    }
    if data[..6] != MAGIC {
        return Err(SigilError::InvalidMagic);
    }
    let major = data[6];
    let minor = data[7];
    if major != VERSION_MAJOR || minor != VERSION_MINOR {
        return Err(SigilError::UnsupportedVersion { major, minor });
    }
    let chunks = parse_chunks(&data[FILE_HEADER_SIZE..])?;
    let shdr = chunks.iter()
        .find(|c| c.tag == Tag::Shdr)
        .ok_or(SigilError::MissingChunk("SHDR"))?;
    decode_header(&shdr.payload)
}

fn decode_header(payload: &[u8]) -> Result<Header, SigilError> {
    // SHDR payload: width(4) + height(4) + colorspace(1) + bitdepth(1) + predictor(1) = 11 bytes
    if payload.len() < 11 {
        return Err(SigilError::TruncatedInput);
    }
    let width = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let height = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);

    if width == 0 || height == 0 {
        return Err(SigilError::InvalidDimensions(width, height));
    }

    let color_space = ColorSpace::from_byte(payload[8])
        .ok_or(SigilError::InvalidColorSpace(payload[8]))?;
    let bit_depth = BitDepth::from_byte(payload[9])
        .ok_or(SigilError::InvalidBitDepth(payload[9]))?;
    let predictor = PredictorId::from_byte(payload[10])
        .ok_or(SigilError::InvalidPredictor(payload[10]))?;

    Ok(Header { width, height, color_space, bit_depth, predictor })
}
```

- [ ] **Step 5: Run tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test reader
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/reader.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): .sgl file reader with header and pixel decoding"
```

---

### Task 11: Public API (lib.rs)

**Files:**
- Modify: `sigil-rs/src/lib.rs`

Wire up the public `decode()` and `read_header()` functions that delegate to `reader.rs`.

- [ ] **Step 1: Write the final lib.rs**

Replace `sigil-rs/src/lib.rs` with the complete version:

```rust
//! Sigil decoder — reads `.sgl` files and returns raw pixel data.
//!
//! Zero runtime dependencies. WASM-compatible.
//!
//! # Usage
//!
//! ```no_run
//! let bytes = std::fs::read("image.sgl").unwrap();
//! let (header, pixels) = sigil_decode::decode(&bytes).unwrap();
//! println!("{}x{} {:?}", header.width, header.height, header.color_space);
//! ```

mod types;
mod error;
mod crc32;
mod chunk;
mod zigzag;
mod token;
mod rice;
mod predict;
mod pipeline;
mod reader;

pub use types::{Header, ColorSpace, BitDepth, PredictorId};
pub use error::SigilError;

/// Decode a `.sgl` file from bytes. Returns header + raw pixel data.
///
/// Pixels are a flat `Vec<u8>` of row-major interleaved samples.
/// For RGB: `[r,g,b, r,g,b, ...]`. Use `Header` to interpret layout.
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError> {
    reader::decode(data)
}

/// Read only the header without decoding pixel data.
///
/// Useful for inspecting image dimensions/format before allocating
/// memory for the full decode.
pub fn read_header(data: &[u8]) -> Result<Header, SigilError> {
    reader::read_header(data)
}
```

- [ ] **Step 2: Add a doc test / smoke test**

Create a test in lib.rs to validate the public API surface. Append to `sigil-rs/src/lib.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_api_types_accessible() {
        // Verify all public types are accessible
        let _h = Header {
            width: 1,
            height: 1,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Eight,
            predictor: PredictorId::None,
        };
        let _e = SigilError::InvalidMagic;
    }

    #[test]
    fn decode_rejects_garbage() {
        let result = decode(&[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
        assert_eq!(result, Err(SigilError::InvalidMagic));
    }

    #[test]
    fn read_header_rejects_garbage() {
        let result = read_header(&[0, 1, 2]);
        assert_eq!(result, Err(SigilError::TruncatedInput));
    }
}
```

- [ ] **Step 3: Run all tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test
```

Expected: all tests across all modules pass.

- [ ] **Step 4: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): wire up public API decode() and read_header()"
```

---

### Task 12: Conformance Tests Against Golden .sgl Files

**Files:**
- Create: `sigil-rs/tests/conformance.rs`

These integration tests decode the golden `.sgl` files produced by `sigil-hs` and compare the pixel output against the source PNGs. The `image` crate is a dev-dependency used only here.

- [ ] **Step 1: Write conformance test file**

Create `sigil-rs/tests/conformance.rs`:

```rust
//! Conformance tests: decode golden .sgl files produced by sigil-hs,
//! verify pixel-identical output against source PNGs.

use std::path::Path;

/// Path to the test corpus (relative to the workspace root).
/// Cargo runs tests with cwd = the crate root (sigil-rs/),
/// so we go up one level to the repo root.
const CORPUS_DIR: &str = "../tests/corpus";
const EXPECTED_DIR: &str = "../tests/corpus/expected";

/// Load a PNG file and return raw pixel data as flat bytes (RGB or RGBA).
fn load_png_pixels(path: &Path) -> (u32, u32, Vec<u8>) {
    let img = image::open(path)
        .unwrap_or_else(|e| panic!("failed to load PNG {}: {}", path.display(), e));
    let rgb = img.to_rgb8();
    let (w, h) = (rgb.width(), rgb.height());
    (w, h, rgb.into_raw())
}

/// Decode a .sgl file and return (header, pixels).
fn decode_sgl(path: &Path) -> (sigil_decode::Header, Vec<u8>) {
    let data = std::fs::read(path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", path.display(), e));
    sigil_decode::decode(&data)
        .unwrap_or_else(|e| panic!("failed to decode {}: {}", path.display(), e))
}

fn conformance_test(name: &str) {
    let sgl_path = Path::new(EXPECTED_DIR).join(format!("{name}.sgl"));
    let png_path = Path::new(CORPUS_DIR).join(format!("{name}.png"));

    if !sgl_path.exists() {
        panic!("golden .sgl not found: {}", sgl_path.display());
    }
    if !png_path.exists() {
        panic!("source PNG not found: {}", png_path.display());
    }

    // Decode the .sgl
    let (header, sgl_pixels) = decode_sgl(&sgl_path);

    // Load the PNG
    let (png_w, png_h, png_pixels) = load_png_pixels(&png_path);

    // Verify header matches PNG dimensions
    assert_eq!(header.width, png_w, "width mismatch for {name}");
    assert_eq!(header.height, png_h, "height mismatch for {name}");

    // Verify pixel data matches
    assert_eq!(
        sgl_pixels.len(), png_pixels.len(),
        "pixel data length mismatch for {name}: sgl={} png={}",
        sgl_pixels.len(), png_pixels.len()
    );
    assert_eq!(
        sgl_pixels, png_pixels,
        "pixel data mismatch for {name} (first difference at byte {})",
        sgl_pixels.iter().zip(png_pixels.iter())
            .position(|(a, b)| a != b)
            .unwrap_or(0)
    );
}

#[test]
fn conformance_gradient_256x256() {
    conformance_test("gradient_256x256");
}

#[test]
fn conformance_flat_white_100x100() {
    conformance_test("flat_white_100x100");
}

#[test]
fn conformance_noise_128x128() {
    conformance_test("noise_128x128");
}

#[test]
fn conformance_checkerboard_64x64() {
    conformance_test("checkerboard_64x64");
}

/// Test that read_header works on golden files without full decode.
#[test]
fn read_header_gradient() {
    let sgl_path = Path::new(EXPECTED_DIR).join("gradient_256x256.sgl");
    let data = std::fs::read(&sgl_path).unwrap();
    let header = sigil_decode::read_header(&data).unwrap();
    assert_eq!(header.width, 256);
    assert_eq!(header.height, 256);
    assert_eq!(header.color_space, sigil_decode::ColorSpace::Rgb);
    assert_eq!(header.bit_depth, sigil_decode::BitDepth::Eight);
}
```

- [ ] **Step 2: Run conformance tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test conformance -- --nocapture
```

Expected: all 5 conformance tests pass. If any fail, the error message will show the first byte offset where pixels differ — this pinpoints whether it is a Rice, zigzag, token, or predict bug.

**Troubleshooting if a test fails:**

- **Width/height mismatch**: Bug in `decode_header` — check byte order or field offset.
- **Pixel length mismatch**: Bug in `decompress` — total_samples calculation or row_bytes.
- **Pixel data mismatch at byte 0**: Likely a predict or unzigzag bug — start by checking a PNone image.
- **Pixel data mismatch deeper in**: Likely a Rice decode or block-k tracking bug.

- [ ] **Step 3: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/tests/conformance.rs
git commit -m "test(sigil-rs): conformance tests against golden .sgl files"
```

---

### Task 13: Final Smoke Test & Cleanup

**Files:**
- Modify: `sigil-rs/src/lib.rs` (if any warnings to fix)
- Modify: `sigil-rs/Cargo.toml` (if any cleanup)

- [ ] **Step 1: Run full test suite**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test
```

Expected: all tests pass — unit tests, proptests, and conformance tests.

- [ ] **Step 2: Run clippy**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo clippy -- -D warnings
```

Expected: no warnings. If there are clippy warnings, fix them. Common ones:
- `unnecessary_wraps` on functions returning `Result` that never error — leave as-is since they may error on malformed input.
- `needless_pass_by_value` — change to `&` where appropriate.
- `cast_possible_truncation` — add explicit truncation comments or use `try_from`.

- [ ] **Step 3: Verify no runtime dependencies**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo tree --depth 1 --edges normal
```

Expected output should show only `sigil-decode` with no runtime dependencies listed. `proptest` and `image` should only appear as dev-dependencies.

- [ ] **Step 4: Add target/ to .gitignore**

Check the repo-level `.gitignore` at `/Users/dennis/programming projects/imgcompressor/.gitignore`. If it does not already include `target/`, add this line:

```
target/
```

This prevents the Rust build artifacts from being committed.

- [ ] **Step 5: Final commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add -A sigil-rs/ .gitignore
git commit -m "chore(sigil-rs): clippy clean, verify zero runtime deps"
```

- [ ] **Step 6: Verify final state**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs"
cargo test
echo "---"
cargo clippy -- -D warnings
echo "---"
cargo tree --depth 1 --edges normal
```

Expected: all tests pass, no clippy warnings, zero runtime dependencies.


---

Plan complete. I was unable to save it to `docs/superpowers/plans/2026-03-28-sigil-decoder-implementation.md` because I am running in read-only mode and do not have access to file creation or editing tools. The full plan content is above and needs to be saved to:

**`/Users/dennis/programming projects/imgcompressor/docs/superpowers/plans/2026-03-28-sigil-decoder-implementation.md`**

Two execution options:

**1. Subagent-Driven (recommended)** -- I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** -- Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?

### Critical Files for Implementation
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Pipeline.hs` -- the core decode pipeline logic being ported (decodeData, decodeTokenStream, decodeSamples)
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Rice.hs` -- BitReader and riceDecode algorithms to port exactly
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Predict.hs` -- predict/unpredictRow/unpredictImage algorithms
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/IO/Reader.hs` -- .sgl file format parsing (magic, version, chunks, SHDR decode)
- `/Users/dennis/programming projects/imgcompressor/docs/superpowers/specs/2026-03-28-sigil-decoder-design.md` -- the design spec this plan implements