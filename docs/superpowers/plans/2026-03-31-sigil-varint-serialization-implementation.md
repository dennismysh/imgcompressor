# Sigil v0.6 Varint Serialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw i32 big-endian coefficient serialization with zigzag + LEB128 varint + DPCM to shrink the pre-zlib stream and beat PNG across all image types.

**Architecture:** New `Codec/Serialize.hs` module handles zigzag (Int32), LEB128 varint, and DPCM transforms. Pipeline.hs swaps `packInt32Vec`/`unpackInt32N` calls for the new serialization functions. Rust decoder gets a matching `serialize.rs` module. Format version bumps to 0.6 with `CompressionMethod::DwtLosslessVarint` (byte value 2).

**Tech Stack:** Haskell (Data.ByteString, Data.Vector, Data.Int, Data.Word, Data.Bits), Rust (no new deps), QuickCheck/proptest for property tests.

---

### Task 1: Haskell Serialize Module — Zigzag + Varint

**Files:**
- Create: `sigil-hs/src/Sigil/Codec/Serialize.hs`
- Create: `sigil-hs/test/Test/Serialize.hs`
- Modify: `sigil-hs/sigil-hs.cabal:14-30` (add module to exposed-modules)
- Modify: `sigil-hs/sigil-hs.cabal:108-118` (add test module)
- Modify: `sigil-hs/test/Spec.hs:16-36` (import and run new tests)

- [ ] **Step 1: Write failing tests for zigzag32 and varint**

Create `sigil-hs/test/Test/Serialize.hs`:

```haskell
module Test.Serialize (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import Data.Word (Word32)
import qualified Data.ByteString as BS

import Sigil.Codec.Serialize (zigzag32, unzigzag32, encodeVarint, decodeVarint)

spec :: Spec
spec = describe "Serialize" $ do
  describe "zigzag32" $ do
    it "maps known values" $ do
      zigzag32 0    `shouldBe` 0
      zigzag32 (-1) `shouldBe` 1
      zigzag32 1    `shouldBe` 2
      zigzag32 (-2) `shouldBe` 3
      zigzag32 2    `shouldBe` 4

    it "round-trips all Int32" $ property $
      \(n :: Int32) -> unzigzag32 (zigzag32 n) === n

  describe "varint" $ do
    it "encodes 0 as single byte 0x00" $
      encodeVarint 0 `shouldBe` BS.pack [0x00]

    it "encodes 127 as single byte 0x7F" $
      encodeVarint 127 `shouldBe` BS.pack [0x7F]

    it "encodes 128 as two bytes" $
      encodeVarint 128 `shouldBe` BS.pack [0x80, 0x01]

    it "encodes 300 as two bytes" $
      encodeVarint 300 `shouldBe` BS.pack [0xAC, 0x02]

    it "round-trips all Word32" $ property $
      \(n :: Word32) ->
        let bs = encodeVarint n
            (val, rest) = decodeVarint bs
        in val === n .&&. rest === BS.empty

    it "values 0-127 encode to exactly 1 byte" $ property $
      forAll (choose (0, 127 :: Word32)) $ \n ->
        BS.length (encodeVarint n) === 1

    it "values 128-16383 encode to exactly 2 bytes" $ property $
      forAll (choose (128, 16383 :: Word32)) $ \n ->
        BS.length (encodeVarint n) === 2
```

- [ ] **Step 2: Register the test module**

Add `Test.Serialize` to `sigil-hs/sigil-hs.cabal` in the test-suite `other-modules` list, after `Test.Conformance`:

```
      Test.Conformance
      Test.Serialize
```

Add the import and call in `sigil-hs/test/Spec.hs`:

```haskell
import qualified Test.Serialize
```

And in the `main` block, after `Test.Conformance.spec`:

```haskell
  Test.Serialize.spec
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd sigil-hs && stack test 2>&1 | head -30`
Expected: Compilation failure — `Sigil.Codec.Serialize` module not found.

- [ ] **Step 4: Implement zigzag32 and varint**

Create `sigil-hs/src/Sigil/Codec/Serialize.hs`:

```haskell
module Sigil.Codec.Serialize
  ( zigzag32
  , unzigzag32
  , encodeVarint
  , decodeVarint
  ) where

import Data.Bits ((.&.), xor, shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Data.Word (Word8, Word32)

-- | Zigzag-encode a signed Int32 to an unsigned Word32.
-- Maps: 0->0, -1->1, 1->2, -2->3, 2->4, ...
zigzag32 :: Int32 -> Word32
zigzag32 n = fromIntegral ((n `shiftL` 1) `xor` (n `shiftR` 31))

-- | Inverse of zigzag32.
unzigzag32 :: Word32 -> Int32
unzigzag32 n = fromIntegral ((n `shiftR` 1) `xor` negate (n .&. 1))

-- | Encode a Word32 as unsigned LEB128.
encodeVarint :: Word32 -> ByteString
encodeVarint = BS.pack . go
  where
    go n
      | n < 0x80  = [fromIntegral n]
      | otherwise = fromIntegral (n .&. 0x7F .|. 0x80) : go (n `shiftR` 7)

-- | Decode one unsigned LEB128 value from a ByteString.
-- Returns (value, remaining bytes).
decodeVarint :: ByteString -> (Word32, ByteString)
decodeVarint = go 0 0
  where
    go acc shift bs
      | BS.null bs = (acc, bs)
      | otherwise  =
          let b = BS.head bs
              rest = BS.tail bs
              val = acc .|. (fromIntegral (b .&. 0x7F) `shiftL` shift)
          in if b .&. 0x80 == 0
               then (val, rest)
               else go val (shift + 7) rest
```

Register the module in `sigil-hs/sigil-hs.cabal` under the library `exposed-modules`, after `Sigil.Codec.Wavelet`:

```
      Sigil.Codec.Serialize
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd sigil-hs && stack test 2>&1 | tail -20`
Expected: All Serialize tests pass.

- [ ] **Step 6: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Serialize.hs sigil-hs/test/Test/Serialize.hs sigil-hs/sigil-hs.cabal sigil-hs/test/Spec.hs
git commit -m "feat(sigil-hs): zigzag32 and LEB128 varint for coefficient serialization"
```

---

### Task 2: Haskell Serialize Module — DPCM + Subband Packing

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Serialize.hs` (add DPCM, packSubband, packLLSubband)
- Modify: `sigil-hs/test/Test/Serialize.hs` (add DPCM and subband packing tests)

- [ ] **Step 1: Write failing tests for DPCM and subband packing**

Append to the `spec` in `sigil-hs/test/Test/Serialize.hs`, adding the needed imports:

Add to the import block:

```haskell
import qualified Data.Vector as V
import Sigil.Codec.Serialize (zigzag32, unzigzag32, encodeVarint, decodeVarint,
                               dpcmEncode, dpcmDecode, packSubband, unpackSubband,
                               packLLSubband, unpackLLSubband)
```

Add these test sections inside `spec`:

```haskell
  describe "dpcm" $ do
    it "encodes a constant row as first value then zeros" $ do
      let input = V.fromList [100, 100, 100, 100]
          result = dpcmEncode 4 input
      result `shouldBe` V.fromList [100, 0, 0, 0]

    it "round-trips with width 1 (single-column)" $ property $
      forAll (choose (1, 50)) $ \len ->
        forAll (V.replicateM len (choose (-1000, 1000 :: Int32))) $ \v ->
          dpcmDecode 1 (dpcmEncode 1 v) === v

    it "round-trips with arbitrary width" $ property $
      forAll (choose (1, 10)) $ \w ->
        let len = w * w  -- square for simplicity
        in forAll (V.replicateM len (choose (-1000, 1000 :: Int32))) $ \v ->
             dpcmDecode w (dpcmEncode w v) === v

    it "resets delta at each row boundary" $ do
      -- 2x2 grid: row0=[10,20], row1=[50,60]
      let input = V.fromList [10, 20, 50, 60]
          result = dpcmEncode 2 input
      -- row0: 10, 20-10=10; row1: 50, 60-50=10
      result `shouldBe` V.fromList [10, 10, 50, 10]

  describe "packSubband" $ do
    it "round-trips detail subband" $ property $
      forAll (choose (1, 100)) $ \len ->
        forAll (V.replicateM len (choose (-5000, 5000 :: Int32))) $ \v ->
          let packed = packSubband v
              (unpacked, rest) = unpackSubband (V.length v) packed
          in unpacked === v .&&. rest === BS.empty

  describe "packLLSubband" $ do
    it "round-trips LL subband with DPCM" $ property $
      forAll (choose (1, 10)) $ \w ->
        forAll (choose (1, 10)) $ \h ->
          forAll (V.replicateM (w * h) (choose (-5000, 5000 :: Int32))) $ \v ->
            let packed = packLLSubband w v
                (unpacked, rest) = unpackLLSubband w (V.length v) packed
            in unpacked === v .&&. rest === BS.empty
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd sigil-hs && stack test 2>&1 | head -30`
Expected: Compilation failure — functions not exported from Serialize.

- [ ] **Step 3: Implement DPCM and subband packing**

Add to the module export list in `sigil-hs/src/Sigil/Codec/Serialize.hs`:

```haskell
module Sigil.Codec.Serialize
  ( zigzag32
  , unzigzag32
  , encodeVarint
  , decodeVarint
  , dpcmEncode
  , dpcmDecode
  , packSubband
  , unpackSubband
  , packLLSubband
  , unpackLLSubband
  ) where
```

Add the `Data.Vector` import:

```haskell
import Data.Vector (Vector)
import qualified Data.Vector as V
```

Add these functions at the end of the file:

```haskell
-- | DPCM encode: per-row delta prediction.
-- First value of each row is sent raw; subsequent values are (current - previous).
dpcmEncode :: Int -> Vector Int32 -> Vector Int32
dpcmEncode w v = V.generate (V.length v) $ \i ->
  if i `mod` w == 0
    then v V.! i
    else (v V.! i) - (v V.! (i - 1))

-- | Inverse DPCM: prefix-sum per row.
dpcmDecode :: Int -> Vector Int32 -> Vector Int32
dpcmDecode w v = V.generate (V.length v) $ \i ->
  if i `mod` w == 0
    then v V.! i
    else go v w i
  where
    go vec width idx =
      let rowStart = (idx `div` width) * width
      in V.foldl' (+) 0 (V.slice rowStart (idx - rowStart + 1) vec)

-- | Pack a detail subband: zigzag each value, then varint-encode.
packSubband :: Vector Int32 -> ByteString
packSubband v = BS.concat $ map (encodeVarint . zigzag32) (V.toList v)

-- | Unpack a detail subband: read `count` varint values, un-zigzag each.
unpackSubband :: Int -> ByteString -> (Vector Int32, ByteString)
unpackSubband count bs = go count bs []
  where
    go 0 remaining acc = (V.fromList (reverse acc), remaining)
    go n remaining acc =
      let (val, rest) = decodeVarint remaining
      in go (n - 1) rest (unzigzag32 val : acc)

-- | Pack the LL subband: DPCM with given row width, then zigzag + varint.
packLLSubband :: Int -> Vector Int32 -> ByteString
packLLSubband w v = packSubband (dpcmEncode w v)

-- | Unpack the LL subband: read varints, un-zigzag, inverse DPCM.
unpackLLSubband :: Int -> Int -> ByteString -> (Vector Int32, ByteString)
unpackLLSubband w count bs =
  let (dpcmed, rest) = unpackSubband count bs
  in (dpcmDecode w dpcmed, rest)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`
Expected: All Serialize tests pass, including DPCM and subband packing.

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Serialize.hs sigil-hs/test/Test/Serialize.hs
git commit -m "feat(sigil-hs): DPCM and subband packing with zigzag+varint"
```

---

### Task 3: Haskell Types + Writer + Reader — v0.6 Support

**Files:**
- Modify: `sigil-hs/src/Sigil/Core/Types.hs:51-63` (add DwtLosslessVarint)
- Modify: `sigil-hs/src/Sigil/IO/Writer.hs:21-23` (bump version to 0.6)
- Modify: `sigil-hs/src/Sigil/IO/Reader.hs:33` (accept version 0.6)

- [ ] **Step 1: Add DwtLosslessVarint to CompressionMethod**

In `sigil-hs/src/Sigil/Core/Types.hs`, update the enum and conversion functions:

```haskell
data CompressionMethod
  = Legacy              -- ^ 0: old predict+zigzag (not produced by v0.5+ encoder)
  | DwtLossless         -- ^ 1: integer 5/3 wavelet + raw i32 + zlib (v0.5)
  | DwtLosslessVarint   -- ^ 2: integer 5/3 wavelet + zigzag/varint + zlib (v0.6)
  deriving (Eq, Show, Enum, Bounded)

compressionMethodFromByte :: Word8 -> Maybe CompressionMethod
compressionMethodFromByte 0 = Just Legacy
compressionMethodFromByte 1 = Just DwtLossless
compressionMethodFromByte 2 = Just DwtLosslessVarint
compressionMethodFromByte _ = Nothing

compressionMethodToByte :: CompressionMethod -> Word8
compressionMethodToByte Legacy             = 0
compressionMethodToByte DwtLossless        = 1
compressionMethodToByte DwtLosslessVarint  = 2
```

- [ ] **Step 2: Bump version in Writer.hs**

In `sigil-hs/src/Sigil/IO/Writer.hs`, change version:

```haskell
versionMajor, versionMinor :: Word8
versionMajor = 0
versionMinor = 6
```

- [ ] **Step 3: Accept v0.6 in Reader.hs**

In `sigil-hs/src/Sigil/IO/Reader.hs`, update the version check (line 33):

```haskell
          if major /= 0 || (minor /= 4 && minor /= 5 && minor /= 6)
```

- [ ] **Step 4: Run tests to verify nothing is broken**

Run: `cd sigil-hs && stack test 2>&1 | tail -20`
Expected: All existing tests still pass. (Pipeline tests use `DwtLossless` in their headers, which still works.)

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/Core/Types.hs sigil-hs/src/Sigil/IO/Writer.hs sigil-hs/src/Sigil/IO/Reader.hs
git commit -m "feat(sigil-hs): add DwtLosslessVarint compression method, bump to v0.6"
```

---

### Task 4: Haskell Pipeline — Wire Up Varint Serialization

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs:1-289` (add v0.6 compress/decompress paths)
- Modify: `sigil-hs/test/Test/Pipeline.hs:1-50` (update tests to use DwtLosslessVarint)

- [ ] **Step 1: Update Pipeline.hs imports**

Add the Serialize import at the top of `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

```haskell
import Sigil.Codec.Serialize (packSubband, unpackSubband, packLLSubband, unpackLLSubband, encodeVarint, decodeVarint)
```

- [ ] **Step 2: Add varint serialization functions**

Add these functions after `serializeCoeffs` in `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

```haskell
-- | Serialize wavelet coefficients using zigzag + varint packing.
-- LL subband gets DPCM first; detail subbands are packed directly.
-- Per spec: writes [varint ll_width] [varint ll_height] before LL data.
serializeCoeffsVarint :: Int -> Int -> Vector Int32
                      -> [(Vector Int32, Vector Int32, Vector Int32)]
                      -> ByteString
serializeCoeffsVarint llW llH finalLL levels =
  let dimBytes = encodeVarint (fromIntegral llW) <> encodeVarint (fromIntegral llH)
      llBytes = packLLSubband llW finalLL
      levelBytes = concatMap (\(lh, hl, hh) ->
        [packSubband lh, packSubband hl, packSubband hh]) levels
  in BS.concat (dimBytes : llBytes : levelBytes)

-- | Deserialize varint-packed wavelet coefficients.
-- Per spec: reads [varint ll_width] [varint ll_height] before LL data.
deserializeCoeffsVarint :: Int -> Int -> Int -> ByteString
                        -> (Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)], ByteString)
deserializeCoeffsVarint numLevels w h bs =
  let levelSizes = computeLevelSizes numLevels w h
      -- Read explicit LL dimensions from the stream
      (llW32, rest0a) = decodeVarint bs
      (llH32, rest0b) = decodeVarint rest0a
      llW = fromIntegral llW32 :: Int
      llH = fromIntegral llH32 :: Int
      llCount = llW * llH
      (finalLL, rest1) = unpackLLSubband llW llCount rest0b
      (levels, rest2) = readLevelsVarint levelSizes rest1
  in (finalLL, levels, rest2)

-- | Read detail subbands using varint unpacking.
readLevelsVarint :: [(Int, Int, Int, Int)] -> ByteString
                 -> ([(Vector Int32, Vector Int32, Vector Int32)], ByteString)
readLevelsVarint [] bs = ([], bs)
readLevelsVarint ((wLow, hLow, wHigh, hHigh) : rest) bs =
  let lhCount = hLow * wHigh
      hlCount = hHigh * wLow
      hhCount = hHigh * wHigh
      (lh, bs1) = unpackSubband lhCount bs
      (hl, bs2) = unpackSubband hlCount bs1
      (hh, bs3) = unpackSubband hhCount bs2
      (restLevels, bsFinal) = readLevelsVarint rest bs3
  in ((lh, hl, hh) : restLevels, bsFinal)
```

- [ ] **Step 3: Add v0.6 serialize/deserialize channel functions**

Add after `serializeChannel`:

```haskell
-- | Serialize a channel using varint packing (v0.6).
serializeChannelVarint :: Int -> Int -> Int -> Vector Int32 -> ByteString
serializeChannelVarint numLevels w h chan =
  let (finalLL, levels) = dwtForwardMulti numLevels w h chan
      levelSizes = computeLevelSizes numLevels w h
      (llW, llH) = case levelSizes of
                     [] -> (w, h)
                     ((lw, lh, _, _) : _) -> (lw, lh)
  in serializeCoeffsVarint llW llH finalLL levels

-- | Serialize all channels using varint packing (v0.6).
serializeAllChannelsVarint :: Int -> Int -> Int -> [Vector Int32] -> ByteString
serializeAllChannelsVarint numLevels w h chans =
  BS.concat $ map (serializeChannelVarint numLevels w h) chans
```

Add after `deserializeChannel`:

```haskell
-- | Deserialize a single channel from varint-packed bytes, apply inverse DWT.
deserializeChannelVarint :: Int -> Int -> Int -> ByteString -> (Vector Int32, ByteString)
deserializeChannelVarint numLevels w h bs =
  let (finalLL, levels, remaining) = deserializeCoeffsVarint numLevels w h bs
      reconstructed = dwtInverseMulti numLevels w h finalLL levels
  in (reconstructed, remaining)

-- | Deserialize all channels from varint-packed bytes.
deserializeAllChannelsVarint :: Int -> Int -> Int -> Int -> ByteString -> [Vector Int32]
deserializeAllChannelsVarint numLevels w h numCh bs = go numCh bs
  where
    go 0 _ = []
    go n remaining =
      let (chan, rest) = deserializeChannelVarint numLevels w h remaining
      in chan : go (n - 1) rest
```

- [ ] **Step 4: Route compress/decompress based on CompressionMethod**

Replace the `compress` function:

```haskell
compress :: Header -> Image -> ByteString
compress hdr img =
  let w  = fromIntegral (width hdr)  :: Int
      h  = fromIntegral (height hdr) :: Int
      ch = channels (colorSpace hdr)
      flat = V.concat (V.toList img)
      chanVecs = deinterleave flat ch
      (useRCT, int32Channels) = toInt32Channels (colorSpace hdr) w h chanVecs
      numLevels = computeLevels w h
      coeffBytes = case compressionMethod hdr of
        DwtLosslessVarint -> serializeAllChannelsVarint numLevels w h int32Channels
        _                 -> serializeAllChannels numLevels w h int32Channels
      compressed = BL.toStrict $ Z.compress $ BL.fromStrict coeffBytes
      ctByte = if useRCT then 1 else 0 :: Word8
      numCh  = fromIntegral (length int32Channels) :: Word8
  in BS.pack [fromIntegral numLevels, ctByte, numCh] <> compressed
```

Replace the `decompress` function:

```haskell
decompress :: Header -> ByteString -> Either SigilError Image
decompress hdr bs
  | compressionMethod hdr == Legacy = decompressLegacy hdr bs
  | BS.length bs < 3 = Left TruncatedInput
  | otherwise =
    let w  = fromIntegral (width hdr)  :: Int
        h  = fromIntegral (height hdr) :: Int
        numLevels = fromIntegral (BS.index bs 0) :: Int
        ctByte    = BS.index bs 1
        numCh     = fromIntegral (BS.index bs 2) :: Int
        useRCT    = ctByte == 1
        compressedData = BS.drop 3 bs
        decompressed = BL.toStrict $ Z.decompress $ BL.fromStrict compressedData
        int32Channels = case compressionMethod hdr of
          DwtLosslessVarint ->
            deserializeAllChannelsVarint numLevels w h numCh decompressed
          _ ->
            deserializeAllChannels numLevels w h numCh decompressed
        word8Channels = fromInt32Channels (colorSpace hdr) w h useRCT int32Channels
        ch = channels (colorSpace hdr)
        interleaved = interleaveChannels word8Channels (w * ch)
        rows = V.fromList [ V.slice (y * w * ch) (w * ch) interleaved
                          | y <- [0 .. h - 1] ]
    in Right rows
```

Note: You'll need to extract the existing legacy decompress path into a helper `decompressLegacy`. Since the current code doesn't have a legacy path in `decompress` (it only supports DWT), and the Legacy method is handled at the reader level, you can simply add this guard:

```haskell
decompressLegacy :: Header -> ByteString -> Either SigilError Image
decompressLegacy _ _ = Left (IoError "Legacy decompression not supported in Pipeline")
```

- [ ] **Step 5: Update Pipeline tests to use DwtLosslessVarint**

In `sigil-hs/test/Test/Pipeline.hs`, change all four `DwtLossless` references to `DwtLosslessVarint`:

```haskell
          let hdr = Header w h RGB Depth8 DwtLosslessVarint
```

```haskell
          let hdr = Header w h Grayscale Depth8 DwtLosslessVarint
```

```haskell
          let hdr = Header w h RGBA Depth8 DwtLosslessVarint
```

```haskell
          let hdr = Header w h GrayscaleAlpha Depth8 DwtLosslessVarint
```

- [ ] **Step 6: Run tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`
Expected: All Pipeline round-trip tests pass with the new varint path.

- [ ] **Step 7: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Pipeline.hs sigil-hs/test/Test/Pipeline.hs
git commit -m "feat(sigil-hs): wire varint serialization into DWT pipeline (v0.6)"
```

---

### Task 5: Haskell File I/O Round-Trip — Verify v0.6 End-to-End

**Files:**
- Modify: `sigil-hs/test/Spec.hs:53-63` (update File I/O test to use DwtLosslessVarint)

- [ ] **Step 1: Update the File I/O round-trip test**

In `sigil-hs/test/Spec.hs`, change the File I/O test (around line 58) to use `DwtLosslessVarint`:

```haskell
            let hdr = Header w h RGB Depth8 DwtLosslessVarint
```

- [ ] **Step 2: Run full test suite**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`
Expected: All tests pass, including the file I/O round-trip through Writer → Reader with v0.6 format.

- [ ] **Step 3: Commit**

```bash
git add sigil-hs/test/Spec.hs
git commit -m "test(sigil-hs): update file I/O round-trip for v0.6 varint format"
```

---

### Task 6: Rust Serialize Module

**Files:**
- Create: `sigil-rs/src/serialize.rs`
- Modify: `sigil-rs/src/lib.rs:10-21` (add module declaration)

- [ ] **Step 1: Write failing tests for Rust zigzag, varint, DPCM**

Create `sigil-rs/src/serialize.rs` with the test module first:

```rust
/// Zigzag + LEB128 varint + DPCM for coefficient deserialization (v0.6).

/// Decode one unsigned LEB128 varint from `data` starting at `*offset`.
/// Advances `*offset` past the consumed bytes.
pub fn decode_varint(data: &[u8], offset: &mut usize) -> u32 {
    todo!()
}

/// Zigzag-decode: unsigned -> signed.
pub fn zigzag_decode(n: u32) -> i32 {
    todo!()
}

/// Inverse DPCM: prefix-sum per row.
pub fn dpcm_decode(v: &mut [i32], width: usize) {
    todo!()
}

/// Unpack `count` varint-encoded, zigzag-encoded i32 values from `data`.
pub fn unpack_subband(data: &[u8], offset: &mut usize, count: usize) -> Vec<i32> {
    todo!()
}

/// Unpack an LL subband: varint decode, zigzag decode, then inverse DPCM.
pub fn unpack_ll_subband(data: &[u8], offset: &mut usize, count: usize, width: usize) -> Vec<i32> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_zigzag_decode_known_values() {
        assert_eq!(zigzag_decode(0), 0);
        assert_eq!(zigzag_decode(1), -1);
        assert_eq!(zigzag_decode(2), 1);
        assert_eq!(zigzag_decode(3), -2);
        assert_eq!(zigzag_decode(4), 2);
    }

    #[test]
    fn test_decode_varint_single_byte() {
        let data = [0x00];
        let mut offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 0);
        assert_eq!(offset, 1);

        let data = [0x7F];
        offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 127);
        assert_eq!(offset, 1);
    }

    #[test]
    fn test_decode_varint_multi_byte() {
        // 128 = 0x80 0x01
        let data = [0x80, 0x01];
        let mut offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 128);
        assert_eq!(offset, 2);

        // 300 = 0xAC 0x02
        let data = [0xAC, 0x02];
        offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 300);
        assert_eq!(offset, 2);
    }

    #[test]
    fn test_dpcm_decode_constant() {
        // DPCM of [100, 0, 0, 0] with width 4 → [100, 100, 100, 100]
        let mut v = vec![100, 0, 0, 0];
        dpcm_decode(&mut v, 4);
        assert_eq!(v, vec![100, 100, 100, 100]);
    }

    #[test]
    fn test_dpcm_decode_row_reset() {
        // 2x2: [10, 10, 50, 10] → row0: [10, 20], row1: [50, 60]
        let mut v = vec![10, 10, 50, 10];
        dpcm_decode(&mut v, 2);
        assert_eq!(v, vec![10, 20, 50, 60]);
    }

    #[test]
    fn test_unpack_subband() {
        // Zigzag(0)=0 → varint [0x00]; Zigzag(-1)=1 → [0x01]; Zigzag(1)=2 → [0x02]
        let data = [0x00, 0x01, 0x02];
        let mut offset = 0;
        let result = unpack_subband(&data, &mut offset, 3);
        assert_eq!(result, vec![0, -1, 1]);
        assert_eq!(offset, 3);
    }
}
```

- [ ] **Step 2: Register the module**

In `sigil-rs/src/lib.rs`, add after the `color_transform` line:

```rust
mod serialize;
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd sigil-rs && cargo test serialize 2>&1`
Expected: Tests fail with `todo!()` panics.

- [ ] **Step 4: Implement the functions**

Replace the `todo!()` bodies in `sigil-rs/src/serialize.rs`:

```rust
pub fn decode_varint(data: &[u8], offset: &mut usize) -> u32 {
    let mut result: u32 = 0;
    let mut shift: u32 = 0;
    loop {
        let b = data[*offset];
        *offset += 1;
        result |= ((b & 0x7F) as u32) << shift;
        if b & 0x80 == 0 {
            return result;
        }
        shift += 7;
    }
}

pub fn zigzag_decode(n: u32) -> i32 {
    ((n >> 1) as i32) ^ -((n & 1) as i32)
}

pub fn dpcm_decode(v: &mut [i32], width: usize) {
    for i in 0..v.len() {
        if i % width != 0 {
            v[i] += v[i - 1];
        }
    }
}

pub fn unpack_subband(data: &[u8], offset: &mut usize, count: usize) -> Vec<i32> {
    let mut result = Vec::with_capacity(count);
    for _ in 0..count {
        let val = decode_varint(data, offset);
        result.push(zigzag_decode(val));
    }
    result
}

pub fn unpack_ll_subband(data: &[u8], offset: &mut usize, count: usize, width: usize) -> Vec<i32> {
    let mut result = unpack_subband(data, offset, count);
    dpcm_decode(&mut result, width);
    result
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd sigil-rs && cargo test serialize 2>&1`
Expected: All serialize tests pass.

- [ ] **Step 6: Commit**

```bash
git add sigil-rs/src/serialize.rs sigil-rs/src/lib.rs
git commit -m "feat(sigil-rs): zigzag, varint, DPCM deserialization for v0.6"
```

---

### Task 7: Rust Types + Reader — v0.6 Support

**Files:**
- Modify: `sigil-rs/src/types.rs:26-40` (add DwtLosslessVarint)
- Modify: `sigil-rs/src/reader.rs:37-41` (accept version 0.6)

- [ ] **Step 1: Add DwtLosslessVarint to Rust CompressionMethod**

In `sigil-rs/src/types.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompressionMethod {
    Legacy,              // 0
    DwtLossless,         // 1
    DwtLosslessVarint,   // 2
}

impl CompressionMethod {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(CompressionMethod::Legacy),
            1 => Some(CompressionMethod::DwtLossless),
            2 => Some(CompressionMethod::DwtLosslessVarint),
            _ => None,
        }
    }
}
```

- [ ] **Step 2: Accept version 0.6 in reader.rs**

In `sigil-rs/src/reader.rs`, update the version check (line 40):

```rust
    if major != 0 || (minor != 4 && minor != 5 && minor != 6) {
```

- [ ] **Step 3: Run tests**

Run: `cd sigil-rs && cargo test 2>&1`
Expected: All existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add sigil-rs/src/types.rs sigil-rs/src/reader.rs
git commit -m "feat(sigil-rs): add DwtLosslessVarint type, accept v0.6 in reader"
```

---

### Task 8: Rust Pipeline — Wire Up Varint Deserialization

**Files:**
- Modify: `sigil-rs/src/pipeline.rs:1-215` (add decompress_dwt_varint path)

- [ ] **Step 1: Add the varint decompress function**

In `sigil-rs/src/pipeline.rs`, add the import at the top:

```rust
use crate::serialize::{decode_varint, unpack_subband, unpack_ll_subband};
```

Update the `decompress` match to handle the new variant:

```rust
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    match header.compression_method {
        CompressionMethod::Legacy            => decompress_legacy(header, sdat_payload),
        CompressionMethod::DwtLossless       => decompress_dwt(header, sdat_payload),
        CompressionMethod::DwtLosslessVarint => decompress_dwt_varint(header, sdat_payload),
    }
}
```

Add the `decompress_dwt_varint` function. It's structurally identical to `decompress_dwt` but reads coefficients via `unpack_ll_subband`/`unpack_subband` instead of `read_i32_slice`:

```rust
fn decompress_dwt_varint(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    if sdat_payload.len() < 3 {
        return Err(SigilError::TruncatedInput);
    }

    let num_levels    = sdat_payload[0] as usize;
    let ct_byte       = sdat_payload[1];
    let num_channels  = sdat_payload[2] as usize;
    let use_rct       = ct_byte == 1;
    let compressed    = &sdat_payload[3..];

    // Zlib decompress
    let mut decoder = ZlibDecoder::new(compressed);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)
        .map_err(|_| SigilError::TruncatedInput)?;

    let w = header.width  as usize;
    let h = header.height as usize;

    // Compute level sizes (deepest-first)
    let level_sizes: Vec<(usize, usize, usize, usize)> = {
        let mut raw: Vec<(usize, usize, usize, usize)> = Vec::with_capacity(num_levels);
        let mut cw = w;
        let mut ch = h;
        for _ in 0..num_levels {
            let w_low  = (cw + 1) / 2;
            let w_high = cw / 2;
            let h_low  = (ch + 1) / 2;
            let h_high = ch / 2;
            raw.push((w_low, h_low, w_high, h_high));
            cw = w_low;
            ch = h_low;
        }
        raw.reverse();
        raw
    };

    let mut offset = 0usize;
    let mut channels_i32: Vec<Vec<i32>> = Vec::with_capacity(num_channels);

    for _ in 0..num_channels {
        // Read explicit LL dimensions from the stream (per spec)
        let ll_w = decode_varint(&decompressed, &mut offset) as usize;
        let ll_h = decode_varint(&decompressed, &mut offset) as usize;
        let ll_count = ll_w * ll_h;

        // Read LL subband with DPCM
        let final_ll = unpack_ll_subband(&decompressed, &mut offset, ll_count, ll_w);

        // Read detail subbands
        let mut levels: Vec<(Vec<i32>, Vec<i32>, Vec<i32>)> = Vec::with_capacity(num_levels);
        for &(w_low, h_low, w_high, h_high) in &level_sizes {
            let lh_count = h_low  * w_high;
            let hl_count = h_high * w_low;
            let hh_count = h_high * w_high;
            let lh = unpack_subband(&decompressed, &mut offset, lh_count);
            let hl = unpack_subband(&decompressed, &mut offset, hl_count);
            let hh = unpack_subband(&decompressed, &mut offset, hh_count);
            levels.push((lh, hl, hh));
        }

        let reconstructed = dwt_inverse_multi(&final_ll, &levels, w, h, num_levels);
        channels_i32.push(reconstructed);
    }

    // Inverse color transform + interleave (identical to decompress_dwt)
    let pixels = if use_rct {
        match header.color_space {
            ColorSpace::Rgb => {
                inverse_rct(w, h, &channels_i32[0], &channels_i32[1], &channels_i32[2])
            }
            ColorSpace::Rgba => {
                let rgb = inverse_rct(w, h, &channels_i32[0], &channels_i32[1], &channels_i32[2]);
                let n = w * h;
                let mut rgba = Vec::with_capacity(n * 4);
                for i in 0..n {
                    rgba.push(rgb[i * 3]);
                    rgba.push(rgb[i * 3 + 1]);
                    rgba.push(rgb[i * 3 + 2]);
                    rgba.push(channels_i32[3][i].clamp(0, 255) as u8);
                }
                rgba
            }
            _ => interleave_channels(&channels_i32, w, h),
        }
    } else {
        interleave_channels(&channels_i32, w, h)
    };

    Ok(pixels)
}
```

- [ ] **Step 2: Run tests**

Run: `cd sigil-rs && cargo test 2>&1`
Expected: All tests pass (no v0.6 files to decode yet, but existing tests remain green).

- [ ] **Step 3: Commit**

```bash
git add sigil-rs/src/pipeline.rs
git commit -m "feat(sigil-rs): varint deserialization path for v0.6 DWT pipeline"
```

---

### Task 9: Cross-Language Conformance Tests

**Files:**
- Modify: `sigil-hs/test/Test/Conformance.hs` (regenerate golden files)
- Modify: `tests/corpus/expected/` (new v0.6 golden .sgl files)

- [ ] **Step 1: Check the current conformance test structure**

Read `sigil-hs/test/Test/Conformance.hs` to understand how golden files are generated and checked. The test typically encodes each corpus PNG to `.sgl`, then compares against a stored expected file, and also decodes the expected file and compares pixel data.

- [ ] **Step 2: Generate new v0.6 golden files**

Run the Haskell encoder CLI on each corpus image to produce new `.sgl` files:

```bash
cd sigil-hs && stack build 2>&1 | tail -5
stack exec sigil-hs -- encode ../tests/corpus/gradient_256x256.png -o ../tests/corpus/expected/gradient_256x256_v06.sgl
stack exec sigil-hs -- encode ../tests/corpus/checkerboard_64x64.png -o ../tests/corpus/expected/checkerboard_64x64_v06.sgl
stack exec sigil-hs -- encode ../tests/corpus/noise_128x128.png -o ../tests/corpus/expected/noise_128x128_v06.sgl
stack exec sigil-hs -- encode ../tests/corpus/flat_white_100x100.png -o ../tests/corpus/expected/flat_white_100x100_v06.sgl
```

- [ ] **Step 3: Update conformance tests to include v0.6 golden files**

Add test cases for the v0.6 files alongside the existing v0.5 ones. The existing v0.5 golden files should remain and still decode correctly via the legacy path.

- [ ] **Step 4: Verify Rust decoder handles v0.6 golden files**

Run the Rust conformance tests (if they exist) or write a quick test:

```bash
cd sigil-rs && cargo test conformance 2>&1
```

If no conformance test exists in Rust, add one in `sigil-rs/tests/conformance.rs`:

```rust
use std::fs;
use sigil_decode::decode;

#[test]
fn decode_v06_gradient() {
    let data = fs::read("../tests/corpus/expected/gradient_256x256_v06.sgl").unwrap();
    let (header, pixels) = decode(&data).unwrap();
    assert_eq!(header.width, 256);
    assert_eq!(header.height, 256);
    assert_eq!(pixels.len(), 256 * 256 * 3);
}

#[test]
fn decode_v06_checkerboard() {
    let data = fs::read("../tests/corpus/expected/checkerboard_64x64_v06.sgl").unwrap();
    let (header, pixels) = decode(&data).unwrap();
    assert_eq!(header.width, 64);
    assert_eq!(header.height, 64);
    assert_eq!(pixels.len(), 64 * 64 * 3);
}

#[test]
fn decode_v06_noise() {
    let data = fs::read("../tests/corpus/expected/noise_128x128_v06.sgl").unwrap();
    let (header, pixels) = decode(&data).unwrap();
    assert_eq!(header.width, 128);
    assert_eq!(header.height, 128);
}

#[test]
fn decode_v06_flat_white() {
    let data = fs::read("../tests/corpus/expected/flat_white_100x100_v06.sgl").unwrap();
    let (header, pixels) = decode(&data).unwrap();
    assert_eq!(header.width, 100);
    assert_eq!(header.height, 100);
}
```

- [ ] **Step 5: Run both test suites**

```bash
cd sigil-hs && stack test 2>&1 | tail -20
cd ../sigil-rs && cargo test 2>&1 | tail -20
```

Expected: All tests pass in both Haskell and Rust.

- [ ] **Step 6: Commit**

```bash
git add tests/corpus/expected/ sigil-hs/test/Test/Conformance.hs sigil-rs/tests/
git commit -m "test: v0.6 golden files and cross-language conformance tests"
```

---

### Task 10: Benchmark and Verify Compression Gains

**Files:**
- No new files — this is a verification task.

- [ ] **Step 1: Run the Haskell CLI bench command**

```bash
cd sigil-hs && stack exec sigil-hs -- bench ../tests/corpus/ --compare ../tests/corpus/
```

This should print a table with v0.6 sizes, compression ratios, and PNG comparison.

- [ ] **Step 2: Record the results**

Note the v0.6 sizes for each corpus image. Compare against:

| Image | Raw | PNG | Sigil v0.5 |
|-------|-----|-----|------------|
| flat_white | 30,000 B | 286 B | 201 B |
| checkerboard | 12,288 B | 207 B | 700 B |
| gradient | 196,608 B | 186,695 B | 6,967 B |
| noise | 49,152 B | 1,228 B | 842 B |

Key check: **checkerboard must improve** (target: smaller than v0.5's 700B, ideally close to or beating PNG's 207B).

- [ ] **Step 3: Verify all corpus images decode correctly**

```bash
cd sigil-hs
for f in ../tests/corpus/*.png; do
  sgl="${f%.png}.sgl"
  stack exec sigil-hs -- encode "$f" -o "$sgl"
  stack exec sigil-hs -- decode "$sgl" -o "${f%.png}_decoded.png"
  # Compare original and decoded (diff should produce no output for lossless)
done
```

- [ ] **Step 4: Commit benchmark results (if you add them to README)**

If you update the README with new compression numbers:

```bash
git add README.md
git commit -m "docs: update compression results for Sigil v0.6 varint serialization"
```
