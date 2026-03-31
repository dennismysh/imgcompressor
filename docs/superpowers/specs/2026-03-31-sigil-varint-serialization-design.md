# Sigil v0.6: Smart Coefficient Serialization

**Date:** 2026-03-31
**Status:** Approved
**Scope:** Replace raw i32 coefficient serialization with zigzag + varint + DPCM, keeping zlib as final entropy coder

## Problem

Sigil v0.5 serializes every DWT coefficient as a fixed 4-byte big-endian Int32 before handing the stream to zlib. This wastes bits badly:

- Detail subband coefficients are mostly 0 or near-zero, but each still costs 4 bytes
- The LL (approximation) subband contains correlated pixel-like values that could benefit from delta prediction
- For a 256x256 RGB image, the pre-zlib coefficient stream is 786,432 bytes (4x the raw image size)
- Zlib must compensate for this inefficiency, limiting overall compression

Current results show Sigil v0.5 loses to PNG on high-frequency content (checkerboard: 700B vs PNG's 207B).

## Goal

Beat PNG consistently across image types (gradients, flat, noise, checkerboard, photos, screenshots) by reducing the pre-zlib coefficient stream size.

## Design

### New Serialization Pipeline

**Detail subbands (LH, HL, HH at each level):**

```
Int32 coefficients -> zigzag encode -> varint pack -> bytes
```

**LL subband (approximation):**

```
Int32 coefficients -> DPCM (row-major delta) -> zigzag encode -> varint pack -> bytes
```

All packed bytes are concatenated and then zlib-compressed as before.

### Zigzag Encoding

Maps signed integers to unsigned so that small-magnitude values produce small unsigned values:

```
encode(n) = (n << 1) XOR (n >> 31)

 0 -> 0
-1 -> 1
 1 -> 2
-2 -> 3
 2 -> 4
```

This is critical because varint encoding works on unsigned values. Without zigzag, -1 as a Word32 would be 0xFFFFFFFF (5 bytes in varint).

The existing `Sigil.Codec.ZigZag` module already implements this for the legacy pipeline.

### Variable-Length Integer Encoding (LEB128)

Unsigned LEB128: 7 data bits per byte, MSB is continuation flag (1 = more bytes follow, 0 = final byte).

```
0-127:       1 byte   (values with 7 bits)
128-16383:   2 bytes  (values with 14 bits)
16384+:      3+ bytes (values with 21+ bits)
```

For typical detail subbands where most coefficients are in [-3, 3], zigzag maps these to [0, 6], costing 1 byte each instead of 4. This is a 4x reduction on the bulk of the data.

Maximum encoded size: 5 bytes for a 32-bit value (worst case, still close to the current 4).

### DPCM on LL Subband

The LL subband is a downscaled approximation of the image. Adjacent values are correlated. Row-major delta prediction:

```
dpcm[0]    = ll[0]           (first value sent raw)
dpcm[i]    = ll[i] - ll[i-1] (subsequent values are deltas)
```

This is applied per-row (delta resets at each row start) to avoid cross-row artifacts. The resulting residuals are small and zero-centered, ideal for zigzag + varint.

On decode, the inverse is a simple prefix sum per row.

### SDAT Payload Format (v0.6)

```
Uncompressed header:
  [u8]  num_levels        -- DWT decomposition levels (1-5)
  [u8]  color_transform   -- 0=none, 1=RCT
  [u8]  num_channels      -- number of transformed channels

Zlib-compressed body:
  For each channel:
    [varint] ll_width
    [varint] ll_height
    [varint*] LL subband   -- DPCM'd, zigzag'd, varint-packed, row-major
                              (ll_width * ll_height values, DPCM resets per row)
    For each level (deepest first):
      [varint*] LH subband -- zigzag'd, varint-packed, row-major
      [varint*] HL subband -- zigzag'd, varint-packed, row-major
      [varint*] HH subband -- zigzag'd, varint-packed, row-major
```

Detail subband dimensions are computed from image dimensions + num_levels (same as v0.5), so no explicit size is needed for them. LL dimensions are stored explicitly because the decoder needs them to know how many varint values to read before the detail subbands begin.

### Format Versioning

- SHDR `compression_method` gets a new variant: `DwtLosslessVarint` (value 2). The decoder dispatches on this byte, not the version.
- Version bytes become [0, 6] (major=0, minor=6) as a convention to indicate the format generation
- Existing v0.4 (`PredictDeflate`, value 0) and v0.5 (`DwtLossless`, value 1) decode paths are preserved unchanged

## Module Changes

### Haskell (encoder)

| Module | Change |
|--------|--------|
| `Codec/Serialize.hs` | **New.** `zigzagEncode`, `zigzagDecode`, `encodeVarint`, `decodeVarint`, `dpcmEncode`, `dpcmDecode`, `packSubband`, `packLLSubband`, `unpackSubband`, `unpackLLSubband` |
| `Codec/Pipeline.hs` | Replace `packInt32Vec` calls with `packSubband` / `packLLSubband` in the DWT compress path. Add `decompressDwtVarint` decode path. |
| `Core/Types.hs` | Add `DwtLosslessVarint` to `CompressionMethod` |
| `IO/Writer.hs` | Write format version 0.6, use new compression method byte |
| `IO/Reader.hs` | Add v0.6 read path (parse varint stream) |

### Rust (decoder)

| Module | Change |
|--------|--------|
| `serialize.rs` | **New.** `zigzag_decode`, `decode_varint`, `dpcm_decode`, `unpack_subband`, `unpack_ll_subband` |
| `pipeline.rs` | Add `decompress_dwt_varint` path |
| `types.rs` | Add `DwtLosslessVarint` to `CompressionMethod` enum |
| `reader.rs` | Parse new compression method value |

### WASM

No changes needed -- the WASM bindings call into the Rust decoder which will automatically support v0.6.

## Testing

### Unit Tests (property-based)

- **Zigzag round-trip:** `zigzagDecode(zigzagEncode(n)) == n` for all Int32
- **Varint round-trip:** `decodeVarint(encodeVarint(n)) == n` for all Word32
- **DPCM round-trip:** `dpcmDecode(dpcmEncode(v, w), w) == v` for arbitrary vectors and widths
- **Subband round-trip:** `unpackSubband(packSubband(v)) == v`
- **LL subband round-trip:** `unpackLLSubband(packLLSubband(v, w), w) == v`
- **Varint size property:** values 0-127 encode to exactly 1 byte

### Integration Tests

- **Full pipeline round-trip:** encode v0.6, decode, pixel-exact match
- **Conformance:** generate new golden `.sgl` files for v0.6, verify Rust decoder matches Haskell encoder on all corpus images

### Regression Tests

- Existing v0.4 and v0.5 golden files still decode correctly through both Haskell and Rust decoders

### Benchmarks

- Run CLI `bench` command on all corpus images before and after
- Compare: Sigil v0.5 size, Sigil v0.6 size, PNG size
- Checkerboard must improve (current: 700B Sigil vs 207B PNG)

## Non-Goals

- Replacing zlib with a custom entropy coder (deferred to Approach B)
- Per-subband adaptive Rice parameters (deferred to Approach B)
- Significance maps / zero-tree coding (deferred to Approach B)
- Adaptive pipeline selection / dual-path encoding (deferred to Approach C)
- Lossy compression
