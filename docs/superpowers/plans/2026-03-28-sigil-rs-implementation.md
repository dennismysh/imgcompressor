# Sigil Rust Production Codec -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Sigil image codec from the Haskell reference implementation (`sigil-hs/`) to a production-quality Rust crate with byte-for-byte conformance against the golden `.sgl` files in `tests/corpus/expected/`.

**Architecture:** Cargo workspace at `sigil-rs/` with two crates: `sigil` (library -- core types, codec pipeline, file I/O via `image` crate) and `sigil-cli` (binary -- CLI via `clap`). Images stored as flat `Vec<u8>` with row access by slice. All codec algorithms are direct ports of the Haskell modules with identical bit-level behavior.

**Tech Stack:** Rust 1.92+, Cargo workspace, `image` (PNG/JPEG I/O), `thiserror` (error types), `clap` (CLI), `proptest` (property-based testing), `criterion` (benchmarks)

**Spec:** `docs/superpowers/specs/2026-03-28-sigil-rs-design.md`

---

### Task 1: Project Scaffold & Cargo Workspace

**Files:**
- Create: `sigil-rs/Cargo.toml`
- Create: `sigil-rs/sigil/Cargo.toml`
- Create: `sigil-rs/sigil/src/lib.rs`
- Create: `sigil-rs/sigil/src/types.rs`
- Create: `sigil-rs/sigil-cli/Cargo.toml`
- Create: `sigil-rs/sigil-cli/src/main.rs`
- Modify: `.gitignore`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p sigil-rs/sigil/src
mkdir -p sigil-rs/sigil-cli/src
mkdir -p sigil-rs/benches
```

- [ ] **Step 2: Create workspace Cargo.toml**

Create `sigil-rs/Cargo.toml`:

```toml
[workspace]
resolver = "2"
members = ["sigil", "sigil-cli"]

[workspace.package]
version = "0.2.0"
edition = "2021"
license = "MIT"

[workspace.dependencies]
image = "0.25"
thiserror = "2"
clap = { version = "4", features = ["derive"] }
proptest = "1"
criterion = { version = "0.5", features = ["html_reports"] }
```

- [ ] **Step 3: Create library crate Cargo.toml**

Create `sigil-rs/sigil/Cargo.toml`:

```toml
[package]
name = "sigil"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "Sigil image codec — Rust production implementation"

[dependencies]
image = { workspace = true }
thiserror = { workspace = true }

[dev-dependencies]
proptest = { workspace = true }
criterion = { workspace = true }

[[bench]]
name = "codec"
harness = false
```

- [ ] **Step 4: Create types.rs with core types and error enum**

Create `sigil-rs/sigil/src/types.rs`:

```rust
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColorSpace {
    Grayscale = 0,
    GrayscaleAlpha = 1,
    Rgb = 2,
    Rgba = 3,
}

impl ColorSpace {
    pub fn channels(self) -> usize {
        match self {
            ColorSpace::Grayscale => 1,
            ColorSpace::GrayscaleAlpha => 2,
            ColorSpace::Rgb => 3,
            ColorSpace::Rgba => 4,
        }
    }

    pub fn from_u8(v: u8) -> Result<Self, SigilError> {
        match v {
            0 => Ok(ColorSpace::Grayscale),
            1 => Ok(ColorSpace::GrayscaleAlpha),
            2 => Ok(ColorSpace::Rgb),
            3 => Ok(ColorSpace::Rgba),
            n => Err(SigilError::InvalidColorSpace(n)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BitDepth {
    Depth8,
    Depth16,
}

impl BitDepth {
    pub fn bytes_per_channel(self) -> usize {
        match self {
            BitDepth::Depth8 => 1,
            BitDepth::Depth16 => 2,
        }
    }

    /// Serialize as the raw byte value (8 or 16), NOT the enum index.
    pub fn to_byte(self) -> u8 {
        match self {
            BitDepth::Depth8 => 8,
            BitDepth::Depth16 => 16,
        }
    }

    pub fn from_byte(v: u8) -> Result<Self, SigilError> {
        match v {
            8 => Ok(BitDepth::Depth8),
            16 => Ok(BitDepth::Depth16),
            n => Err(SigilError::InvalidBitDepth(n)),
        }
    }
}

/// Fixed predictors are 0..5. Adaptive is 6.
/// The enum ordering must match Haskell's `[PNone .. PGradient]` for adaptive tie-breaking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PredictorId {
    None = 0,
    Sub = 1,
    Up = 2,
    Average = 3,
    Paeth = 4,
    Gradient = 5,
    Adaptive = 6,
}

/// All fixed predictors in enum order, used by adaptive_row.
/// CONFORMANCE: This ordering determines tie-breaking — PNone wins over PSub on equal cost.
pub const FIXED_PREDICTORS: [PredictorId; 6] = [
    PredictorId::None,
    PredictorId::Sub,
    PredictorId::Up,
    PredictorId::Average,
    PredictorId::Paeth,
    PredictorId::Gradient,
];

impl PredictorId {
    pub fn from_u8(v: u8) -> Result<Self, SigilError> {
        match v {
            0 => Ok(PredictorId::None),
            1 => Ok(PredictorId::Sub),
            2 => Ok(PredictorId::Up),
            3 => Ok(PredictorId::Average),
            4 => Ok(PredictorId::Paeth),
            5 => Ok(PredictorId::Gradient),
            6 => Ok(PredictorId::Adaptive),
            n => Err(SigilError::InvalidPredictor(n)),
        }
    }

    pub fn to_u8(self) -> u8 {
        self as u8
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub width: u32,
    pub height: u32,
    pub color_space: ColorSpace,
    pub bit_depth: BitDepth,
    pub predictor: PredictorId,
}

impl Header {
    pub fn row_bytes(&self) -> usize {
        self.width as usize
            * self.color_space.channels()
            * self.bit_depth.bytes_per_channel()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Metadata {
    pub entries: Vec<(String, Vec<u8>)>,
}

#[derive(Debug, Error)]
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

- [ ] **Step 5: Create lib.rs with stub modules**

Create `sigil-rs/sigil/src/lib.rs`:

```rust
pub mod types;
pub mod zigzag;
pub mod predict;
pub mod token;
pub mod rice;
pub mod chunk;
pub mod pipeline;
pub mod writer;
pub mod reader;
pub mod convert;

pub use types::*;
```

Create stub files so the workspace compiles. Each will be filled in by subsequent tasks:

Create `sigil-rs/sigil/src/zigzag.rs`:

```rust
// Implemented in Task 2
```

Create `sigil-rs/sigil/src/predict.rs`:

```rust
// Implemented in Task 3
```

Create `sigil-rs/sigil/src/token.rs`:

```rust
// Implemented in Task 4
```

Create `sigil-rs/sigil/src/rice.rs`:

```rust
// Implemented in Task 5
```

Create `sigil-rs/sigil/src/chunk.rs`:

```rust
// Implemented in Task 6
```

Create `sigil-rs/sigil/src/pipeline.rs`:

```rust
// Implemented in Task 7
```

Create `sigil-rs/sigil/src/writer.rs`:

```rust
// Implemented in Task 8
```

Create `sigil-rs/sigil/src/reader.rs`:

```rust
// Implemented in Task 8
```

Create `sigil-rs/sigil/src/convert.rs`:

```rust
// Implemented in Task 9
```

- [ ] **Step 6: Create CLI crate stub**

Create `sigil-rs/sigil-cli/Cargo.toml`:

```toml
[package]
name = "sigil-cli"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "Sigil image codec — CLI"

[[bin]]
name = "sigil"
path = "src/main.rs"

[dependencies]
sigil = { path = "../sigil" }
clap = { workspace = true }
```

Create `sigil-rs/sigil-cli/src/main.rs`:

```rust
fn main() {
    println!("sigil-cli: not yet implemented");
}
```

- [ ] **Step 7: Update .gitignore**

Append to `.gitignore`:

```
target/
```

- [ ] **Step 8: Build the workspace to verify setup**

```bash
cd sigil-rs && cargo build
```

Expected: compiles with warnings about unused/empty modules, but no errors.

- [ ] **Step 9: Commit**

```bash
git add sigil-rs/ .gitignore && git commit -m "feat: scaffold sigil-rs cargo workspace with core types"
```

---

### Task 2: ZigZag Encoding (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/zigzag.rs`

- [ ] **Step 1: Write the failing tests**

Replace `sigil-rs/sigil/src/zigzag.rs`:

```rust
/// Zig-zag encoding: maps signed residuals to unsigned values.
/// 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4, ...
///
/// Identical bit formula to Haskell: `(n << 1) ^ (n >> 15)`
pub fn zigzag(_n: i16) -> u16 {
    todo!()
}

/// Inverse of zigzag.
/// Identical bit formula to Haskell: `(n >> 1) ^ -(n & 1)`
pub fn unzigzag(_n: u16) -> i16 {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_0_to_0() {
        assert_eq!(zigzag(0), 0u16);
    }

    #[test]
    fn maps_neg1_to_1() {
        assert_eq!(zigzag(-1), 1);
    }

    #[test]
    fn maps_1_to_2() {
        assert_eq!(zigzag(1), 2);
    }

    #[test]
    fn maps_neg2_to_3() {
        assert_eq!(zigzag(-2), 3);
    }

    #[test]
    fn maps_2_to_4() {
        assert_eq!(zigzag(2), 4);
    }

    #[test]
    fn round_trips_all_residual_values() {
        for n in -255i16..=255 {
            assert_eq!(unzigzag(zigzag(n)), n, "round-trip failed for {n}");
        }
    }

    #[test]
    fn output_is_non_negative() {
        for n in -255i16..=255 {
            // u16 is always >= 0, but verify the mapping is sensible
            let _ = zigzag(n); // no panic
        }
    }

    #[test]
    fn monotonic_on_positive() {
        for a in 0i16..255 {
            assert!(
                zigzag(a) < zigzag(a + 1),
                "not monotonic: zigzag({a}) = {} >= zigzag({}) = {}",
                zigzag(a),
                a + 1,
                zigzag(a + 1)
            );
        }
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn round_trip(n in -255i16..=255) {
            prop_assert_eq!(unzigzag(zigzag(n)), n);
        }

        #[test]
        fn full_range_round_trip(n in i16::MIN..=i16::MAX) {
            prop_assert_eq!(unzigzag(zigzag(n)), n);
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd sigil-rs && cargo test -p sigil zigzag 2>&1 | head -20
```

Expected: tests fail with `not yet implemented` panics.

- [ ] **Step 3: Implement zigzag**

Replace the two function bodies in `sigil-rs/sigil/src/zigzag.rs` (keep tests unchanged):

```rust
pub fn zigzag(n: i16) -> u16 {
    ((n << 1) ^ (n >> 15)) as u16
}

pub fn unzigzag(n: u16) -> i16 {
    ((n >> 1) ^ (0u16.wrapping_sub(n & 1))) as i16
}
```

Note on `unzigzag`: The Haskell `negate (n .&. 1)` on `Word16` produces `0xFFFF` when `n` is odd and `0x0000` when even. In Rust, `u16` does not have unary negation, so we use `0u16.wrapping_sub(n & 1)` which yields the identical bit pattern.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil zigzag
```

Expected: all tests pass (unit + proptest).

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil/src/zigzag.rs && git commit -m "feat: zigzag encoding with TDD and proptest"
```

---

### Task 3: Predictors (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/predict.rs`

- [ ] **Step 1: Write the failing tests**

Replace `sigil-rs/sigil/src/predict.rs`:

```rust
use crate::types::{Header, PredictorId, FIXED_PREDICTORS};

/// Compute the predicted value for a single sample given its neighbors.
/// a = left, b = above, c = above-left.
pub fn predict(_pid: PredictorId, _a: u8, _b: u8, _c: u8) -> u8 {
    todo!()
}

/// Paeth predictor (used by PNG and Sigil).
pub fn paeth(_a: u8, _b: u8, _c: u8) -> u8 {
    todo!()
}

/// Compute the signed residual: x - predict(a, b, c).
pub fn residual(_pid: PredictorId, _a: u8, _b: u8, _c: u8, _x: u8) -> i16 {
    todo!()
}

/// Predict an entire row, producing signed residuals.
/// `prev` is the previous row (or all zeros for row 0).
/// `cur` is the current row of raw pixel values.
/// `ch` is the number of channels (bytes per pixel for Depth8).
pub fn predict_row(_pid: PredictorId, _prev: &[u8], _cur: &[u8], _ch: usize) -> Vec<i16> {
    todo!()
}

/// Reconstruct a row from residuals (inverse of predict_row).
/// `prev` is the previous reconstructed row.
/// `residuals` is the signed residual row.
/// `ch` is the number of channels.
pub fn unpredict_row(_pid: PredictorId, _prev: &[u8], _residuals: &[i16], _ch: usize) -> Vec<u8> {
    todo!()
}

/// Predict an entire image, returning per-row predictor IDs and residual rows.
/// If header.predictor is Adaptive, tries all 6 fixed predictors per row.
/// If fixed, uses the same predictor for every row.
pub fn predict_image(_header: &Header, _pixels: &[u8]) -> (Vec<PredictorId>, Vec<Vec<i16>>) {
    todo!()
}

/// Reconstruct pixel data from per-row predictor IDs and residual rows.
pub fn unpredict_image(_header: &Header, _pids: &[PredictorId], _residuals: &[Vec<i16>]) -> Vec<u8> {
    todo!()
}

/// Try all 6 fixed predictors on a row, return the one with lowest cost.
/// Cost = sum of absolute residual values (as i64 to avoid overflow).
/// CONFORMANCE: On ties, the first predictor in FIXED_PREDICTORS wins (PNone).
pub fn adaptive_row(_prev: &[u8], _cur: &[u8], _ch: usize) -> (PredictorId, Vec<i16>) {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ColorSpace, BitDepth};

    #[test]
    fn pnone_always_predicts_0() {
        assert_eq!(predict(PredictorId::None, 100, 200, 50), 0);
    }

    #[test]
    fn psub_predicts_left() {
        assert_eq!(predict(PredictorId::Sub, 42, 200, 50), 42);
    }

    #[test]
    fn pup_predicts_above() {
        assert_eq!(predict(PredictorId::Up, 42, 200, 50), 200);
    }

    #[test]
    fn paverage_predicts_average() {
        // (100 + 200) / 2 = 150
        assert_eq!(predict(PredictorId::Average, 100, 200, 50), 150);
        // (1 + 2) / 2 = 1 (integer division)
        assert_eq!(predict(PredictorId::Average, 1, 2, 0), 1);
    }

    #[test]
    fn ppaeth_known_values() {
        assert_eq!(paeth(10, 20, 15), 10); // p=15, pa=5, pb=5, pc=0 -> pa<=pb && pa<=pc? 5<=5 && 5<=0 NO -> pb<=pc? 5<=0 NO -> c=15... let me recalculate
        // p = 10+20-15 = 15, pa=|15-10|=5, pb=|15-20|=5, pc=|15-15|=0
        // pa<=pb (5<=5) YES, pa<=pc (5<=0) NO -> not first branch
        // pb<=pc (5<=0) NO -> c = 15
        // Haskell: if pa<=pb && pa<=pc then a; elif pb<=pc then b; else c
        // So paeth(10,20,15) = 15
        assert_eq!(paeth(10, 20, 15), 15);
    }

    #[test]
    fn pgradient_clamps() {
        // a=200, b=200, c=0 -> 200+200-0=400, clamped to 255
        assert_eq!(predict(PredictorId::Gradient, 200, 200, 0), 255);
        // a=0, b=0, c=200 -> 0+0-200=-200, clamped to 0
        assert_eq!(predict(PredictorId::Gradient, 0, 0, 200), 0);
        // a=100, b=50, c=30 -> 100+50-30=120
        assert_eq!(predict(PredictorId::Gradient, 100, 50, 30), 120);
    }

    #[test]
    fn residual_law() {
        // For every fixed predictor: predict(a,b,c) + residual(a,b,c,x) == x
        for &pid in &FIXED_PREDICTORS {
            for x in (0u8..=255).step_by(17) {
                for a in (0u8..=255).step_by(51) {
                    let b = 128u8;
                    let c = 64u8;
                    let r = residual(pid, a, b, c, x);
                    let reconstructed = (predict(pid, a, b, c) as i16 + r) as u8;
                    assert_eq!(
                        reconstructed, x,
                        "pid={pid:?} a={a} b={b} c={c} x={x}"
                    );
                }
            }
        }
    }

    #[test]
    fn predict_row_basic() {
        let prev = vec![0u8; 6]; // 2 pixels, 3 channels
        let cur = vec![10, 20, 30, 40, 50, 60];
        let res = predict_row(PredictorId::None, &prev, &cur, 3);
        // PNone: predict=0, so residual = x - 0 = x
        assert_eq!(res, vec![10, 20, 30, 40, 50, 60]);
    }

    #[test]
    fn predict_row_sub() {
        let prev = vec![0u8; 6];
        let cur = vec![10, 20, 30, 40, 50, 60];
        let res = predict_row(PredictorId::Sub, &prev, &cur, 3);
        // First pixel (i<ch): a=0, so residual = x - 0 = x
        // Second pixel: a = cur[i-ch]
        // i=3: a=cur[0]=10, residual=40-10=30
        // i=4: a=cur[1]=20, residual=50-20=30
        // i=5: a=cur[2]=30, residual=60-30=30
        assert_eq!(res, vec![10, 20, 30, 30, 30, 30]);
    }

    #[test]
    fn row_round_trip() {
        for &pid in &FIXED_PREDICTORS {
            let prev = vec![0u8; 9]; // 3 pixels, 3 channels
            let cur = vec![10, 20, 30, 40, 50, 60, 70, 80, 90];
            let residuals = predict_row(pid, &prev, &cur, 3);
            let recovered = unpredict_row(pid, &prev, &residuals, 3);
            assert_eq!(recovered, cur, "round-trip failed for {pid:?}");
        }
    }

    #[test]
    fn image_round_trip_fixed() {
        for &pid in &FIXED_PREDICTORS {
            let header = Header {
                width: 3,
                height: 2,
                color_space: ColorSpace::Rgb,
                bit_depth: BitDepth::Depth8,
                predictor: pid,
            };
            let pixels: Vec<u8> = (0..18).collect(); // 3*2*3 = 18 bytes
            let (pids, residuals) = predict_image(&header, &pixels);
            let recovered = unpredict_image(&header, &pids, &residuals);
            assert_eq!(recovered, pixels, "image round-trip failed for {pid:?}");
        }
    }

    #[test]
    fn image_round_trip_adaptive() {
        let header = Header {
            width: 4,
            height: 3,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::Adaptive,
        };
        let pixels: Vec<u8> = (0..36).map(|i| (i * 7 + 13) as u8).collect();
        let (pids, residuals) = predict_image(&header, &pixels);
        assert_eq!(pids.len(), 3);
        let recovered = unpredict_image(&header, &pids, &residuals);
        assert_eq!(recovered, pixels);
    }

    #[test]
    fn adaptive_picks_optimal() {
        // All-same row: PNone should have cost=0 for a row with prev=cur
        let prev = vec![10u8, 20, 30, 10, 20, 30];
        let cur = vec![10u8, 20, 30, 10, 20, 30];
        let (pid, residuals) = adaptive_row(&prev, &cur, 3);
        // PUp predicts exactly: residuals all 0, cost 0
        // PNone predicts 0: residuals = cur values, cost > 0
        // So PUp should win
        assert_eq!(pid, PredictorId::Up);
        assert!(residuals.iter().all(|&r| r == 0));
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use crate::types::{ColorSpace, BitDepth};
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
        fn residual_law(
            pid in arb_fixed_predictor(),
            a in 0u8..=255,
            b in 0u8..=255,
            c in 0u8..=255,
            x in 0u8..=255,
        ) {
            let r = residual(pid, a, b, c, x);
            let reconstructed = (predict(pid, a, b, c) as i16 + r) as u8;
            prop_assert_eq!(reconstructed, x);
        }

        #[test]
        fn row_round_trip(
            pid in arb_fixed_predictor(),
            row_len in 1usize..=30,
        ) {
            let prev = vec![0u8; row_len];
            let cur: Vec<u8> = (0..row_len).map(|i| (i * 13 + 7) as u8).collect();
            let residuals = predict_row(pid, &prev, &cur, 1);
            let recovered = unpredict_row(pid, &prev, &residuals, 1);
            prop_assert_eq!(recovered, cur);
        }

        #[test]
        fn adaptive_cost_is_optimal(
            row_len in 3usize..=30,
        ) {
            let prev: Vec<u8> = (0..row_len).map(|i| (i * 17) as u8).collect();
            let cur: Vec<u8> = (0..row_len).map(|i| (i * 23 + 5) as u8).collect();
            let ch = 1;
            let (_, adaptive_res) = adaptive_row(&prev, &cur, ch);
            let adaptive_cost: i64 = adaptive_res.iter().map(|&r| (r as i64).abs()).sum();
            for &pid in &FIXED_PREDICTORS {
                let fixed_res = predict_row(pid, &prev, &cur, ch);
                let fixed_cost: i64 = fixed_res.iter().map(|&r| (r as i64).abs()).sum();
                prop_assert!(adaptive_cost <= fixed_cost,
                    "adaptive cost {adaptive_cost} > {pid:?} cost {fixed_cost}");
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd sigil-rs && cargo test -p sigil predict 2>&1 | head -20
```

Expected: tests fail with `not yet implemented` panics.

- [ ] **Step 3: Implement predict functions**

Replace the function bodies in `sigil-rs/sigil/src/predict.rs` (keep all tests unchanged):

```rust
use crate::types::{Header, PredictorId, FIXED_PREDICTORS};

pub fn predict(pid: PredictorId, a: u8, b: u8, c: u8) -> u8 {
    match pid {
        PredictorId::None => 0,
        PredictorId::Sub => a,
        PredictorId::Up => b,
        PredictorId::Average => {
            ((a as i32 + b as i32) / 2) as u8
        }
        PredictorId::Paeth => paeth(a, b, c),
        PredictorId::Gradient => {
            let v = a as i32 + b as i32 - c as i32;
            v.clamp(0, 255) as u8
        }
        PredictorId::Adaptive => panic!("adaptive is resolved per-row"),
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

pub fn residual(pid: PredictorId, a: u8, b: u8, c: u8, x: u8) -> i16 {
    x as i16 - predict(pid, a, b, c) as i16
}

pub fn predict_row(pid: PredictorId, prev: &[u8], cur: &[u8], ch: usize) -> Vec<i16> {
    let len = cur.len();
    let mut out = Vec::with_capacity(len);
    for i in 0..len {
        let a = if i >= ch { cur[i - ch] } else { 0 };
        let b = prev[i];
        let c = if i >= ch { prev[i - ch] } else { 0 };
        out.push(residual(pid, a, b, c, cur[i]));
    }
    out
}

pub fn unpredict_row(pid: PredictorId, prev: &[u8], residuals: &[i16], ch: usize) -> Vec<u8> {
    let len = residuals.len();
    let mut out = Vec::with_capacity(len);
    for i in 0..len {
        let a = if i >= ch { out[i - ch] } else { 0 };
        let b = prev[i];
        let c = if i >= ch { prev[i - ch] } else { 0 };
        let predicted = predict(pid, a, b, c);
        let x = (predicted as i16 + residuals[i]) as u8;
        out.push(x);
    }
    out
}

pub fn predict_image(header: &Header, pixels: &[u8]) -> (Vec<PredictorId>, Vec<Vec<i16>>) {
    let num_rows = header.height as usize;
    let row_len = header.row_bytes();
    let ch = header.color_space.channels() * header.bit_depth.bytes_per_channel();
    let zero_row = vec![0u8; row_len];

    if header.predictor == PredictorId::Adaptive {
        let mut pids = Vec::with_capacity(num_rows);
        let mut residuals = Vec::with_capacity(num_rows);
        for i in 0..num_rows {
            let prev = if i == 0 {
                &zero_row
            } else {
                &pixels[(i - 1) * row_len..i * row_len]
            };
            let cur = &pixels[i * row_len..(i + 1) * row_len];
            let (pid, row_residuals) = adaptive_row(prev, cur, ch);
            pids.push(pid);
            residuals.push(row_residuals);
        }
        (pids, residuals)
    } else {
        let pid = header.predictor;
        let mut residuals = Vec::with_capacity(num_rows);
        for i in 0..num_rows {
            let prev = if i == 0 {
                &zero_row
            } else {
                &pixels[(i - 1) * row_len..i * row_len]
            };
            let cur = &pixels[i * row_len..(i + 1) * row_len];
            residuals.push(predict_row(pid, prev, cur, ch));
        }
        (vec![pid; num_rows], residuals)
    }
}

pub fn unpredict_image(
    header: &Header,
    pids: &[PredictorId],
    residuals: &[Vec<i16>],
) -> Vec<u8> {
    let num_rows = header.height as usize;
    let row_len = header.row_bytes();
    let ch = header.color_space.channels() * header.bit_depth.bytes_per_channel();
    let zero_row = vec![0u8; row_len];
    let mut pixels = Vec::with_capacity(num_rows * row_len);

    for i in 0..num_rows {
        let prev = if i == 0 {
            &zero_row[..]
        } else {
            &pixels[(i - 1) * row_len..i * row_len]
        };
        let row = unpredict_row(pids[i], prev, &residuals[i], ch);
        pixels.extend_from_slice(&row);
    }
    pixels
}

pub fn adaptive_row(prev: &[u8], cur: &[u8], ch: usize) -> (PredictorId, Vec<i16>) {
    // CONFORMANCE: iterate FIXED_PREDICTORS in order [None, Sub, Up, Average, Paeth, Gradient].
    // On equal cost, the first one in the list wins (minimumBy picks first on tie).
    let mut best_pid = FIXED_PREDICTORS[0];
    let mut best_residuals = predict_row(best_pid, prev, cur, ch);
    let mut best_cost = cost(&best_residuals);

    for &pid in &FIXED_PREDICTORS[1..] {
        let row_residuals = predict_row(pid, prev, cur, ch);
        let c = cost(&row_residuals);
        if c < best_cost {
            best_cost = c;
            best_pid = pid;
            best_residuals = row_residuals;
        }
    }
    (best_pid, best_residuals)
}

/// Cost function: sum of absolute residuals.
/// Uses i64 to avoid overflow on large rows.
fn cost(residuals: &[i16]) -> i64 {
    residuals.iter().map(|&r| (r as i64).abs()).sum()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil predict
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil/src/predict.rs && git commit -m "feat: predictor functions with TDD and proptest"
```

---

### Task 4: Token (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/token.rs`

- [ ] **Step 1: Write the failing tests**

Replace `sigil-rs/sigil/src/token.rs`:

```rust
/// Tokens represent either a run of zeros or a non-zero value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Token {
    ZeroRun(u16),
    Value(u16),
}

/// Convert a slice of zigzag-encoded values into a token stream.
/// Consecutive zeros are collapsed into ZeroRun tokens.
/// Runs longer than 65535 are split into multiple ZeroRun tokens.
pub fn tokenize(_values: &[u16]) -> Vec<Token> {
    todo!()
}

/// Expand a token stream back into a flat vector of values.
pub fn untokenize(_tokens: &[Token]) -> Vec<u16> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_zeros_single_run() {
        assert_eq!(tokenize(&[0; 10]), vec![Token::ZeroRun(10)]);
    }

    #[test]
    fn non_zero_values() {
        assert_eq!(tokenize(&[3, 5]), vec![Token::Value(3), Token::Value(5)]);
    }

    #[test]
    fn zeros_then_value() {
        assert_eq!(
            tokenize(&[0, 0, 0, 7]),
            vec![Token::ZeroRun(3), Token::Value(7)]
        );
    }

    #[test]
    fn value_then_zeros() {
        assert_eq!(
            tokenize(&[4, 0, 0]),
            vec![Token::Value(4), Token::ZeroRun(2)]
        );
    }

    #[test]
    fn empty_input() {
        assert_eq!(tokenize(&[]), vec![]);
    }

    #[test]
    fn single_value() {
        assert_eq!(tokenize(&[42]), vec![Token::Value(42)]);
    }

    #[test]
    fn single_zero() {
        assert_eq!(tokenize(&[0]), vec![Token::ZeroRun(1)]);
    }

    #[test]
    fn round_trip_basic() {
        let values = vec![0, 0, 3, 0, 5, 0, 0, 0, 1];
        let tokens = tokenize(&values);
        let recovered = untokenize(&tokens);
        assert_eq!(recovered, values);
    }

    #[test]
    fn long_zero_run_splits_at_u16_max() {
        // 65536 zeros should produce two ZeroRun tokens: 65535 + 1
        let values = vec![0u16; 65536];
        let tokens = tokenize(&values);
        assert_eq!(tokens, vec![Token::ZeroRun(65535), Token::ZeroRun(1)]);
        let recovered = untokenize(&tokens);
        assert_eq!(recovered, values);
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn round_trip(values in proptest::collection::vec(0u16..512, 0..200)) {
            let tokens = tokenize(&values);
            let recovered = untokenize(&tokens);
            prop_assert_eq!(recovered, values);
        }

        #[test]
        fn no_zero_values_in_token_value(values in proptest::collection::vec(0u16..512, 0..200)) {
            let tokens = tokenize(&values);
            for t in &tokens {
                if let Token::Value(v) = t {
                    prop_assert_ne!(*v, 0, "Token::Value should never contain 0");
                }
            }
        }

        #[test]
        fn no_empty_zero_runs(values in proptest::collection::vec(0u16..512, 0..200)) {
            let tokens = tokenize(&values);
            for t in &tokens {
                if let Token::ZeroRun(n) = t {
                    prop_assert!(*n > 0, "ZeroRun should never have length 0");
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd sigil-rs && cargo test -p sigil token 2>&1 | head -20
```

Expected: tests fail with `not yet implemented` panics.

- [ ] **Step 3: Implement tokenize and untokenize**

Replace the function bodies:

```rust
pub fn tokenize(values: &[u16]) -> Vec<Token> {
    let len = values.len();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < len {
        if values[i] == 0 {
            // Count consecutive zeros, capped at u16::MAX
            let start = i;
            while i < len && values[i] == 0 && (i - start) < u16::MAX as usize {
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

pub fn untokenize(tokens: &[Token]) -> Vec<u16> {
    let mut values = Vec::new();
    for token in tokens {
        match *token {
            Token::ZeroRun(n) => {
                values.extend(std::iter::repeat_n(0u16, n as usize));
            }
            Token::Value(v) => {
                values.push(v);
            }
        }
    }
    values
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil token
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil/src/token.rs && git commit -m "feat: token run-length encoding with TDD and proptest"
```

---

### Task 5: Rice-Golomb Coding (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/rice.rs`

- [ ] **Step 1: Write the failing tests**

Replace `sigil-rs/sigil/src/rice.rs`:

```rust
/// Block size for Rice coding (matches Haskell blockSize = 64).
pub const BLOCK_SIZE: usize = 64;

/// MSB-first bit writer. Accumulates bytes in a Vec.
pub struct BitWriter {
    bytes: Vec<u8>,
    current: u8,
    bit_pos: u8, // 0..7, number of bits written in current byte
}

impl BitWriter {
    pub fn new() -> Self {
        BitWriter {
            bytes: Vec::new(),
            current: 0,
            bit_pos: 0,
        }
    }

    /// Write a single bit. MSB-first: bit 0 goes to position 7 of the byte.
    pub fn write_bit(&mut self, _b: bool) {
        todo!()
    }

    /// Write `n` bits from `val`, MSB first.
    /// Writes bits from position (n-1) down to 0.
    pub fn write_bits(&mut self, _n: u8, _val: u16) {
        todo!()
    }

    /// Flush the writer, returning the accumulated bytes.
    /// If there is a partial byte, it is included (padded with zeros in low bits).
    pub fn flush(self) -> Vec<u8> {
        todo!()
    }
}

/// MSB-first bit reader over a byte slice.
pub struct BitReader<'a> {
    data: &'a [u8],
    byte_ix: usize,
    bit_pos: u8, // 0..7, next bit to read within current byte
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BitReader {
            data,
            byte_ix: 0,
            bit_pos: 0,
        }
    }

    /// Read a single bit. MSB-first: bit_pos 0 reads bit 7 of the byte.
    pub fn read_bit(&mut self) -> bool {
        todo!()
    }

    /// Read `n` bits as a u16, MSB first.
    pub fn read_bits(&mut self, _n: u8) -> u16 {
        todo!()
    }
}

/// Rice-encode a single value with parameter k.
/// Quotient q = val >> k. Remainder r = val & ((1 << k) - 1).
/// Write q ones + one zero (unary), then k bits of r.
pub fn rice_encode(_k: u8, _val: u16, _w: &mut BitWriter) {
    todo!()
}

/// Rice-decode a single value with parameter k.
/// Read unary (count ones until zero), read k bits, val = (q << k) | r.
pub fn rice_decode(_k: u8, _r: &mut BitReader) -> u16 {
    todo!()
}

/// Find optimal k for a block of values. Tries k=0..8.
/// Cost(k) = sum(val >> k) + num_values + k * num_values
///   (each val: (val>>k) ones for unary, 1 zero, k bits for remainder)
/// CONFORMANCE: minimum on (cost, k) tuples -- lowest cost wins, ties broken by lowest k.
pub fn optimal_k(_block: &[u16]) -> u8 {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitwriter_8_bits_make_one_byte() {
        let mut w = BitWriter::new();
        // Write 10110010 = 0xB2
        for &b in &[true, false, true, true, false, false, true, false] {
            w.write_bit(b);
        }
        let bytes = w.flush();
        assert_eq!(bytes, vec![0xB2]);
    }

    #[test]
    fn bitwriter_partial_byte() {
        let mut w = BitWriter::new();
        w.write_bit(true);
        w.write_bit(false);
        w.write_bit(true);
        // 101xxxxx = 0xA0
        let bytes = w.flush();
        assert_eq!(bytes, vec![0xA0]);
    }

    #[test]
    fn bitwriter_write_bits_16() {
        let mut w = BitWriter::new();
        w.write_bits(16, 0x1234);
        let bytes = w.flush();
        assert_eq!(bytes, vec![0x12, 0x34]);
    }

    #[test]
    fn bitwriter_write_bits_4() {
        let mut w = BitWriter::new();
        w.write_bits(4, 0b1010);
        w.write_bits(4, 0b0011);
        let bytes = w.flush();
        assert_eq!(bytes, vec![0b10100011]);
    }

    #[test]
    fn bitreader_reads_bits() {
        let data = vec![0xB2]; // 10110010
        let mut r = BitReader::new(&data);
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
    fn bitreader_read_bits() {
        let data = vec![0x12, 0x34];
        let mut r = BitReader::new(&data);
        assert_eq!(r.read_bits(16), 0x1234);
    }

    #[test]
    fn rice_round_trip_k0() {
        for val in 0u16..50 {
            let mut w = BitWriter::new();
            rice_encode(0, val, &mut w);
            let bytes = w.flush();
            let mut r = BitReader::new(&bytes);
            assert_eq!(rice_decode(0, &mut r), val, "k=0, val={val}");
        }
    }

    #[test]
    fn rice_round_trip_all_k() {
        for k in 0u8..=8 {
            for val in [0u16, 1, 2, 3, 7, 15, 63, 127, 255, 511, 1023, 4095] {
                let mut w = BitWriter::new();
                rice_encode(k, val, &mut w);
                let bytes = w.flush();
                let mut r = BitReader::new(&bytes);
                let decoded = rice_decode(k, &mut r);
                assert_eq!(decoded, val, "k={k}, val={val}");
            }
        }
    }

    #[test]
    fn optimal_k_all_zeros() {
        // All zeros: every k gives cost = 0 + blockSize + k*blockSize = (1+k)*blockSize
        // k=0 wins (cost = blockSize)
        let block = vec![0u16; BLOCK_SIZE];
        assert_eq!(optimal_k(&block), 0);
    }

    #[test]
    fn optimal_k_in_range() {
        let block: Vec<u16> = (0..BLOCK_SIZE as u16).collect();
        let k = optimal_k(&block);
        assert!(k <= 8, "optimal_k should be in [0, 8], got {k}");
    }

    #[test]
    fn optimal_k_large_values_prefer_higher_k() {
        // Large values: shifting right by more bits reduces unary part
        let block = vec![1000u16; BLOCK_SIZE];
        let k = optimal_k(&block);
        assert!(k >= 4, "large values should prefer higher k, got {k}");
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn rice_round_trip(k in 0u8..=8, val in 0u16..4096) {
            let mut w = BitWriter::new();
            rice_encode(k, val, &mut w);
            let bytes = w.flush();
            let mut r = BitReader::new(&bytes);
            let decoded = rice_decode(k, &mut r);
            prop_assert_eq!(decoded, val);
        }

        #[test]
        fn optimal_k_in_valid_range(block in proptest::collection::vec(0u16..512, 1..=BLOCK_SIZE)) {
            let k = optimal_k(&block);
            prop_assert!(k <= 8);
        }

        #[test]
        fn write_read_bits_round_trip(n in 1u8..=16, val in 0u16..=u16::MAX) {
            let masked = val & ((1u32 << n as u32).wrapping_sub(1) as u16);
            let mut w = BitWriter::new();
            w.write_bits(n, masked);
            let bytes = w.flush();
            let mut r = BitReader::new(&bytes);
            let decoded = r.read_bits(n);
            prop_assert_eq!(decoded, masked);
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd sigil-rs && cargo test -p sigil rice 2>&1 | head -20
```

Expected: tests fail with `not yet implemented` panics.

- [ ] **Step 3: Implement BitWriter, BitReader, Rice coding, and optimal_k**

Replace the function/method bodies:

```rust
pub const BLOCK_SIZE: usize = 64;

pub struct BitWriter {
    bytes: Vec<u8>,
    current: u8,
    bit_pos: u8,
}

impl BitWriter {
    pub fn new() -> Self {
        BitWriter {
            bytes: Vec::new(),
            current: 0,
            bit_pos: 0,
        }
    }

    pub fn write_bit(&mut self, b: bool) {
        if b {
            self.current |= 1 << (7 - self.bit_pos);
        }
        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.bytes.push(self.current);
            self.current = 0;
            self.bit_pos = 0;
        }
    }

    pub fn write_bits(&mut self, n: u8, val: u16) {
        // Write bits from MSB to LSB: positions (n-1), (n-2), ..., 0
        for i in (0..n).rev() {
            self.write_bit((val >> i) & 1 == 1);
        }
    }

    pub fn flush(mut self) -> Vec<u8> {
        if self.bit_pos > 0 {
            self.bytes.push(self.current);
        }
        self.bytes
    }
}

pub struct BitReader<'a> {
    data: &'a [u8],
    byte_ix: usize,
    bit_pos: u8,
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BitReader {
            data,
            byte_ix: 0,
            bit_pos: 0,
        }
    }

    pub fn read_bit(&mut self) -> bool {
        let byte = self.data[self.byte_ix];
        let bit = (byte >> (7 - self.bit_pos)) & 1 == 1;
        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.byte_ix += 1;
            self.bit_pos = 0;
        }
        bit
    }

    pub fn read_bits(&mut self, n: u8) -> u16 {
        let mut val: u16 = 0;
        for _ in 0..n {
            val = (val << 1) | (if self.read_bit() { 1 } else { 0 });
        }
        val
    }
}

pub fn rice_encode(k: u8, val: u16, w: &mut BitWriter) {
    let q = val >> k;
    let r = val & ((1u16 << k) - 1);
    // Unary: q ones followed by one zero
    for _ in 0..q {
        w.write_bit(true);
    }
    w.write_bit(false);
    // Binary: k bits of remainder
    w.write_bits(k, r);
}

pub fn rice_decode(k: u8, r: &mut BitReader) -> u16 {
    // Read unary: count ones until zero
    let mut q: u16 = 0;
    while r.read_bit() {
        q += 1;
    }
    // Read k bits of remainder
    let remainder = r.read_bits(k);
    (q << k) | remainder
}

pub fn optimal_k(block: &[u16]) -> u8 {
    // CONFORMANCE: minimum on (cost, k) tuples.
    // By iterating k=0..=8 and using < (not <=), ties are broken by lowest k.
    let mut best_k: u8 = 0;
    let mut best_cost = encoded_bits_cost(0, block);
    for k in 1u8..=8 {
        let cost = encoded_bits_cost(k, block);
        if cost < best_cost {
            best_cost = cost;
            best_k = k;
        }
    }
    best_k
}

/// Compute the total bit cost of encoding a block with parameter k.
/// Each value costs: (val >> k) ones + 1 zero + k remainder bits
/// = (val >> k) + 1 + k
fn encoded_bits_cost(k: u8, block: &[u16]) -> u64 {
    let mut total: u64 = 0;
    for &val in block {
        total += (val >> k) as u64 + 1 + k as u64;
    }
    total
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil rice
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil/src/rice.rs && git commit -m "feat: Rice-Golomb coding with BitWriter/BitReader, TDD and proptest"
```

---

### Task 6: CRC32 and Chunk (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/chunk.rs`

- [ ] **Step 1: Write the failing tests**

Replace `sigil-rs/sigil/src/chunk.rs`:

```rust
use crate::types::SigilError;

/// Chunk tags in the Sigil format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Shdr,
    Smta,
    Spal,
    Sdat,
    Send,
}

impl Tag {
    pub fn as_bytes(self) -> &'static [u8; 4] {
        match self {
            Tag::Shdr => b"SHDR",
            Tag::Smta => b"SMTA",
            Tag::Spal => b"SPAL",
            Tag::Sdat => b"SDAT",
            Tag::Send => b"SEND",
        }
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self, SigilError> {
        match b {
            b"SHDR" => Ok(Tag::Shdr),
            b"SMTA" => Ok(Tag::Smta),
            b"SPAL" => Ok(Tag::Spal),
            b"SDAT" => Ok(Tag::Sdat),
            b"SEND" => Ok(Tag::Send),
            _ => Err(SigilError::InvalidTag),
        }
    }
}

/// A parsed chunk: tag, payload, and CRC32 of the payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    pub tag: Tag,
    pub payload: Vec<u8>,
    pub crc: u32,
}

/// Create a chunk with a computed CRC32.
pub fn make_chunk(_tag: Tag, _payload: Vec<u8>) -> Chunk {
    todo!()
}

/// Verify that the chunk's CRC matches the payload.
pub fn verify_chunk(_chunk: &Chunk) -> Result<(), SigilError> {
    todo!()
}

/// CRC32 (ISO 3309, polynomial 0xEDB88320, same as PNG).
/// Empty input returns 0x00000000.
pub fn crc32(_data: &[u8]) -> u32 {
    todo!()
}

/// Compile-time CRC32 lookup table.
const CRC_TABLE: [u32; 256] = {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            if c & 1 == 1 {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c >>= 1;
            }
            k += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_empty_is_zero() {
        assert_eq!(crc32(&[]), 0x00000000);
    }

    #[test]
    fn crc32_iend_matches_png_reference() {
        // "IEND" = [0x49, 0x45, 0x4E, 0x44]
        assert_eq!(crc32(&[0x49, 0x45, 0x4E, 0x44]), 0xAE426082);
    }

    #[test]
    fn crc32_known_value() {
        // CRC32 of "123456789" = 0xCBF43926
        assert_eq!(crc32(b"123456789"), 0xCBF43926);
    }

    #[test]
    fn make_chunk_computes_crc() {
        let chunk = make_chunk(Tag::Shdr, vec![1, 2, 3]);
        assert_eq!(chunk.crc, crc32(&[1, 2, 3]));
        assert_eq!(chunk.tag, Tag::Shdr);
        assert_eq!(chunk.payload, vec![1, 2, 3]);
    }

    #[test]
    fn verify_chunk_accepts_valid() {
        let chunk = make_chunk(Tag::Shdr, vec![1, 2, 3]);
        assert!(verify_chunk(&chunk).is_ok());
    }

    #[test]
    fn verify_chunk_rejects_corrupted() {
        let mut chunk = make_chunk(Tag::Shdr, vec![1, 2, 3]);
        chunk.payload = vec![9, 9, 9]; // corrupt
        assert!(verify_chunk(&chunk).is_err());
    }

    #[test]
    fn tag_round_trip() {
        for tag in [Tag::Shdr, Tag::Smta, Tag::Spal, Tag::Sdat, Tag::Send] {
            let bytes = tag.as_bytes();
            assert_eq!(Tag::from_bytes(bytes).unwrap(), tag);
        }
    }

    #[test]
    fn tag_from_invalid_bytes() {
        assert!(Tag::from_bytes(b"XXXX").is_err());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd sigil-rs && cargo test -p sigil chunk 2>&1 | head -20
```

Expected: tests fail with `not yet implemented` panics.

- [ ] **Step 3: Implement CRC32, make_chunk, and verify_chunk**

Replace the function bodies:

```rust
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFFFFFF;
    for &byte in data {
        let idx = ((crc ^ byte as u32) & 0xFF) as usize;
        crc = (crc >> 8) ^ CRC_TABLE[idx];
    }
    crc ^ 0xFFFFFFFF
}

pub fn make_chunk(tag: Tag, payload: Vec<u8>) -> Chunk {
    let crc = crc32(&payload);
    Chunk { tag, payload, crc }
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil chunk
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil/src/chunk.rs && git commit -m "feat: CRC32 and chunk types with compile-time lookup table"
```

---

### Task 7: Pipeline -- Compress & Decompress (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/pipeline.rs`

- [ ] **Step 1: Write the failing tests**

Replace `sigil-rs/sigil/src/pipeline.rs`:

```rust
use crate::types::{Header, PredictorId, SigilError, ColorSpace, BitDepth};
use crate::predict::{predict_image, unpredict_image};
use crate::zigzag::{zigzag, unzigzag};
use crate::token::{Token, tokenize, untokenize};
use crate::rice::{BitWriter, BitReader, rice_encode, rice_decode, optimal_k, BLOCK_SIZE};

/// Compress pixel data to the SDAT payload bytes.
pub fn compress(_header: &Header, _pixels: &[u8]) -> Vec<u8> {
    todo!()
}

/// Decompress SDAT payload bytes back to pixel data.
pub fn decompress(_header: &Header, _data: &[u8]) -> Result<Vec<u8>, SigilError> {
    todo!()
}

/// Encode token stream to bytes.
/// Format: [16-bit numBlocks] [4-bit k per block] [token bitstream]
fn encode_token_stream(_tokens: &[Token]) -> Vec<u8> {
    todo!()
}

/// Decode token stream from bytes.
fn decode_token_stream(_data: &[u8], _total_samples: usize) -> Vec<Token> {
    todo!()
}

/// Split tokens into blocks of up to BLOCK_SIZE TValues each.
/// TZeroRun tokens pass through without consuming the block's TValue budget.
/// Returns Vec of (k, Vec<Token>) for each block.
fn annotate_with_ks(tokens: &[Token], ks: &[u8]) -> Vec<(u8, Token)> {
    let mut result = Vec::new();
    let mut token_idx = 0;
    let mut k_idx = 0;
    while token_idx < tokens.len() {
        let k = if k_idx < ks.len() { ks[k_idx] } else { 0 };
        let mut budget = BLOCK_SIZE;
        while token_idx < tokens.len() && budget > 0 {
            match tokens[token_idx] {
                Token::ZeroRun(n) => {
                    result.push((k, Token::ZeroRun(n)));
                    token_idx += 1;
                    // ZeroRun does not consume block budget
                }
                Token::Value(v) => {
                    result.push((k, Token::Value(v)));
                    token_idx += 1;
                    budget -= 1;
                }
            }
        }
        // Also include trailing ZeroRuns after budget exhausted within this block
        // Actually no: when budget reaches 0, we advance to next k
        k_idx += 1;
    }
    result
}

/// Split a flat slice into chunks of `n` elements.
fn chunks_of<T: Clone>(slice: &[T], n: usize) -> Vec<Vec<T>> {
    slice.chunks(n).map(|c| c.to_vec()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_header(w: u32, h: u32, cs: ColorSpace, pid: PredictorId) -> Header {
        Header {
            width: w,
            height: h,
            color_space: cs,
            bit_depth: BitDepth::Depth8,
            predictor: pid,
        }
    }

    #[test]
    fn round_trip_fixed_none() {
        let hdr = make_header(3, 2, ColorSpace::Rgb, PredictorId::None);
        let pixels: Vec<u8> = (0..18).collect();
        let compressed = compress(&hdr, &pixels);
        let decompressed = decompress(&hdr, &compressed).unwrap();
        assert_eq!(decompressed, pixels);
    }

    #[test]
    fn round_trip_fixed_sub() {
        let hdr = make_header(4, 3, ColorSpace::Rgb, PredictorId::Sub);
        let pixels: Vec<u8> = (0..36).map(|i| (i * 7 + 3) as u8).collect();
        let compressed = compress(&hdr, &pixels);
        let decompressed = decompress(&hdr, &compressed).unwrap();
        assert_eq!(decompressed, pixels);
    }

    #[test]
    fn round_trip_adaptive() {
        let hdr = make_header(4, 3, ColorSpace::Rgb, PredictorId::Adaptive);
        let pixels: Vec<u8> = (0..36).map(|i| (i * 13 + 5) as u8).collect();
        let compressed = compress(&hdr, &pixels);
        let decompressed = decompress(&hdr, &compressed).unwrap();
        assert_eq!(decompressed, pixels);
    }

    #[test]
    fn round_trip_grayscale() {
        let hdr = make_header(8, 4, ColorSpace::Grayscale, PredictorId::Adaptive);
        let pixels: Vec<u8> = (0..32).map(|i| (i * 3) as u8).collect();
        let compressed = compress(&hdr, &pixels);
        let decompressed = decompress(&hdr, &compressed).unwrap();
        assert_eq!(decompressed, pixels);
    }

    #[test]
    fn round_trip_rgba() {
        let hdr = make_header(4, 3, ColorSpace::Rgba, PredictorId::Adaptive);
        let pixels: Vec<u8> = (0..48).map(|i| (i * 11 + 7) as u8).collect();
        let compressed = compress(&hdr, &pixels);
        let decompressed = decompress(&hdr, &compressed).unwrap();
        assert_eq!(decompressed, pixels);
    }

    #[test]
    fn round_trip_all_fixed_predictors() {
        for &pid in &crate::types::FIXED_PREDICTORS {
            let hdr = make_header(5, 4, ColorSpace::Rgb, pid);
            let pixels: Vec<u8> = (0..60).map(|i| (i * 17 + 3) as u8).collect();
            let compressed = compress(&hdr, &pixels);
            let decompressed = decompress(&hdr, &compressed).unwrap();
            assert_eq!(decompressed, pixels, "failed for {pid:?}");
        }
    }

    #[test]
    fn round_trip_flat_image() {
        let hdr = make_header(10, 10, ColorSpace::Rgb, PredictorId::Adaptive);
        let pixels = vec![128u8; 300]; // all-same values
        let compressed = compress(&hdr, &pixels);
        let decompressed = decompress(&hdr, &compressed).unwrap();
        assert_eq!(decompressed, pixels);
    }

    #[test]
    fn token_stream_round_trip() {
        let tokens = vec![
            Token::ZeroRun(5),
            Token::Value(42),
            Token::Value(7),
            Token::ZeroRun(3),
            Token::Value(100),
        ];
        let encoded = encode_token_stream(&tokens);
        // Total samples: 5 + 1 + 1 + 3 + 1 = 11
        let decoded = decode_token_stream(&encoded, 11);
        assert_eq!(decoded, tokens);
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
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
        fn pipeline_round_trip_fixed(
            pid in arb_fixed_predictor(),
            w in 1u32..=16,
            h in 1u32..=16,
        ) {
            let hdr = Header {
                width: w,
                height: h,
                color_space: ColorSpace::Rgb,
                bit_depth: BitDepth::Depth8,
                predictor: pid,
            };
            let num_bytes = (w * h * 3) as usize;
            let pixels: Vec<u8> = (0..num_bytes).map(|i| (i * 13 + 7) as u8).collect();
            let compressed = compress(&hdr, &pixels);
            let decompressed = decompress(&hdr, &compressed).unwrap();
            prop_assert_eq!(decompressed, pixels);
        }

        #[test]
        fn pipeline_round_trip_adaptive(
            w in 1u32..=16,
            h in 1u32..=16,
        ) {
            let hdr = Header {
                width: w,
                height: h,
                color_space: ColorSpace::Rgb,
                bit_depth: BitDepth::Depth8,
                predictor: PredictorId::Adaptive,
            };
            let num_bytes = (w * h * 3) as usize;
            let pixels: Vec<u8> = (0..num_bytes).map(|i| (i * 23 + 5) as u8).collect();
            let compressed = compress(&hdr, &pixels);
            let decompressed = decompress(&hdr, &compressed).unwrap();
            prop_assert_eq!(decompressed, pixels);
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd sigil-rs && cargo test -p sigil pipeline 2>&1 | head -20
```

Expected: tests fail with `not yet implemented` panics.

- [ ] **Step 3: Implement the pipeline**

Replace the function bodies (keep all tests and `annotate_with_ks` and `chunks_of`):

```rust
pub fn compress(header: &Header, pixels: &[u8]) -> Vec<u8> {
    // 1. Predict
    let (pids, residual_rows) = predict_image(header, pixels);

    // 2. Zigzag
    let zigzag_rows: Vec<Vec<u16>> = residual_rows
        .iter()
        .map(|row| row.iter().map(|&r| zigzag(r)).collect())
        .collect();

    // 3. Encode
    encode_data(header, &pids, &zigzag_rows)
}

pub fn decompress(header: &Header, data: &[u8]) -> Result<Vec<u8>, SigilError> {
    // 1. Decode
    let (pids, zigzag_rows) = decode_data(header, data);

    // 2. Un-zigzag
    let residual_rows: Vec<Vec<i16>> = zigzag_rows
        .iter()
        .map(|row| row.iter().map(|&v| unzigzag(v)).collect())
        .collect();

    // 3. Unpredict
    let pixels = unpredict_image(header, &pids, &residual_rows);
    Ok(pixels)
}

fn encode_data(
    header: &Header,
    pids: &[PredictorId],
    rows: &[Vec<u16>],
) -> Vec<u8> {
    // Predictor ID bytes (only if adaptive)
    let mut pid_bytes = Vec::new();
    if header.predictor == PredictorId::Adaptive {
        pid_bytes = pids.iter().map(|p| p.to_u8()).collect();
    }

    // Flatten all rows
    let flat: Vec<u16> = rows.iter().flat_map(|r| r.iter().copied()).collect();

    // Tokenize
    let tokens = tokenize(&flat);

    // Encode token stream
    let mut result = pid_bytes;
    result.extend(encode_token_stream(&tokens));
    result
}

fn decode_data(
    header: &Header,
    data: &[u8],
) -> (Vec<PredictorId>, Vec<Vec<u16>>) {
    let num_rows = header.height as usize;
    let row_len = header.row_bytes();
    let total_samples = num_rows * row_len;

    let (pids, rest) = if header.predictor == PredictorId::Adaptive {
        let pid_bytes = &data[..num_rows];
        let pids: Vec<PredictorId> = pid_bytes
            .iter()
            .map(|&b| PredictorId::from_u8(b).unwrap())
            .collect();
        (pids, &data[num_rows..])
    } else {
        (vec![header.predictor; num_rows], data)
    };

    let tokens = decode_token_stream(rest, total_samples);
    let flat = untokenize(&tokens);

    let rows: Vec<Vec<u16>> = (0..num_rows)
        .map(|i| flat[i * row_len..(i + 1) * row_len].to_vec())
        .collect();

    (pids, rows)
}

fn encode_token_stream(tokens: &[Token]) -> Vec<u8> {
    // Collect all TValue values
    let values: Vec<u16> = tokens
        .iter()
        .filter_map(|t| match t {
            Token::Value(v) => Some(*v),
            _ => None,
        })
        .collect();

    // Split values into blocks of BLOCK_SIZE
    let blocks = chunks_of(&values, BLOCK_SIZE);
    let ks: Vec<u8> = blocks.iter().map(|b| optimal_k(b)).collect();
    let num_blocks = ks.len();

    let mut w = BitWriter::new();

    // Write 16-bit numBlocks
    w.write_bits(16, num_blocks as u16);

    // Write 4-bit k per block
    for &k in &ks {
        w.write_bits(4, k as u16);
    }

    // Annotate tokens with their block's k
    let annotated = annotate_with_ks(tokens, &ks);

    // Encode each annotated token
    for (k, token) in &annotated {
        match token {
            Token::ZeroRun(n) => {
                w.write_bit(false); // flag 0 = ZeroRun
                w.write_bits(16, *n);
            }
            Token::Value(v) => {
                w.write_bit(true); // flag 1 = Value
                rice_encode(*k, *v, &mut w);
            }
        }
    }

    w.flush()
}

fn decode_token_stream(data: &[u8], total_samples: usize) -> Vec<Token> {
    let mut r = BitReader::new(data);

    // Read 16-bit numBlocks
    let num_blocks = r.read_bits(16) as usize;

    // Read 4-bit k per block
    let mut ks: Vec<u8> = Vec::with_capacity(num_blocks);
    for _ in 0..num_blocks {
        ks.push(r.read_bits(4) as u8);
    }

    // Decode tokens
    let mut tokens = Vec::new();
    let mut remaining = total_samples as i64;
    let mut k_idx: usize = 0;
    let mut tval_pos: usize = 0;

    while remaining > 0 {
        let k = if k_idx < ks.len() { ks[k_idx] } else { 0 };
        let flag = r.read_bit();
        if flag {
            // TValue
            let val = rice_decode(k, &mut r);
            tokens.push(Token::Value(val));
            remaining -= 1;
            tval_pos += 1;
            if tval_pos >= BLOCK_SIZE {
                k_idx += 1;
                tval_pos = 0;
            }
        } else {
            // TZeroRun
            let run_len = r.read_bits(16);
            tokens.push(Token::ZeroRun(run_len));
            remaining -= run_len as i64;
            // ZeroRun does NOT advance tval_pos or k_idx
        }
    }

    tokens
}

fn annotate_with_ks(tokens: &[Token], ks: &[u8]) -> Vec<(u8, Token)> {
    let mut result = Vec::new();
    let mut token_idx = 0;
    let mut k_idx = 0;

    while token_idx < tokens.len() {
        let k = if k_idx < ks.len() { ks[k_idx] } else { 0 };
        let mut budget = BLOCK_SIZE;

        while token_idx < tokens.len() {
            match tokens[token_idx] {
                Token::ZeroRun(n) => {
                    result.push((k, Token::ZeroRun(n)));
                    token_idx += 1;
                    // ZeroRun does not consume block budget
                }
                Token::Value(v) => {
                    if budget == 0 {
                        break; // advance to next block
                    }
                    result.push((k, Token::Value(v)));
                    token_idx += 1;
                    budget -= 1;
                }
            }
        }
        k_idx += 1;
    }
    result
}

fn chunks_of<T: Clone>(slice: &[T], n: usize) -> Vec<Vec<T>> {
    slice.chunks(n).map(|c| c.to_vec()).collect()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil pipeline
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil/src/pipeline.rs && git commit -m "feat: compress/decompress pipeline with token stream encoding"
```

---

### Task 8: File I/O -- Writer & Reader (TDD)

**Files:**
- Modify: `sigil-rs/sigil/src/writer.rs`
- Modify: `sigil-rs/sigil/src/reader.rs`

- [ ] **Step 1: Write the writer with tests**

Replace `sigil-rs/sigil/src/writer.rs`:

```rust
use crate::types::{Header, Metadata, SigilError, BitDepth};
use crate::chunk::{Tag, make_chunk};
use crate::pipeline::compress;

/// Magic bytes: 0x89 S G L \r \n
pub const MAGIC: [u8; 6] = [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A];
pub const VERSION_MAJOR: u8 = 0;
pub const VERSION_MINOR: u8 = 2;

/// Encode a complete .sgl file from header, metadata, and raw pixel data.
pub fn encode_sigil_file(header: &Header, metadata: &Metadata, pixels: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();

    // Magic + version
    out.extend_from_slice(&MAGIC);
    out.push(VERSION_MAJOR);
    out.push(VERSION_MINOR);

    // SHDR chunk
    let hdr_payload = encode_header(header);
    let shdr = make_chunk(Tag::Shdr, hdr_payload);
    write_chunk(&mut out, &shdr);

    // Optional SMTA chunk
    if !metadata.entries.is_empty() {
        let meta_payload = encode_metadata(metadata);
        let smta = make_chunk(Tag::Smta, meta_payload);
        write_chunk(&mut out, &smta);
    }

    // SDAT chunk
    let sdat_payload = compress(header, pixels);
    let sdat = make_chunk(Tag::Sdat, sdat_payload);
    write_chunk(&mut out, &sdat);

    // SEND chunk
    let send = make_chunk(Tag::Send, Vec::new());
    write_chunk(&mut out, &send);

    out
}

/// Write header + metadata + pre-compressed SDAT payload (used by reader tests).
pub fn encode_sigil_file_raw(
    header: &Header,
    metadata: &Metadata,
    sdat_payload: Vec<u8>,
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.push(VERSION_MAJOR);
    out.push(VERSION_MINOR);
    let shdr = make_chunk(Tag::Shdr, encode_header(header));
    write_chunk(&mut out, &shdr);
    if !metadata.entries.is_empty() {
        let smta = make_chunk(Tag::Smta, encode_metadata(metadata));
        write_chunk(&mut out, &smta);
    }
    let sdat = make_chunk(Tag::Sdat, sdat_payload);
    write_chunk(&mut out, &sdat);
    let send = make_chunk(Tag::Send, Vec::new());
    write_chunk(&mut out, &send);
    out
}

fn write_chunk(out: &mut Vec<u8>, chunk: &crate::chunk::Chunk) {
    out.extend_from_slice(chunk.tag.as_bytes());
    out.extend_from_slice(&(chunk.payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&chunk.payload);
    out.extend_from_slice(&chunk.crc.to_be_bytes());
}

/// Encode the header into its binary representation (11 bytes).
/// Width (u32 BE) + Height (u32 BE) + ColorSpace (u8) + BitDepth (u8: 8 or 16) + Predictor (u8)
pub fn encode_header(header: &Header) -> Vec<u8> {
    let mut out = Vec::with_capacity(11);
    out.extend_from_slice(&header.width.to_be_bytes());
    out.extend_from_slice(&header.height.to_be_bytes());
    out.push(header.color_space as u8);
    out.push(header.bit_depth.to_byte()); // 8 or 16, NOT enum index
    out.push(header.predictor.to_u8());
    out
}

fn encode_metadata(metadata: &Metadata) -> Vec<u8> {
    let mut out = Vec::new();
    for (key, value) in &metadata.entries {
        let key_bytes = key.as_bytes();
        out.extend_from_slice(&(key_bytes.len() as u16).to_be_bytes());
        out.extend_from_slice(key_bytes);
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value);
    }
    out
}

/// Write a .sgl file to disk.
pub fn write_sigil_file(
    path: &std::path::Path,
    header: &Header,
    metadata: &Metadata,
    pixels: &[u8],
) -> Result<(), SigilError> {
    let data = encode_sigil_file(header, metadata, pixels);
    std::fs::write(path, data)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ColorSpace, PredictorId};

    #[test]
    fn encode_header_size() {
        let hdr = Header {
            width: 256,
            height: 128,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::Adaptive,
        };
        let encoded = encode_header(&hdr);
        assert_eq!(encoded.len(), 11);
    }

    #[test]
    fn encode_header_values() {
        let hdr = Header {
            width: 256,
            height: 128,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::Adaptive,
        };
        let encoded = encode_header(&hdr);
        // Width = 256 = 0x00000100
        assert_eq!(&encoded[0..4], &[0, 0, 1, 0]);
        // Height = 128 = 0x00000080
        assert_eq!(&encoded[4..8], &[0, 0, 0, 128]);
        // ColorSpace = RGB = 2
        assert_eq!(encoded[8], 2);
        // BitDepth = 8 (raw value, not enum index)
        assert_eq!(encoded[9], 8);
        // Predictor = Adaptive = 6
        assert_eq!(encoded[10], 6);
    }

    #[test]
    fn encode_header_depth16() {
        let hdr = Header {
            width: 1,
            height: 1,
            color_space: ColorSpace::Grayscale,
            bit_depth: BitDepth::Depth16,
            predictor: PredictorId::None,
        };
        let encoded = encode_header(&hdr);
        assert_eq!(encoded[9], 16); // NOT 1 (enum index)
    }

    #[test]
    fn file_starts_with_magic_and_version() {
        let hdr = Header {
            width: 2,
            height: 2,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::None,
        };
        let pixels = vec![0u8; 12];
        let data = encode_sigil_file(&hdr, &Metadata::default(), &pixels);
        assert_eq!(&data[0..6], &MAGIC);
        assert_eq!(data[6], VERSION_MAJOR);
        assert_eq!(data[7], VERSION_MINOR);
    }

    #[test]
    fn file_has_shdr_chunk_after_header() {
        let hdr = Header {
            width: 1,
            height: 1,
            color_space: ColorSpace::Grayscale,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::None,
        };
        let pixels = vec![128u8];
        let data = encode_sigil_file(&hdr, &Metadata::default(), &pixels);
        // After magic (6) + version (2) = offset 8
        assert_eq!(&data[8..12], b"SHDR");
    }

    #[test]
    fn file_ends_with_send_chunk() {
        let hdr = Header {
            width: 1,
            height: 1,
            color_space: ColorSpace::Grayscale,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::None,
        };
        let pixels = vec![128u8];
        let data = encode_sigil_file(&hdr, &Metadata::default(), &pixels);
        // SEND chunk: tag(4) + length(4, =0) + crc(4) = 12 bytes from end
        let send_start = data.len() - 12;
        assert_eq!(&data[send_start..send_start + 4], b"SEND");
        // Length = 0
        assert_eq!(&data[send_start + 4..send_start + 8], &[0, 0, 0, 0]);
    }
}
```

- [ ] **Step 2: Write the reader with tests**

Replace `sigil-rs/sigil/src/reader.rs`:

```rust
use crate::types::{Header, Metadata, ColorSpace, BitDepth, PredictorId, SigilError};
use crate::chunk::{Tag, Chunk, verify_chunk, crc32};
use crate::pipeline::decompress;
use crate::writer::MAGIC;

/// Decode a .sgl file from bytes, returning header, metadata, and raw pixel data.
pub fn decode_sigil_file(data: &[u8]) -> Result<(Header, Metadata, Vec<u8>), SigilError> {
    if data.len() < 8 {
        return Err(SigilError::TruncatedInput);
    }

    // Validate magic
    if data[0..6] != MAGIC {
        return Err(SigilError::InvalidMagic);
    }

    // Validate version
    let major = data[6];
    let minor = data[7];
    if major != 0 || minor != 2 {
        return Err(SigilError::UnsupportedVersion { major, minor });
    }

    // Read chunks
    let chunks = read_chunks(&data[8..])?;

    // Verify all CRCs
    for chunk in &chunks {
        verify_chunk(chunk)?;
    }

    // Find SHDR
    let shdr = chunks
        .iter()
        .find(|c| c.tag == Tag::Shdr)
        .ok_or_else(|| SigilError::MissingChunk("SHDR".to_string()))?;
    let header = decode_header(&shdr.payload)?;

    // Optional SMTA
    let metadata = chunks
        .iter()
        .find(|c| c.tag == Tag::Smta)
        .map(|c| decode_metadata(&c.payload))
        .unwrap_or_else(|| Ok(Metadata::default()))?;

    // Concatenate SDAT payloads
    let sdat_payload: Vec<u8> = chunks
        .iter()
        .filter(|c| c.tag == Tag::Sdat)
        .flat_map(|c| c.payload.iter().copied())
        .collect();

    // Decompress
    let pixels = decompress(&header, &sdat_payload)?;

    Ok((header, metadata, pixels))
}

fn read_chunks(mut data: &[u8]) -> Result<Vec<Chunk>, SigilError> {
    let mut chunks = Vec::new();
    loop {
        if data.len() < 8 {
            return Err(SigilError::TruncatedInput);
        }
        let tag = Tag::from_bytes(&data[0..4])?;
        let len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
        if data.len() < 8 + len + 4 {
            return Err(SigilError::TruncatedInput);
        }
        let payload = data[8..8 + len].to_vec();
        let crc = u32::from_be_bytes([
            data[8 + len],
            data[8 + len + 1],
            data[8 + len + 2],
            data[8 + len + 3],
        ]);
        let chunk = Chunk { tag, payload, crc };
        let is_end = tag == Tag::Send;
        chunks.push(chunk);
        if is_end {
            break;
        }
        data = &data[8 + len + 4..];
    }
    Ok(chunks)
}

fn decode_header(data: &[u8]) -> Result<Header, SigilError> {
    if data.len() < 11 {
        return Err(SigilError::TruncatedInput);
    }
    let width = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
    let height = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
    if width == 0 || height == 0 {
        return Err(SigilError::InvalidDimensions(width, height));
    }
    let color_space = ColorSpace::from_u8(data[8])?;
    let bit_depth = BitDepth::from_byte(data[9])?;
    let predictor = PredictorId::from_u8(data[10])?;
    Ok(Header {
        width,
        height,
        color_space,
        bit_depth,
        predictor,
    })
}

fn decode_metadata(data: &[u8]) -> Result<Metadata, SigilError> {
    let mut entries = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        if pos + 2 > data.len() {
            break;
        }
        let key_len = u16::from_be_bytes([data[pos], data[pos + 1]]) as usize;
        pos += 2;
        if pos + key_len > data.len() {
            break;
        }
        let key = String::from_utf8_lossy(&data[pos..pos + key_len]).to_string();
        pos += key_len;
        if pos + 4 > data.len() {
            break;
        }
        let val_len =
            u32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]) as usize;
        pos += 4;
        if pos + val_len > data.len() {
            break;
        }
        let value = data[pos..pos + val_len].to_vec();
        pos += val_len;
        entries.push((key, value));
    }
    Ok(Metadata { entries })
}

/// Read a .sgl file from disk.
pub fn read_sigil_file(
    path: &std::path::Path,
) -> Result<(Header, Metadata, Vec<u8>), SigilError> {
    let data = std::fs::read(path)?;
    decode_sigil_file(&data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::writer::encode_sigil_file;

    fn make_header(w: u32, h: u32) -> Header {
        Header {
            width: w,
            height: h,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::Adaptive,
        }
    }

    #[test]
    fn round_trip_small_image() {
        let hdr = make_header(3, 2);
        let pixels: Vec<u8> = (0..18).collect();
        let encoded = encode_sigil_file(&hdr, &Metadata::default(), &pixels);
        let (decoded_hdr, _, decoded_pixels) = decode_sigil_file(&encoded).unwrap();
        assert_eq!(decoded_hdr, hdr);
        assert_eq!(decoded_pixels, pixels);
    }

    #[test]
    fn round_trip_with_metadata() {
        let hdr = make_header(2, 2);
        let pixels = vec![0u8; 12];
        let meta = Metadata {
            entries: vec![
                ("author".to_string(), b"test".to_vec()),
                ("comment".to_string(), b"hello world".to_vec()),
            ],
        };
        let encoded = encode_sigil_file(&hdr, &meta, &pixels);
        let (decoded_hdr, decoded_meta, decoded_pixels) = decode_sigil_file(&encoded).unwrap();
        assert_eq!(decoded_hdr, hdr);
        assert_eq!(decoded_meta, meta);
        assert_eq!(decoded_pixels, pixels);
    }

    #[test]
    fn rejects_bad_magic() {
        let data = vec![0x00; 100];
        assert!(matches!(
            decode_sigil_file(&data),
            Err(SigilError::InvalidMagic)
        ));
    }

    #[test]
    fn rejects_bad_version() {
        let mut data = Vec::new();
        data.extend_from_slice(&MAGIC);
        data.push(1); // major = 1
        data.push(0); // minor = 0
        data.extend_from_slice(&[0; 100]);
        assert!(matches!(
            decode_sigil_file(&data),
            Err(SigilError::UnsupportedVersion { major: 1, minor: 0 })
        ));
    }

    #[test]
    fn rejects_truncated_input() {
        let data = vec![0x89, 0x53, 0x47]; // too short
        assert!(matches!(
            decode_sigil_file(&data),
            Err(SigilError::TruncatedInput)
        ));
    }

    #[test]
    fn header_round_trip() {
        let hdr = Header {
            width: 1920,
            height: 1080,
            color_space: ColorSpace::Rgba,
            bit_depth: BitDepth::Depth16,
            predictor: PredictorId::Paeth,
        };
        let encoded = crate::writer::encode_header(&hdr);
        let decoded = decode_header(&encoded).unwrap();
        assert_eq!(decoded, hdr);
    }

    #[test]
    fn all_predictors_round_trip() {
        for pid_val in 0u8..=6 {
            let pid = PredictorId::from_u8(pid_val).unwrap();
            let hdr = Header {
                width: 4,
                height: 3,
                color_space: ColorSpace::Rgb,
                bit_depth: BitDepth::Depth8,
                predictor: pid,
            };
            let pixels: Vec<u8> = (0..36).map(|i| (i * 7 + 3) as u8).collect();
            let encoded = encode_sigil_file(&hdr, &Metadata::default(), &pixels);
            let (decoded_hdr, _, decoded_pixels) = decode_sigil_file(&encoded).unwrap();
            assert_eq!(decoded_hdr, hdr);
            assert_eq!(decoded_pixels, pixels);
        }
    }
}

#[cfg(test)]
mod proptests {
    use super::*;
    use crate::writer::encode_sigil_file;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn file_round_trip(
            w in 1u32..=16,
            h in 1u32..=16,
        ) {
            let hdr = Header {
                width: w,
                height: h,
                color_space: ColorSpace::Rgb,
                bit_depth: BitDepth::Depth8,
                predictor: PredictorId::Adaptive,
            };
            let num_bytes = (w * h * 3) as usize;
            let pixels: Vec<u8> = (0..num_bytes).map(|i| (i * 13 + 7) as u8).collect();
            let encoded = encode_sigil_file(&hdr, &Metadata::default(), &pixels);
            let (decoded_hdr, _, decoded_pixels) = decode_sigil_file(&encoded).unwrap();
            prop_assert_eq!(decoded_hdr, hdr);
            prop_assert_eq!(decoded_pixels, pixels);
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil writer && cargo test -p sigil reader
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add sigil-rs/sigil/src/writer.rs sigil-rs/sigil/src/reader.rs && git commit -m "feat: .sgl file writer and reader with TDD"
```

---

### Task 9: Image Conversion (image crate)

**Files:**
- Modify: `sigil-rs/sigil/src/convert.rs`

- [ ] **Step 1: Write the conversion module with tests**

Replace `sigil-rs/sigil/src/convert.rs`:

```rust
use image::{DynamicImage, RgbImage, RgbaImage, GrayImage, GrayAlphaImage};
use crate::types::{Header, ColorSpace, BitDepth, PredictorId, SigilError};

/// Load a PNG/JPEG/BMP image and convert to Sigil (Header, flat pixel data).
/// Default predictor for loaded images: PAdaptive.
pub fn load_image(path: &std::path::Path) -> Result<(Header, Vec<u8>), SigilError> {
    let img = image::open(path)?;
    Ok(dynamic_to_sigil(&img))
}

/// Save pixel data as a PNG file.
pub fn save_image(
    path: &std::path::Path,
    header: &Header,
    pixels: &[u8],
) -> Result<(), SigilError> {
    match header.color_space {
        ColorSpace::Rgb => {
            let img = sigil_to_rgb(header, pixels);
            img.save(path)?;
        }
        ColorSpace::Rgba => {
            let img = sigil_to_rgba(header, pixels);
            img.save(path)?;
        }
        ColorSpace::Grayscale => {
            let img = sigil_to_gray(header, pixels);
            img.save(path)?;
        }
        ColorSpace::GrayscaleAlpha => {
            let img = sigil_to_gray_alpha(header, pixels);
            img.save(path)?;
        }
    }
    Ok(())
}

/// Convert a DynamicImage to Sigil (Header, flat pixel data).
pub fn dynamic_to_sigil(img: &DynamicImage) -> (Header, Vec<u8>) {
    match img {
        DynamicImage::ImageRgb8(rgb) => rgb_to_sigil(rgb),
        DynamicImage::ImageRgba8(rgba) => rgba_to_sigil(rgba),
        DynamicImage::ImageLuma8(gray) => gray_to_sigil(gray),
        DynamicImage::ImageLumaA8(ga) => gray_alpha_to_sigil(ga),
        // Convert anything else to RGB8
        other => rgb_to_sigil(&other.to_rgb8()),
    }
}

fn rgb_to_sigil(img: &RgbImage) -> (Header, Vec<u8>) {
    let w = img.width();
    let h = img.height();
    let header = Header {
        width: w,
        height: h,
        color_space: ColorSpace::Rgb,
        bit_depth: BitDepth::Depth8,
        predictor: PredictorId::Adaptive,
    };
    let pixels = img.as_raw().clone();
    (header, pixels)
}

fn rgba_to_sigil(img: &RgbaImage) -> (Header, Vec<u8>) {
    let w = img.width();
    let h = img.height();
    let header = Header {
        width: w,
        height: h,
        color_space: ColorSpace::Rgba,
        bit_depth: BitDepth::Depth8,
        predictor: PredictorId::Adaptive,
    };
    let pixels = img.as_raw().clone();
    (header, pixels)
}

fn gray_to_sigil(img: &GrayImage) -> (Header, Vec<u8>) {
    let w = img.width();
    let h = img.height();
    let header = Header {
        width: w,
        height: h,
        color_space: ColorSpace::Grayscale,
        bit_depth: BitDepth::Depth8,
        predictor: PredictorId::Adaptive,
    };
    let pixels = img.as_raw().clone();
    (header, pixels)
}

fn gray_alpha_to_sigil(img: &GrayAlphaImage) -> (Header, Vec<u8>) {
    let w = img.width();
    let h = img.height();
    let header = Header {
        width: w,
        height: h,
        color_space: ColorSpace::GrayscaleAlpha,
        bit_depth: BitDepth::Depth8,
        predictor: PredictorId::Adaptive,
    };
    let pixels = img.as_raw().clone();
    (header, pixels)
}

fn sigil_to_rgb(header: &Header, pixels: &[u8]) -> RgbImage {
    RgbImage::from_raw(header.width, header.height, pixels.to_vec())
        .expect("pixel data size mismatch for RGB")
}

fn sigil_to_rgba(header: &Header, pixels: &[u8]) -> RgbaImage {
    RgbaImage::from_raw(header.width, header.height, pixels.to_vec())
        .expect("pixel data size mismatch for RGBA")
}

fn sigil_to_gray(header: &Header, pixels: &[u8]) -> GrayImage {
    GrayImage::from_raw(header.width, header.height, pixels.to_vec())
        .expect("pixel data size mismatch for Grayscale")
}

fn sigil_to_gray_alpha(header: &Header, pixels: &[u8]) -> GrayAlphaImage {
    GrayAlphaImage::from_raw(header.width, header.height, pixels.to_vec())
        .expect("pixel data size mismatch for GrayscaleAlpha")
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, Rgba, Luma, LumaA};

    #[test]
    fn rgb_round_trip() {
        let mut img = RgbImage::new(4, 4);
        for y in 0..4 {
            for x in 0..4 {
                img.put_pixel(x, y, Rgb([x as u8 * 10, y as u8 * 20, 128]));
            }
        }
        let (hdr, pixels) = rgb_to_sigil(&img);
        assert_eq!(hdr.width, 4);
        assert_eq!(hdr.height, 4);
        assert_eq!(hdr.color_space, ColorSpace::Rgb);
        let recovered = sigil_to_rgb(&hdr, &pixels);
        assert_eq!(recovered.dimensions(), img.dimensions());
        for y in 0..4 {
            for x in 0..4 {
                assert_eq!(recovered.get_pixel(x, y), img.get_pixel(x, y));
            }
        }
    }

    #[test]
    fn rgba_round_trip() {
        let mut img = RgbaImage::new(3, 3);
        for y in 0..3 {
            for x in 0..3 {
                img.put_pixel(x, y, Rgba([x as u8, y as u8, 100, 255]));
            }
        }
        let (hdr, pixels) = rgba_to_sigil(&img);
        assert_eq!(hdr.color_space, ColorSpace::Rgba);
        let recovered = sigil_to_rgba(&hdr, &pixels);
        for y in 0..3 {
            for x in 0..3 {
                assert_eq!(recovered.get_pixel(x, y), img.get_pixel(x, y));
            }
        }
    }

    #[test]
    fn gray_round_trip() {
        let mut img = GrayImage::new(5, 5);
        for y in 0..5 {
            for x in 0..5 {
                img.put_pixel(x, y, Luma([(x * 10 + y * 5) as u8]));
            }
        }
        let (hdr, pixels) = gray_to_sigil(&img);
        assert_eq!(hdr.color_space, ColorSpace::Grayscale);
        let recovered = sigil_to_gray(&hdr, &pixels);
        for y in 0..5 {
            for x in 0..5 {
                assert_eq!(recovered.get_pixel(x, y), img.get_pixel(x, y));
            }
        }
    }

    #[test]
    fn gray_alpha_round_trip() {
        let mut img = GrayAlphaImage::new(3, 3);
        for y in 0..3 {
            for x in 0..3 {
                img.put_pixel(x, y, LumaA([(x * 30) as u8, 200]));
            }
        }
        let (hdr, pixels) = gray_alpha_to_sigil(&img);
        assert_eq!(hdr.color_space, ColorSpace::GrayscaleAlpha);
        let recovered = sigil_to_gray_alpha(&hdr, &pixels);
        for y in 0..3 {
            for x in 0..3 {
                assert_eq!(recovered.get_pixel(x, y), img.get_pixel(x, y));
            }
        }
    }

    #[test]
    fn dynamic_rgb_conversion() {
        let img = RgbImage::from_fn(2, 2, |x, y| {
            Rgb([(x * 100) as u8, (y * 100) as u8, 50])
        });
        let dyn_img = DynamicImage::ImageRgb8(img.clone());
        let (hdr, pixels) = dynamic_to_sigil(&dyn_img);
        assert_eq!(hdr.color_space, ColorSpace::Rgb);
        assert_eq!(hdr.predictor, PredictorId::Adaptive);
        assert_eq!(pixels, *img.as_raw());
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd sigil-rs && cargo test -p sigil convert
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add sigil-rs/sigil/src/convert.rs && git commit -m "feat: image crate conversion for PNG/JPEG I/O"
```

---

### Task 10: lib.rs Public API

**Files:**
- Modify: `sigil-rs/sigil/src/lib.rs`

- [ ] **Step 1: Update lib.rs with public API re-exports**

Replace `sigil-rs/sigil/src/lib.rs`:

```rust
pub mod types;
pub mod zigzag;
pub mod predict;
pub mod token;
pub mod rice;
pub mod chunk;
pub mod pipeline;
pub mod writer;
pub mod reader;
pub mod convert;

pub use types::*;

use std::path::Path;

/// High-level: encode raw pixel data to .sgl bytes.
pub fn encode(header: &Header, pixels: &[u8]) -> Result<Vec<u8>, SigilError> {
    Ok(writer::encode_sigil_file(header, &Metadata::default(), pixels))
}

/// High-level: decode .sgl bytes to header + raw pixel data.
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError> {
    let (header, _meta, pixels) = reader::decode_sigil_file(data)?;
    Ok((header, pixels))
}

/// High-level: read header without decoding pixel data.
pub fn read_header(data: &[u8]) -> Result<Header, SigilError> {
    // Parse just enough to get the SHDR chunk
    if data.len() < 8 {
        return Err(SigilError::TruncatedInput);
    }
    if data[0..6] != writer::MAGIC {
        return Err(SigilError::InvalidMagic);
    }
    // Skip to first chunk (offset 8), read SHDR
    let chunk_data = &data[8..];
    if chunk_data.len() < 8 {
        return Err(SigilError::TruncatedInput);
    }
    let tag = chunk::Tag::from_bytes(&chunk_data[0..4])?;
    if tag != chunk::Tag::Shdr {
        return Err(SigilError::MissingChunk("SHDR".to_string()));
    }
    let len = u32::from_be_bytes([chunk_data[4], chunk_data[5], chunk_data[6], chunk_data[7]]) as usize;
    if chunk_data.len() < 8 + len {
        return Err(SigilError::TruncatedInput);
    }
    let payload = &chunk_data[8..8 + len];
    // Decode header from payload (same logic as reader, but without full file parse)
    if payload.len() < 11 {
        return Err(SigilError::TruncatedInput);
    }
    let width = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let height = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
    if width == 0 || height == 0 {
        return Err(SigilError::InvalidDimensions(width, height));
    }
    let color_space = ColorSpace::from_u8(payload[8])?;
    let bit_depth = BitDepth::from_byte(payload[9])?;
    let predictor = PredictorId::from_u8(payload[10])?;
    Ok(Header { width, height, color_space, bit_depth, predictor })
}

/// High-level: encode a PNG/JPEG/BMP file to .sgl format.
pub fn encode_file(input: &Path, output: &Path) -> Result<(), SigilError> {
    let (header, pixels) = convert::load_image(input)?;
    writer::write_sigil_file(output, &header, &Metadata::default(), &pixels)
}

/// High-level: decode a .sgl file to PNG.
pub fn decode_file(input: &Path, output: &Path) -> Result<(), SigilError> {
    let (header, _meta, pixels) = reader::read_sigil_file(input)?;
    convert::save_image(output, &header, &pixels)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_round_trip() {
        let hdr = Header {
            width: 4,
            height: 3,
            color_space: ColorSpace::Rgb,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::Adaptive,
        };
        let pixels: Vec<u8> = (0..36).map(|i| (i * 7 + 13) as u8).collect();
        let encoded = encode(&hdr, &pixels).unwrap();
        let (decoded_hdr, decoded_pixels) = decode(&encoded).unwrap();
        assert_eq!(decoded_hdr, hdr);
        assert_eq!(decoded_pixels, pixels);
    }

    #[test]
    fn read_header_from_encoded() {
        let hdr = Header {
            width: 100,
            height: 50,
            color_space: ColorSpace::Rgba,
            bit_depth: BitDepth::Depth8,
            predictor: PredictorId::Gradient,
        };
        let pixels = vec![0u8; 100 * 50 * 4];
        let encoded = encode(&hdr, &pixels).unwrap();
        let parsed = read_header(&encoded).unwrap();
        assert_eq!(parsed, hdr);
    }
}
```

- [ ] **Step 2: Build and test**

```bash
cd sigil-rs && cargo test -p sigil
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add sigil-rs/sigil/src/lib.rs && git commit -m "feat: public API with encode/decode/encode_file/decode_file"
```

---

### Task 11: Conformance Tests

**Files:**
- Create: `sigil-rs/sigil/tests/conformance.rs`

- [ ] **Step 1: Write the conformance test**

Create `sigil-rs/sigil/tests/conformance.rs`:

```rust
//! Byte-for-byte conformance tests against the sigil-hs golden .sgl files.
//!
//! These tests verify that the Rust implementation produces identical output
//! to the Haskell reference implementation for every corpus image.

use std::path::PathBuf;

fn corpus_dir() -> PathBuf {
    // From sigil-rs/sigil/tests/ -> ../../tests/corpus/
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/corpus")
}

fn expected_dir() -> PathBuf {
    corpus_dir().join("expected")
}

const TEST_IMAGES: &[&str] = &[
    "gradient_256x256.png",
    "flat_white_100x100.png",
    "noise_128x128.png",
    "checkerboard_64x64.png",
];

#[test]
fn encode_matches_golden_files() {
    for img_name in TEST_IMAGES {
        let img_path = corpus_dir().join(img_name);
        if !img_path.exists() {
            panic!("corpus image not found: {}", img_path.display());
        }

        let sgl_name = img_name.replace(".png", ".sgl");
        let expected_path = expected_dir().join(&sgl_name);

        // Load the PNG
        let (header, pixels) = sigil::convert::load_image(&img_path)
            .unwrap_or_else(|e| panic!("failed to load {img_name}: {e}"));

        // Encode to .sgl bytes
        let encoded = sigil::encode(&header, &pixels)
            .unwrap_or_else(|e| panic!("failed to encode {img_name}: {e}"));

        // Compare byte-for-byte against golden file
        if expected_path.exists() {
            let expected = std::fs::read(&expected_path)
                .unwrap_or_else(|e| panic!("failed to read golden {}: {e}", expected_path.display()));
            assert_eq!(
                encoded, expected,
                "CONFORMANCE FAILURE: {img_name} encoded output differs from golden {}.\n\
                 Encoded len: {}, expected len: {}",
                sgl_name,
                encoded.len(),
                expected.len()
            );
        } else {
            panic!(
                "Golden file not found: {}. Run sigil-hs to generate it first.",
                expected_path.display()
            );
        }
    }
}

#[test]
fn decode_golden_files() {
    for img_name in TEST_IMAGES {
        let img_path = corpus_dir().join(img_name);
        if !img_path.exists() {
            panic!("corpus image not found: {}", img_path.display());
        }

        let sgl_name = img_name.replace(".png", ".sgl");
        let expected_path = expected_dir().join(&sgl_name);
        if !expected_path.exists() {
            panic!("golden file not found: {}", expected_path.display());
        }

        // Load original pixels from PNG
        let (original_header, original_pixels) = sigil::convert::load_image(&img_path)
            .unwrap_or_else(|e| panic!("failed to load {img_name}: {e}"));

        // Decode golden .sgl
        let golden_bytes = std::fs::read(&expected_path)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", expected_path.display()));
        let (decoded_header, decoded_pixels) = sigil::decode(&golden_bytes)
            .unwrap_or_else(|e| panic!("failed to decode {sgl_name}: {e}"));

        // Verify header matches
        assert_eq!(
            decoded_header, original_header,
            "Header mismatch for {sgl_name}"
        );

        // Verify pixels match the original PNG
        assert_eq!(
            decoded_pixels, original_pixels,
            "Pixel mismatch for {sgl_name}: decoded golden .sgl differs from source PNG.\n\
             Decoded len: {}, original len: {}",
            decoded_pixels.len(),
            original_pixels.len()
        );
    }
}

#[test]
fn round_trip_through_sgl() {
    for img_name in TEST_IMAGES {
        let img_path = corpus_dir().join(img_name);
        if !img_path.exists() {
            panic!("corpus image not found: {}", img_path.display());
        }

        let (header, original_pixels) = sigil::convert::load_image(&img_path)
            .unwrap_or_else(|e| panic!("failed to load {img_name}: {e}"));

        let encoded = sigil::encode(&header, &original_pixels)
            .unwrap_or_else(|e| panic!("failed to encode {img_name}: {e}"));

        let (decoded_header, decoded_pixels) = sigil::decode(&encoded)
            .unwrap_or_else(|e| panic!("failed to decode {img_name}: {e}"));

        assert_eq!(decoded_header, header, "header mismatch for {img_name}");
        assert_eq!(
            decoded_pixels, original_pixels,
            "round-trip pixel mismatch for {img_name}"
        );
    }
}
```

- [ ] **Step 2: Run the conformance tests**

```bash
cd sigil-rs && cargo test -p sigil --test conformance
```

Expected: all tests pass. If they fail, this indicates a byte-level conformance issue that must be debugged before proceeding.

**Debugging conformance failures:** If `encode_matches_golden_files` fails, the approach is:
1. Hex-dump both files and find the first differing byte
2. Determine which chunk it falls in (SHDR, SDAT, SEND)
3. If SHDR differs, check header encoding (endianness, bit depth raw value)
4. If SDAT differs, add intermediate comparison: predict a single row in both Haskell and Rust, compare residuals; then zigzag; then tokenize; then Rice-encode
5. Common pitfalls: zigzag sign extension, Rice unary off-by-one, adaptive tie-breaking order, BitWriter MSB/LSB confusion

- [ ] **Step 3: Commit**

```bash
git add sigil-rs/sigil/tests/conformance.rs && git commit -m "feat: byte-for-byte conformance tests against sigil-hs golden files"
```

---

### Task 12: CLI -- Encode, Decode, Info, Verify

**Files:**
- Modify: `sigil-rs/sigil-cli/src/main.rs`

- [ ] **Step 1: Implement CLI**

Replace `sigil-rs/sigil-cli/src/main.rs`:

```rust
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process;

#[derive(Parser)]
#[command(name = "sigil", about = "Sigil image codec — Rust production implementation")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Encode a PNG/JPEG/BMP image to .sgl format
    Encode {
        /// Input image path
        input: PathBuf,
        /// Output .sgl path
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Decode a .sgl file to PNG
    Decode {
        /// Input .sgl path
        input: PathBuf,
        /// Output PNG path
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Show .sgl file metadata
    Info {
        /// Input .sgl path
        input: PathBuf,
    },
    /// Verify round-trip integrity of an image
    Verify {
        /// Input image path
        input: PathBuf,
    },
    /// Benchmark compression with per-predictor comparison
    Bench {
        /// Input image path
        input: PathBuf,
        /// Number of iterations
        #[arg(long, default_value = "10")]
        iterations: usize,
    },
}

fn main() {
    let cli = Cli::parse();
    if let Err(e) = run(cli) {
        eprintln!("Error: {e}");
        process::exit(1);
    }
}

fn run(cli: Cli) -> Result<(), sigil::SigilError> {
    match cli.command {
        Command::Encode { input, output } => {
            sigil::encode_file(&input, &output)?;
            println!("Encoded {} -> {}", input.display(), output.display());
        }
        Command::Decode { input, output } => {
            sigil::decode_file(&input, &output)?;
            println!("Decoded {} -> {}", input.display(), output.display());
        }
        Command::Info { input } => {
            let data = std::fs::read(&input)?;
            let header = sigil::read_header(&data)?;
            println!("File: {}", input.display());
            println!("Dimensions: {}x{}", header.width, header.height);
            println!("Color space: {:?}", header.color_space);
            println!("Bit depth: {:?}", header.bit_depth);
            println!("Predictor: {:?}", header.predictor);
            println!(
                "Raw size: {} bytes",
                header.row_bytes() * header.height as usize
            );
        }
        Command::Verify { input } => {
            let (header, original) = sigil::convert::load_image(&input)?;
            let encoded = sigil::encode(&header, &original)?;
            let (_, decoded) = sigil::decode(&encoded)?;
            if decoded == original {
                println!("PASS: {} round-trip verified", input.display());
            } else {
                eprintln!("FAIL: {} round-trip mismatch", input.display());
                process::exit(1);
            }
        }
        Command::Bench { input, iterations } => {
            run_bench(&input, iterations)?;
        }
    }
    Ok(())
}

fn run_bench(input: &std::path::Path, iterations: usize) -> Result<(), sigil::SigilError> {
    let (header, pixels) = sigil::convert::load_image(input)?;
    let raw_size = header.row_bytes() * header.height as usize;

    println!(
        "Image: {} ({}x{}, {:?}, {:?})",
        input.display(),
        header.width,
        header.height,
        header.color_space,
        header.bit_depth
    );
    println!("Raw size: {raw_size} bytes");
    println!();
    println!(
        "{:<14} {:>9} {:>8} {:>12} {:>12}",
        "Predictor", "Encoded", "Ratio", "Encode ms", "Decode ms"
    );
    println!("{}", "-".repeat(60));

    let predictors = [
        (sigil::PredictorId::None, "None"),
        (sigil::PredictorId::Sub, "Sub"),
        (sigil::PredictorId::Up, "Up"),
        (sigil::PredictorId::Average, "Average"),
        (sigil::PredictorId::Paeth, "Paeth"),
        (sigil::PredictorId::Gradient, "Gradient"),
        (sigil::PredictorId::Adaptive, "Adaptive"),
    ];

    for (pid, name) in &predictors {
        let hdr = sigil::Header {
            predictor: *pid,
            ..header.clone()
        };

        // Benchmark encode
        let start = std::time::Instant::now();
        let mut encoded = Vec::new();
        for _ in 0..iterations {
            encoded = sigil::pipeline::compress(&hdr, &pixels);
        }
        let enc_ms = start.elapsed().as_secs_f64() * 1000.0 / iterations as f64;

        let enc_size = encoded.len();

        // Benchmark decode
        let start = std::time::Instant::now();
        for _ in 0..iterations {
            let _ = sigil::pipeline::decompress(&hdr, &encoded);
        }
        let dec_ms = start.elapsed().as_secs_f64() * 1000.0 / iterations as f64;

        let ratio = raw_size as f64 / enc_size as f64;
        println!(
            "{:<14} {:>9} {:>7.2}x {:>10.1} {:>12.1}",
            name, enc_size, ratio, enc_ms, dec_ms
        );
    }

    Ok(())
}
```

- [ ] **Step 2: Build and test the CLI**

```bash
cd sigil-rs && cargo build -p sigil-cli
```

Expected: compiles successfully.

```bash
cd sigil-rs && cargo run -p sigil-cli -- info ../../tests/corpus/expected/gradient_256x256.sgl
```

Expected output:
```
File: ../../tests/corpus/expected/gradient_256x256.sgl
Dimensions: 256x256
Color space: Rgb
Bit depth: Depth8
Predictor: Adaptive
Raw size: 196608 bytes
```

- [ ] **Step 3: Test encode and decode**

```bash
cd sigil-rs && cargo run -p sigil-cli -- encode ../../tests/corpus/gradient_256x256.png -o /tmp/gradient_rs.sgl
```

Expected: `Encoded ... -> /tmp/gradient_rs.sgl`

```bash
cd sigil-rs && cargo run -p sigil-cli -- decode /tmp/gradient_rs.sgl -o /tmp/gradient_rs.png
```

Expected: `Decoded ... -> /tmp/gradient_rs.png`

- [ ] **Step 4: Test verify**

```bash
cd sigil-rs && cargo run -p sigil-cli -- verify ../../tests/corpus/gradient_256x256.png
```

Expected: `PASS: ... round-trip verified`

- [ ] **Step 5: Commit**

```bash
git add sigil-rs/sigil-cli/ && git commit -m "feat: CLI with encode, decode, info, verify, and bench commands"
```

---

### Task 13: Criterion Benchmarks

**Files:**
- Create: `sigil-rs/benches/codec.rs`

- [ ] **Step 1: Write criterion benchmarks**

Create `sigil-rs/benches/codec.rs`:

```rust
use criterion::{criterion_group, criterion_main, Criterion, BenchmarkId};

fn generate_gradient(w: u32, h: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            pixels.push(x as u8);
            pixels.push(y as u8);
            pixels.push(((x + y) % 256) as u8);
        }
    }
    pixels
}

fn generate_flat(w: u32, h: u32) -> Vec<u8> {
    vec![128u8; (w * h * 3) as usize]
}

fn generate_noise(w: u32, h: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            let seed = x * h + y;
            let v = ((seed.wrapping_mul(1103515245).wrapping_add(12345)) % 256) as u8;
            pixels.push(v);
            pixels.push(v);
            pixels.push(v);
        }
    }
    pixels
}

fn make_header(w: u32, h: u32, pid: sigil::PredictorId) -> sigil::Header {
    sigil::Header {
        width: w,
        height: h,
        color_space: sigil::ColorSpace::Rgb,
        bit_depth: sigil::BitDepth::Depth8,
        predictor: pid,
    }
}

fn bench_zigzag(c: &mut Criterion) {
    let mut group = c.benchmark_group("zigzag");
    let values: Vec<i16> = (-255..=255).collect();
    group.bench_function("encode", |b| {
        b.iter(|| {
            for &v in &values {
                std::hint::black_box(sigil::zigzag::zigzag(v));
            }
        })
    });
    let encoded: Vec<u16> = values.iter().map(|&v| sigil::zigzag::zigzag(v)).collect();
    group.bench_function("decode", |b| {
        b.iter(|| {
            for &v in &encoded {
                std::hint::black_box(sigil::zigzag::unzigzag(v));
            }
        })
    });
    group.finish();
}

fn bench_rice(c: &mut Criterion) {
    let mut group = c.benchmark_group("rice/encode");
    for k in [0u8, 2, 4, 6, 8] {
        group.bench_with_input(BenchmarkId::new("k", k), &k, |b, &k| {
            let values: Vec<u16> = (0..64).collect();
            b.iter(|| {
                let mut w = sigil::rice::BitWriter::new();
                for &v in &values {
                    sigil::rice::rice_encode(k, v, &mut w);
                }
                std::hint::black_box(w.flush());
            })
        });
    }
    group.finish();
}

fn bench_tokenize(c: &mut Criterion) {
    let mut group = c.benchmark_group("tokenize");
    let sparse: Vec<u16> = (0..1000).map(|i| if i % 10 == 0 { i as u16 } else { 0 }).collect();
    let dense: Vec<u16> = (0..1000).map(|i| (i % 256) as u16).collect();
    let uniform: Vec<u16> = vec![42; 1000];

    group.bench_function("sparse", |b| {
        b.iter(|| std::hint::black_box(sigil::token::tokenize(&sparse)))
    });
    group.bench_function("dense", |b| {
        b.iter(|| std::hint::black_box(sigil::token::tokenize(&dense)))
    });
    group.bench_function("uniform", |b| {
        b.iter(|| std::hint::black_box(sigil::token::tokenize(&uniform)))
    });
    group.finish();
}

fn bench_pipeline(c: &mut Criterion) {
    let sizes: &[(u32, u32)] = &[(64, 64), (256, 256)];
    let predictors = [
        (sigil::PredictorId::None, "None"),
        (sigil::PredictorId::Sub, "Sub"),
        (sigil::PredictorId::Paeth, "Paeth"),
        (sigil::PredictorId::Adaptive, "Adaptive"),
    ];

    // Per-predictor benchmarks
    {
        let mut group = c.benchmark_group("predict");
        for &(w, h) in sizes {
            let pixels = generate_gradient(w, h);
            for &(pid, name) in &predictors {
                group.bench_with_input(
                    BenchmarkId::new(format!("{name}/{w}x{h}"), ""),
                    &(&pixels, w, h, pid),
                    |b, &(pixels, w, h, pid)| {
                        let hdr = make_header(*w, *h, *pid);
                        b.iter(|| std::hint::black_box(sigil::predict::predict_image(&hdr, pixels)))
                    },
                );
            }
        }
        group.finish();
    }

    // Pipeline encode/decode
    {
        let mut group = c.benchmark_group("pipeline/encode");
        for &(w, h) in sizes {
            let pixels = generate_gradient(w, h);
            let hdr = make_header(w, h, sigil::PredictorId::Adaptive);
            group.bench_with_input(
                BenchmarkId::new(format!("{w}x{h}"), ""),
                &(),
                |b, _| {
                    b.iter(|| std::hint::black_box(sigil::pipeline::compress(&hdr, &pixels)))
                },
            );
        }
        group.finish();
    }
    {
        let mut group = c.benchmark_group("pipeline/decode");
        for &(w, h) in sizes {
            let pixels = generate_gradient(w, h);
            let hdr = make_header(w, h, sigil::PredictorId::Adaptive);
            let compressed = sigil::pipeline::compress(&hdr, &pixels);
            group.bench_with_input(
                BenchmarkId::new(format!("{w}x{h}"), ""),
                &(),
                |b, _| {
                    b.iter(|| std::hint::black_box(sigil::pipeline::decompress(&hdr, &compressed)))
                },
            );
        }
        group.finish();
    }
}

criterion_group!(benches, bench_zigzag, bench_rice, bench_tokenize, bench_pipeline);
criterion_main!(benches);
```

Note: The bench file lives at `sigil-rs/benches/codec.rs` but the `[[bench]]` entry in `sigil/Cargo.toml` expects it under `sigil/benches/`. We need to move it or adjust. Since the design spec shows it at `sigil-rs/benches/`, update `sigil/Cargo.toml` to point there:

Actually, criterion benches must be in the crate that declares them. Move the bench to `sigil-rs/sigil/benches/codec.rs`:

```bash
mkdir -p sigil-rs/sigil/benches
```

Then create `sigil-rs/sigil/benches/codec.rs` with the content above.

- [ ] **Step 2: Run benchmarks**

```bash
cd sigil-rs && cargo bench -p sigil -- --quick
```

Expected: benchmark results for zigzag, rice, tokenize, and pipeline.

- [ ] **Step 3: Commit**

```bash
git add sigil-rs/sigil/benches/ && git commit -m "feat: criterion benchmarks for codec pipeline"
```

---

### Task 14: End-to-End Smoke Test

**Files:**
- No new files -- just running existing commands.

- [ ] **Step 1: Encode all corpus images**

```bash
cd sigil-rs
for f in ../tests/corpus/*.png; do
  name=$(basename "$f" .png)
  cargo run -p sigil-cli -- encode "$f" -o "/tmp/${name}.sgl"
done
```

Expected: success message for each image.

- [ ] **Step 2: Inspect a .sgl file**

```bash
cd sigil-rs && cargo run -p sigil-cli -- info /tmp/gradient_256x256.sgl
```

Expected: prints dimensions (256x256), Rgb, Depth8, Adaptive.

- [ ] **Step 3: Decode back to PNG**

```bash
cd sigil-rs
for f in /tmp/*.sgl; do
  name=$(basename "$f" .sgl)
  cargo run -p sigil-cli -- decode "$f" -o "/tmp/${name}_decoded.png"
done
```

Expected: success message for each.

- [ ] **Step 4: Verify round-trip on all corpus images**

```bash
cd sigil-rs
for f in ../tests/corpus/*.png; do
  cargo run -p sigil-cli -- verify "$f"
done
```

Expected: `PASS` for all images.

- [ ] **Step 5: Run bench on a corpus image**

```bash
cd sigil-rs && cargo run -p sigil-cli --release -- bench ../tests/corpus/gradient_256x256.png --iterations 5
```

Expected: predictor comparison table with ratios and timing.

- [ ] **Step 6: Run full test suite including conformance**

```bash
cd sigil-rs && cargo test -p sigil
```

Expected: all tests pass, including conformance tests.

- [ ] **Step 7: Binary comparison with Haskell output**

```bash
diff /tmp/gradient_256x256.sgl ../tests/corpus/expected/gradient_256x256.sgl && echo "MATCH" || echo "DIFFER"
diff /tmp/flat_white_100x100.sgl ../tests/corpus/expected/flat_white_100x100.sgl && echo "MATCH" || echo "DIFFER"
diff /tmp/noise_128x128.sgl ../tests/corpus/expected/noise_128x128.sgl && echo "MATCH" || echo "DIFFER"
diff /tmp/checkerboard_64x64.sgl ../tests/corpus/expected/checkerboard_64x64.sgl && echo "MATCH" || echo "DIFFER"
```

Expected: `MATCH` for all four.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "chore: verify end-to-end smoke test and byte-for-byte conformance"
```

---

This plan is now complete. The implementation order ensures each module is tested in isolation before being composed, conformance is verified at the end, and every commit represents a working, tested state.

### Critical Files for Implementation
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Pipeline.hs`
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Rice.hs`
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Predict.hs`
- `/Users/dennis/programming projects/imgcompressor/docs/superpowers/specs/2026-03-28-sigil-rs-design.md`
- `/Users/dennis/programming projects/imgcompressor/tests/corpus/expected/gradient_256x256.sgl`