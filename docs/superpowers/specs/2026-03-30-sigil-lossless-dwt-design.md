# Sigil Lossless DWT — Design Spec

**Date**: 2026-03-30
**Scope**: Replace prediction stage with integer 5/3 wavelet transform + reversible color transform
**Version**: Sigil v0.5 (format-breaking change)

---

## 1. Purpose

Replace Sigil's row-by-row prediction stage with a 2D discrete wavelet transform (DWT) using the integer 5/3 lifting scheme. This provides better energy compaction than scanline prediction, especially on photographic content with 2D spatial correlations. Combined with the existing zlib entropy backend, this should significantly improve compression across all image types.

---

## 2. New Pipeline

```
Encode: pixels → RCT (RGB→YCbCr) → 2D DWT (5/3 lifting) → serialize coefficients → zlib compress
Decode: zlib decompress → deserialize coefficients → inverse 2D DWT → inverse RCT → pixels
```

The old prediction stage (predict → zigzag) is removed entirely.

---

## 3. Integer 5/3 Lifting Scheme (Le Gall Wavelet)

Lossless, reversible. Same wavelet used in JPEG 2000's reversible mode.

### 1D Forward Transform

Given input samples `x[0..N-1]` where N is even:

```
Step 1 (predict): d[n] = x[2n+1] - floor((x[2n] + x[2n+2]) / 2)
Step 2 (update):  s[n] = x[2n] + floor((d[n-1] + d[n] + 2) / 4)
```

Where `d` = detail coefficients (high-pass), `s` = approximation coefficients (low-pass).

Boundary handling: mirror extension at edges (d[-1] = d[0], d[N/2] = d[N/2-1], x[N] = x[N-1]).

### 1D Inverse Transform

```
Step 1: x[2n] = s[n] - floor((d[n-1] + d[n] + 2) / 4)
Step 2: x[2n+1] = d[n] + floor((x[2n] + x[2n+2]) / 2)
```

### 2D Separable Transform

Apply 1D transform to all rows (horizontal), then all columns (vertical). This produces 4 subbands per level:

```
+--------+--------+
|   LL   |   LH   |    LL = low-low (approximation)
|        |        |    LH = low-high (horizontal detail)
+--------+--------+    HL = high-low (vertical detail)
|   HL   |   HH   |    HH = high-high (diagonal detail)
|        |        |
+--------+--------+
```

LL is recursively decomposed for multi-level transforms.

### Odd Dimensions

If a dimension is odd, the last sample is treated as an extra approximation coefficient (no corresponding detail coefficient for it). The lifting scheme naturally handles this.

---

## 4. Reversible Color Transform (RCT)

For RGB images, decorrelate color channels before DWT:

```
Forward:
  Yr = floor((R + 2G + B) / 4)
  Cb = B - G
  Cr = R - G

Inverse:
  G = Yr - floor((Cb + Cr) / 4)
  R = Cr + G
  B = Cb + G
```

Integer arithmetic, perfectly reversible. Same as JPEG 2000 RCT.

For grayscale/grayscale-alpha: no color transform (applied per-channel independently). For RGBA: apply RCT to RGB, pass alpha channel through DWT separately.

---

## 5. Decomposition Levels

Adaptive based on image dimensions:

```
levels = min(5, floor(log2(min(width, height))) - 3)
levels = max(1, levels)  -- at least 1 level
```

Examples: 64x64 → 3 levels, 256x256 → 5 levels, 1920x1080 → 5 levels, 16x16 → 1 level.

Stored in the SDAT payload header so the decoder knows how many levels to invert.

---

## 6. Coefficient Serialization

After the DWT, the image is a 2D array of `Int32` coefficients (the lifting scheme can expand the value range beyond Int16 after multiple levels).

Subbands are serialized in this order:
1. LL band of the deepest level (the small approximation image)
2. For each level from deepest to shallowest: LH, HL, HH

Each subband is serialized row-major as big-endian Int32 values (4 bytes each).

The entire serialized coefficient stream is then zlib compressed.

---

## 7. SDAT Payload Format (v0.5)

```
[u8: num_levels]
[u8: color_transform — 0=none, 1=RCT]
[u8: channels_in_transform — number of channels DWT was applied to]
[zlib-compressed coefficient data]
```

The compressed coefficient data, when decompressed, is:

```
For each channel (Yr/Cb/Cr or grayscale or R/G/B/A):
  [subbands serialized in order: LL, then LH/HL/HH per level deepest-first]
  [each coefficient as i32 big-endian, row-major within each subband]
```

---

## 8. File Changes

### New Haskell modules

- `Sigil.Codec.Wavelet` — 1D and 2D integer 5/3 lifting (forward + inverse), multi-level DWT
- `Sigil.Codec.ColorTransform` — RCT forward + inverse

### Modified modules

- `Sigil.Codec.Pipeline` — new compress/decompress using DWT+zlib instead of predict+zigzag+zlib
- `Sigil.IO.Writer` — version 0.5
- `Sigil.IO.Reader` — accept version 0.5

### No longer used by pipeline (kept in codebase)

- `Sigil.Codec.Predict`
- `Sigil.Codec.ZigZag`
- `Sigil.Codec.ANS`
- `Sigil.Codec.Token`
- `Sigil.Codec.Rice`

### Rust decoder

- New: `sigil-rs/src/wavelet.rs` — inverse 2D DWT (5/3 lifting)
- New: `sigil-rs/src/color_transform.rs` — inverse RCT
- Modified: `sigil-rs/src/pipeline.rs` — use wavelet+RCT decode path

### WASM

Rebuild after Rust changes.

---

## 9. Header Changes

The `predictor` field in the Header is repurposed: in v0.5 it's always `PNone` (the DWT replaces prediction). Future versions may use this field for different wavelet types.

A new approach: add a `compression_method` byte to the SHDR payload:
- 0 = legacy (predict+zigzag+zlib, v0.4)
- 1 = DWT lossless (5/3 + zlib, v0.5)
- 2 = DWT lossy (9/7 + quantize + zlib, v0.6 future)

SHDR payload becomes: width(u32) + height(u32) + colorspace(u8) + bitdepth(u8) + compression_method(u8)

The `predictor` field is removed from the Header struct. This is a breaking change.

---

## 10. Testing

### Wavelet module tests
- 1D forward + inverse round-trip for known sequences
- 2D forward + inverse round-trip for known 4x4, 8x8 matrices
- Multi-level round-trip for various image sizes (including odd dimensions)
- Property test: `inverse(forward(data)) == data` for random 2D arrays

### Color transform tests
- RCT forward + inverse round-trip for all RGB values (exhaustive for small range)
- Property test: `inverseRCT(forwardRCT(r,g,b)) == (r,g,b)`

### Pipeline round-trip
- Same QuickCheck property as before: `decompress(compress(img)) == img`

### Conformance
- Regenerate golden .sgl files (v0.5)
- Verify all corpus images round-trip

### Compression comparison
- Sigil v0.5 vs v0.4 vs PNG on all corpus images + real photos
