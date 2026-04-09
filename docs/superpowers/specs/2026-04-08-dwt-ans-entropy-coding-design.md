# DWT + ANS Entropy Coding Design

**Date:** 2026-04-08
**Status:** Approved
**Version:** v0.8 (new compression method `DwtANS`)

## Goal

Replace zlib with sub-band-adaptive tANS entropy coding, giving Sigil full ownership of its compression pipeline. Combined with magnitude class coding and LL prediction, this should improve compression ratios — especially on images with sparse detail coefficients.

## Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| Replace zlib with what? | tANS (existing `ANS.hs`) | Own the full pipeline end-to-end |
| ANS strategy | Sub-band-adaptive | LL, LH, HL, HH have very different distributions; separate frequency tables exploit this |
| Symbol mapping | Magnitude class coding | Small fixed alphabet (~16 symbols), scales to any coefficient range, battle-tested (JPEG, JPEG 2000, H.264) |
| LL sub-band treatment | Paeth prediction before mag class + ANS | LL has strong spatial correlation; prediction turns it into small residuals |
| Architecture | Layered modules, single release | Each module independently testable with QuickCheck; matches existing codebase pattern |

## Architecture

### Pipeline Flow

```
Current (DwtLosslessVarint):
  RCT -> DWT -> varint serialize -> zlib -> SDAT

New (DwtANS):
  RCT -> DWT -> +-- LL:     Paeth predict -> mag class -> ANS --+-> SDAT
                +-- Detail:                   mag class -> ANS --+
```

### New Modules

#### 1. `MagClass.hs` — Magnitude Class Coding

Standalone module. Converts signed Int32 DWT coefficients into a small-alphabet symbol stream (for ANS) plus raw sign+residual bits.

**Encoding formula:**
- `v == 0`: class 0, no sign, no residual bits
- `v != 0`: class k = floor(log2(|v|)) + 1, sign = 1 bit (0=positive, 1=negative), residual = |v| - 2^(k-1) stored as (k-1) bits

**Examples:**
| Value | Class | Sign | Residual bits |
|-------|-------|------|---------------|
| 0     | 0     | —    | —             |
| 1     | 1     | +    | (0 bits)      |
| -1    | 1     | -    | (0 bits)      |
| 5     | 3     | +    | 01 (2 bits)   |
| -13   | 4     | -    | 101 (3 bits)  |

**API:**
```haskell
-- Single coefficient encode/decode
encodeCoeff :: Int32 -> (Word16, [Bool])
decodeCoeff :: Word16 -> [Bool] -> Int32

-- Batch encode: coefficients -> (class stream for ANS, raw bits for packing)
encodeCoeffs :: Vector Int32 -> ([Word16], [Bool])

-- Batch decode: class stream + raw bits -> coefficients
decodeCoeffs :: [Word16] -> [Bool] -> Vector Int32
```

**QuickCheck properties:**
- Round-trip: `decodeCoeff (encodeCoeff v) == v` for all Int32
- Class 0 produces no sign/residual bits
- Class k produces exactly k bits (1 sign + k-1 residual)

#### 2. `SubbandCoder.hs` — Per-Sub-band ANS + Magnitude Class

Composes MagClass + ANS into encode/decode for one sub-band. Each sub-band gets its own ANS frequency table — this is where "sub-band adaptive" behavior lives.

**Encode flow:**
```
Vector Int32
  -> encodeCoeffs (MagClass)
  -> ([Word16] classes, [Bool] rawBits)
  -> ansEncode classes -> ByteString ansBlob
  -> packBits rawBits -> ByteString rawBlob
  -> [varint: rawBitCount] ++ ansBlob ++ rawBlob
```

**Decode flow:**
```
ByteString
  -> read varint rawBitCount
  -> ansDecode -> [Word16] classes
  -> unpackBits rawBitCount -> [Bool] rawBits
  -> decodeCoeffs classes rawBits -> Vector Int32
```

The ANS blob is self-delimiting (contains its own bitstream length in its serialization format). The decoder parses the ANS portion, then reads the remaining bytes as raw sign+residual bits.

**API:**
```haskell
encodeSubband :: Vector Int32 -> ByteString
decodeSubband :: Int -> ByteString -> Vector Int32
-- Int = expected coefficient count, for validation
```

**QuickCheck properties:**
- Round-trip: `decodeSubband n (encodeSubband v) == v`
- Empty vector produces valid output
- Single-element vector works

### Pipeline Integration

#### New Compression Method

`DwtANS` (byte = 3) added to `CompressionMethod` in both Haskell (`Types.hs`) and Rust (`types.rs`).

#### SDAT Payload Format (DwtANS)

```
[u8: num_levels]
[u8: color_transform -- 0=none, 1=RCT]
[u8: num_channels]
[u8: ll_predictor -- 4=Paeth]
For each channel:
  [varint: LL encoded byte count]
  [LL encoded blob: ANS(mag_classes) ++ packed(sign+residual bits)]
  For each level (deepest first):
    [varint: LH byte count] [LH blob]
    [varint: HL byte count] [HL blob]
    [varint: HH byte count] [HH blob]
```

Each blob is self-framing: the ANS output contains its frequency table, final state, and bitstream length, followed by raw sign+residual bits. The varint size prefix lets the decoder skip ahead to the next sub-band.

#### LL Prediction

Reuse existing `Predict.hs` Paeth predictor, applied as a 2D filter on the LL sub-band (a small llW x llH grid of Int32 values).

```haskell
predictLL :: Int -> Int -> Vector Int32 -> Vector Int32   -- (width, height, pixels -> residuals)
unpredictLL :: Int -> Int -> Vector Int32 -> Vector Int32  -- inverse
```

Lives in `Pipeline.hs` as a thin adapter — not a separate module.

#### Pipeline.hs Changes

New branches in `compress`/`compressWithProgress`/`decompress` for `DwtANS`:

**Encode:**
1. RCT (same as today)
2. DWT (same as today)
3. LL: Paeth predict -> `encodeSubband`
4. Detail bands (LH, HL, HH per level): `encodeSubband` directly
5. Pack: header bytes + varint-prefixed blobs

**Decode:**
1. Read header bytes (num_levels, color_transform, num_channels, ll_predictor)
2. For each channel: read varint sizes, `decodeSubband` each blob
3. Inverse Paeth on LL
4. Inverse DWT
5. Inverse RCT

**Unchanged:** DWT, RCT, existing `DwtLosslessVarint` path (backward compatible), progress reporting stage callbacks.

### Rust Decoder (sigil-rs)

Mirror the Haskell modules (decode-only):

- `mag_class.rs` — `decode_coeff(class, bits) -> i32`, `decode_coeffs(classes, bits) -> Vec<i32>`
- `subband_coder.rs` — `decode_subband(data, count) -> Vec<i32>` (uses existing `ans.rs` + new mag_class)
- Update `types.rs` — add `DwtANS` variant (byte = 3)
- Update `pipeline.rs` — new branch for `DwtANS`: read varint-prefixed blobs, decode each sub-band, inverse Paeth on LL, inverse DWT, inverse RCT

No Rust encoder needed (decoder-only by design).

### WASM Decoder

`sigil-wasm` wraps `sigil-rs`, so once the Rust decoder supports `DwtANS`, WASM gets it for free. No changes to WASM bindings or web UI.

## Testing Strategy

### Haskell Unit Tests (QuickCheck)

- `MagClass`: round-trip for arbitrary Int32 values
- `SubbandCoder`: round-trip for arbitrary Vector Int32
- Pipeline integration: compress/decompress round-trip with `DwtANS` method

### Golden File Conformance

- Re-encode the 4 existing corpus images (gradient, checkerboard, noise, flat_white) with `DwtANS`
- Generate new `.sgl` golden files in `tests/corpus/expected/`
- Rust conformance tests verify pixel-exact decode against source PNGs
- This is the bridge between Haskell encoder and Rust decoder (same pattern as existing tests)

### Compression Regression

- Compare file sizes: `DwtANS` vs `DwtLosslessVarint` on each corpus image
- Not a hard gate, but expect improvement on most images (especially gradient and flat_white where detail bands are very sparse)

## Files Changed

### New files
- `sigil-hs/src/Sigil/Codec/MagClass.hs`
- `sigil-hs/src/Sigil/Codec/SubbandCoder.hs`
- `sigil-rs/src/mag_class.rs`
- `sigil-rs/src/subband_coder.rs`

### Modified files
- `sigil-hs/src/Sigil/Core/Types.hs` — add `DwtANS` variant
- `sigil-hs/src/Sigil/Codec/Pipeline.hs` — new encode/decode branches, LL prediction
- `sigil-hs/src/Sigil/IO/Convert.hs` — use `DwtANS` as default compression method
- `sigil-hs/package.yaml` — expose new modules
- `sigil-hs/test/Spec.hs` — new test groups
- `sigil-rs/src/types.rs` — add `DwtANS` variant
- `sigil-rs/src/pipeline.rs` — new decode branch
- `sigil-rs/src/lib.rs` — expose new modules
- `tests/corpus/expected/*.sgl` — regenerated golden files
