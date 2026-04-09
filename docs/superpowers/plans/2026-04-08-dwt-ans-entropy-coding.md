# DWT + ANS Entropy Coding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace zlib with sub-band-adaptive tANS entropy coding using magnitude class symbols and Paeth-predicted LL, creating a new `DwtANS` compression method (byte 3).

**Architecture:** Two new Haskell modules (`MagClass.hs`, `SubbandCoder.hs`) compose magnitude-class symbol encoding with the existing ANS entropy coder. Pipeline.hs gets a new `DwtANS` branch that applies Paeth prediction on the LL sub-band before encoding. The Rust decoder mirrors with `mag_class.rs` and `subband_coder.rs`. Golden files bridge encoder/decoder conformance.

**Tech Stack:** Haskell (sigil-hs), Rust (sigil-rs), hspec + QuickCheck, cargo test

**Spec:** `docs/superpowers/specs/2026-04-08-dwt-ans-entropy-coding-design.md`

---

### Task 1: Add `DwtANS` compression method variant

**Files:**
- Modify: `sigil-hs/src/Sigil/Core/Types.hs:51-61`
- Modify: `sigil-rs/src/types.rs:26-42`

- [ ] **Step 1: Add `DwtANS` to Haskell `CompressionMethod`**

In `sigil-hs/src/Sigil/Core/Types.hs`, add the new variant and update the byte mappings:

```haskell
data CompressionMethod
  = Legacy              -- ^ 0: old predict+zigzag (not produced by v0.5+ encoder)
  | DwtLossless         -- ^ 1: integer 5/3 wavelet + raw i32 + zlib (v0.5)
  | DwtLosslessVarint   -- ^ 2: integer 5/3 wavelet + zigzag/varint + zlib (v0.6)
  | DwtANS              -- ^ 3: integer 5/3 wavelet + mag class + ANS (v0.8)
  deriving (Eq, Show, Enum, Bounded)

compressionMethodFromByte :: Word8 -> Maybe CompressionMethod
compressionMethodFromByte 0 = Just Legacy
compressionMethodFromByte 1 = Just DwtLossless
compressionMethodFromByte 2 = Just DwtLosslessVarint
compressionMethodFromByte 3 = Just DwtANS
compressionMethodFromByte _ = Nothing

compressionMethodToByte :: CompressionMethod -> Word8
compressionMethodToByte Legacy             = 0
compressionMethodToByte DwtLossless        = 1
compressionMethodToByte DwtLosslessVarint  = 2
compressionMethodToByte DwtANS             = 3
```

- [ ] **Step 2: Add `DwtANS` to Rust `CompressionMethod`**

In `sigil-rs/src/types.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompressionMethod {
    Legacy,              // 0
    DwtLossless,         // 1
    DwtLosslessVarint,   // 2
    DwtANS,              // 3
}

impl CompressionMethod {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(CompressionMethod::Legacy),
            1 => Some(CompressionMethod::DwtLossless),
            2 => Some(CompressionMethod::DwtLosslessVarint),
            3 => Some(CompressionMethod::DwtANS),
            _ => None,
        }
    }
}
```

- [ ] **Step 3: Verify both build**

Run:
```bash
cd sigil-hs && stack build 2>&1 | tail -5
cd ../sigil-rs && cargo build 2>&1 | tail -5
```

Expected: Both compile. Haskell may warn about non-exhaustive patterns in Pipeline.hs — that's expected and will be fixed in Task 5.

- [ ] **Step 4: Commit**

```bash
git add sigil-hs/src/Sigil/Core/Types.hs sigil-rs/src/types.rs
git commit -m "feat: add DwtANS compression method variant (byte 3)"
```

---

### Task 2: Implement `MagClass.hs` with tests (TDD)

**Files:**
- Create: `sigil-hs/src/Sigil/Codec/MagClass.hs`
- Create: `sigil-hs/test/Test/MagClass.hs`
- Modify: `sigil-hs/package.yaml:27-43` (exposed-modules)
- Modify: `sigil-hs/package.yaml:81-93` (test other-modules)
- Modify: `sigil-hs/test/Spec.hs:1-40`

- [ ] **Step 1: Write the failing tests**

Create `sigil-hs/test/Test/MagClass.hs`:

```haskell
module Test.MagClass (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import Data.Word (Word16)
import qualified Data.Vector as V

import Sigil.Codec.MagClass

spec :: Spec
spec = describe "MagClass" $ do

  describe "encodeCoeff / decodeCoeff" $ do
    it "zero → class 0, no bits" $ do
      let (cls, bits) = encodeCoeff 0
      cls `shouldBe` 0
      bits `shouldBe` []

    it "1 → class 1, sign +, no residual" $ do
      let (cls, bits) = encodeCoeff 1
      cls `shouldBe` 1
      bits `shouldBe` [False]  -- sign bit: 0 = positive

    it "-1 → class 1, sign -, no residual" $ do
      let (cls, bits) = encodeCoeff (-1)
      cls `shouldBe` 1
      bits `shouldBe` [True]  -- sign bit: 1 = negative

    it "5 → class 3, sign +, residual 01" $ do
      let (cls, bits) = encodeCoeff 5
      cls `shouldBe` 3
      -- sign=False, residual = 5 - 4 = 1, as 2 bits MSB-first: [False, True]
      bits `shouldBe` [False, False, True]

    it "-13 → class 4, sign -, residual 101" $ do
      let (cls, bits) = encodeCoeff (-13)
      cls `shouldBe` 4
      -- sign=True, residual = 13 - 8 = 5, as 3 bits MSB-first: [True, False, True]
      bits `shouldBe` [True, True, False, True]

    it "round-trip for known values" $ do
      let vals = [0, 1, -1, 2, -2, 5, -5, 13, -13, 127, -128, 255, -256]
      mapM_ (\v -> do
        let (cls, bits) = encodeCoeff v
            decoded = decodeCoeff cls bits
        decoded `shouldBe` v
        ) vals

    it "QuickCheck: round-trip for arbitrary Int32" $ property $
      \(v :: Int32) ->
        let (cls, bits) = encodeCoeff v
            decoded = decodeCoeff cls bits
        in decoded === v

    it "class 0 produces exactly 0 bits" $ do
      let (_, bits) = encodeCoeff 0
      length bits `shouldBe` 0

    it "class k produces exactly k bits (1 sign + k-1 residual)" $ property $
      forAll (choose (1, 10000 :: Int32)) $ \v ->
        let (cls, bits) = encodeCoeff v
        in length bits === fromIntegral cls

  describe "encodeCoeffs / decodeCoeffs" $ do
    it "empty vector" $ do
      let (classes, bits) = encodeCoeffs V.empty
      classes `shouldBe` []
      bits `shouldBe` []
      decodeCoeffs [] [] `shouldBe` V.empty

    it "round-trip for known vector" $ do
      let v = V.fromList [0, 5, -13, 1, -1, 0]
          (classes, bits) = encodeCoeffs v
          decoded = decodeCoeffs classes bits
      decoded `shouldBe` v

    it "QuickCheck: round-trip for arbitrary vectors" $ property $
      forAll (listOf (choose (-1000, 1000 :: Int32))) $ \xs ->
        let v = V.fromList xs
            (classes, bits) = encodeCoeffs v
            decoded = decodeCoeffs classes bits
        in decoded === v
```

- [ ] **Step 2: Register the test module**

In `sigil-hs/test/Spec.hs`, add:

```haskell
import qualified Test.MagClass
```

And in the `main` body, add:

```haskell
  Test.MagClass.spec
```

In `sigil-hs/package.yaml`, add `Test.MagClass` to the `other-modules` list under tests, and add `Sigil.Codec.MagClass` to the `exposed-modules` list under library.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd sigil-hs && stack test 2>&1 | tail -20`

Expected: Compilation error — `Sigil.Codec.MagClass` module not found.

- [ ] **Step 4: Implement `MagClass.hs`**

Create `sigil-hs/src/Sigil/Codec/MagClass.hs`:

```haskell
module Sigil.Codec.MagClass
  ( encodeCoeff
  , decodeCoeff
  , encodeCoeffs
  , decodeCoeffs
  ) where

import Data.Bits (shiftR, shiftL, (.&.), (.|.), testBit)
import Data.Int (Int32)
import Data.Word (Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

-- | Encode a signed Int32 coefficient into (magnitude class, sign+residual bits).
--
-- v == 0: class 0, no bits
-- v /= 0: class k = floor(log2(|v|)) + 1
--          bits = [sign] ++ [residual as (k-1) MSB-first bits]
--          sign: False = positive, True = negative
--          residual = |v| - 2^(k-1)
encodeCoeff :: Int32 -> (Word16, [Bool])
encodeCoeff 0 = (0, [])
encodeCoeff v =
  let absV = abs (fromIntegral v) :: Word32
      k    = ilog2 absV + 1     -- magnitude class
      sign = v < 0
      residual = absV - (1 `shiftL` (k - 1))
      resBits  = toBitsMSB (k - 1) residual
  in (fromIntegral k, sign : resBits)
  where
    -- | Floor of log2 for positive Word32.
    ilog2 :: Word32 -> Int
    ilog2 1 = 0
    ilog2 n = 1 + ilog2 (n `shiftR` 1)

    -- | Convert a value to MSB-first bits of given width.
    toBitsMSB :: Int -> Word32 -> [Bool]
    toBitsMSB 0 _ = []
    toBitsMSB w n = [testBit n (w - 1 - i) | i <- [0 .. w - 1]]

-- | Decode a coefficient from its magnitude class and sign+residual bits.
decodeCoeff :: Word16 -> [Bool] -> Int32
decodeCoeff 0 _ = 0
decodeCoeff cls bits =
  let k = fromIntegral cls :: Int
      sign = head bits
      resBits = tail bits
      base = 1 `shiftL` (k - 1) :: Word32
      residual = fromBitsMSB resBits
      absV = base + residual
      val = fromIntegral absV :: Int32
  in if sign then -val else val
  where
    fromBitsMSB :: [Bool] -> Word32
    fromBitsMSB = foldl (\acc b -> (acc `shiftL` 1) .|. (if b then 1 else 0)) 0

-- | Batch encode: coefficients → (class stream for ANS, concatenated raw bits).
encodeCoeffs :: Vector Int32 -> ([Word16], [Bool])
encodeCoeffs v =
  let pairs = map encodeCoeff (V.toList v)
      classes = map fst pairs
      bits = concatMap snd pairs
  in (classes, bits)

-- | Batch decode: class stream + raw bits → coefficients.
decodeCoeffs :: [Word16] -> [Bool] -> Vector Int32
decodeCoeffs classes bits = V.fromList (go classes bits)
  where
    go [] _ = []
    go (cls : rest) bs =
      let k = fromIntegral cls :: Int
          (myBits, remaining) = splitAt k bs
          val = decodeCoeff cls myBits
      in val : go rest remaining
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd sigil-hs && stack test 2>&1 | grep -E "(MagClass|examples|failures)"`

Expected: All MagClass tests pass.

- [ ] **Step 6: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/MagClass.hs sigil-hs/test/Test/MagClass.hs sigil-hs/package.yaml sigil-hs/test/Spec.hs
git commit -m "feat: add MagClass module with magnitude class coding"
```

---

### Task 3: Implement `SubbandCoder.hs` with tests (TDD)

**Files:**
- Create: `sigil-hs/src/Sigil/Codec/SubbandCoder.hs`
- Create: `sigil-hs/test/Test/SubbandCoder.hs`
- Modify: `sigil-hs/package.yaml:27-43` (exposed-modules)
- Modify: `sigil-hs/package.yaml:81-93` (test other-modules)
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write the failing tests**

Create `sigil-hs/test/Test/SubbandCoder.hs`:

```haskell
module Test.SubbandCoder (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import qualified Data.Vector as V

import Sigil.Codec.SubbandCoder

spec :: Spec
spec = describe "SubbandCoder" $ do

  describe "encodeSubband / decodeSubband" $ do
    it "empty vector round-trips" $ do
      let v = V.empty :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 0 encoded
      decoded `shouldBe` v

    it "single zero round-trips" $ do
      let v = V.singleton 0 :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "single positive round-trips" $ do
      let v = V.singleton 42 :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "single negative round-trips" $ do
      let v = V.singleton (-17) :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "known sequence round-trips" $ do
      let v = V.fromList [0, 5, -13, 1, -1, 0, 127, -128] :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband (V.length v) encoded
      decoded `shouldBe` v

    it "all zeros (sparse detail band)" $ do
      let v = V.replicate 100 0 :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 100 encoded
      decoded `shouldBe` v

    it "QuickCheck: round-trip for arbitrary vectors" $ property $
      forAll (listOf (choose (-1000, 1000 :: Int32))) $ \xs ->
        let v = V.fromList xs
            n = V.length v
            encoded = encodeSubband v
            decoded = decodeSubband n encoded
        in decoded === v

    it "QuickCheck: round-trip for large sparse vectors (90% zeros)" $ property $
      forAll (vectorOf 500 (frequency [(9, pure 0), (1, choose (-100, 100 :: Int32))])) $ \xs ->
        let v = V.fromList xs
            n = V.length v
            encoded = encodeSubband v
            decoded = decodeSubband n encoded
        in decoded === v
```

- [ ] **Step 2: Register the test module**

In `sigil-hs/test/Spec.hs`, add:

```haskell
import qualified Test.SubbandCoder
```

And in the `main` body, add:

```haskell
  Test.SubbandCoder.spec
```

In `sigil-hs/package.yaml`, add `Test.SubbandCoder` to `other-modules` under tests and `Sigil.Codec.SubbandCoder` to `exposed-modules` under library.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd sigil-hs && stack test 2>&1 | tail -20`

Expected: Compilation error — `Sigil.Codec.SubbandCoder` module not found.

- [ ] **Step 4: Implement `SubbandCoder.hs`**

Create `sigil-hs/src/Sigil/Codec/SubbandCoder.hs`:

```haskell
module Sigil.Codec.SubbandCoder
  ( encodeSubband
  , decodeSubband
  ) where

import Data.Bits (shiftL, shiftR, (.|.), (.&.))
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.Int (Int32)
import Data.Word (Word8, Word16, Word32)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Codec.MagClass (encodeCoeffs, decodeCoeffs)
import Sigil.Codec.ANS (ansEncode, ansDecode)
import Sigil.Codec.Serialize (encodeVarint, decodeVarint)

-- | Encode one sub-band's coefficients into a self-contained ByteString.
--
-- Format: [varint: rawBitCount] ++ [ANS blob] ++ [packed raw bits]
--
-- The ANS blob is self-delimiting (contains its own length info).
-- rawBitCount tells the decoder how many sign+residual bits to unpack
-- from the trailing bytes.
encodeSubband :: Vector Int32 -> ByteString
encodeSubband v
  | V.null v =
    -- Empty sub-band: rawBitCount=0, empty ANS, no raw bits
    encodeVarint 0 <> ansEncode []
  | otherwise =
    let (classes, rawBits) = encodeCoeffs v
        ansBlob = ansEncode classes
        rawBitCount = length rawBits
        packedRaw = packBits rawBits
    in encodeVarint (fromIntegral rawBitCount) <> ansBlob <> packedRaw

-- | Decode one sub-band's coefficients from a ByteString.
-- The Int parameter is the expected coefficient count (for validation).
decodeSubband :: Int -> ByteString -> Vector Int32
decodeSubband 0 _ = V.empty
decodeSubband n bs =
  let -- Read rawBitCount
      (rawBitCount32, rest0) = decodeVarint bs
      rawBitCount = fromIntegral rawBitCount32 :: Int
      -- ANS decode: the blob is self-delimiting, we decode n class symbols
      classes = ansDecode rest0 n
      -- Compute ANS blob size to find where raw bits start
      ansBlobSize = computeANSBlobSize rest0
      rawBytes = BS.drop ansBlobSize rest0
      -- Unpack raw bits
      rawBits = unpackBits rawBitCount rawBytes
      -- Reconstruct coefficients
  in decodeCoeffs classes rawBits

-- | Compute the byte size of an ANS-encoded blob by parsing its header.
-- Format: [u32 total_samples] [u16 num_unique] [num_unique * 6 bytes] [u32 state] [u32 bitCount] [ceil(bitCount/8) bytes]
computeANSBlobSize :: ByteString -> Int
computeANSBlobSize bs =
  let numUnique = fromIntegral (getU16BE bs 4) :: Int
      freqEnd = 6 + numUnique * 6
      bitCount = fromIntegral (getU32BE bs (freqEnd + 4)) :: Int
      bitstreamBytes = (bitCount + 7) `div` 8
  in freqEnd + 8 + bitstreamBytes

-- ── Bit packing (same logic as ANS.hs, local copy to avoid coupling) ──

packBits :: [Bool] -> ByteString
packBits bits = BS.pack (go bits)
  where
    go [] = []
    go bts =
      let (chunk, rest) = splitAt 8 bts
          padded = chunk ++ replicate (8 - length chunk) False
          byte = foldl' (\acc b -> (acc `shiftL` 1) .|. (if b then 1 else 0)) (0 :: Word8) padded
      in byte : go rest

unpackBits :: Int -> ByteString -> [Bool]
unpackBits n bts = take n $ concatMap byteToBits (BS.unpack bts)
  where
    byteToBits w = [ w .&. (1 `shiftL` (7 - i)) /= 0 | i <- [0..7] ]

-- ── Binary helpers ──

getU32BE :: ByteString -> Int -> Word32
getU32BE bts off =
  (fromIntegral (BS.index bts off) `shiftL` 24)
  .|. (fromIntegral (BS.index bts (off + 1)) `shiftL` 16)
  .|. (fromIntegral (BS.index bts (off + 2)) `shiftL` 8)
  .|. fromIntegral (BS.index bts (off + 3))

getU16BE :: ByteString -> Int -> Word16
getU16BE bts off =
  (fromIntegral (BS.index bts off) `shiftL` 8)
  .|. fromIntegral (BS.index bts (off + 1))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd sigil-hs && stack test 2>&1 | grep -E "(SubbandCoder|examples|failures)"`

Expected: All SubbandCoder tests pass.

- [ ] **Step 6: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/SubbandCoder.hs sigil-hs/test/Test/SubbandCoder.hs sigil-hs/package.yaml sigil-hs/test/Spec.hs
git commit -m "feat: add SubbandCoder module composing MagClass + ANS"
```

---

### Task 4: Wire `DwtANS` into Pipeline.hs encoder

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs:1-65` (imports, compress function)

- [ ] **Step 1: Add imports to Pipeline.hs**

Add these imports at the top of `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

```haskell
import Sigil.Codec.SubbandCoder (encodeSubband, decodeSubband)
import Sigil.Codec.Predict (paeth)
```

- [ ] **Step 2: Add LL prediction helpers**

Add these functions to Pipeline.hs (after the existing `clampWord8` function, around line 238):

```haskell
------------------------------------------------------------------------
-- LL Prediction (Paeth for Int32 sub-band)
------------------------------------------------------------------------

-- | Apply Paeth prediction on an LL sub-band (Int32 values, row-major).
-- Returns residuals.
predictLL :: Int -> Int -> Vector Int32 -> Vector Int32
predictLL w h v = V.generate (w * h) $ \idx ->
  let x = idx `mod` w
      y = idx `div` w
      cur = v V.! idx
      a = if x > 0 then v V.! (idx - 1) else 0           -- left
      b = if y > 0 then v V.! (idx - w) else 0            -- above
      c = if x > 0 && y > 0 then v V.! (idx - w - 1) else 0 -- above-left
      predicted = paethInt32 a b c
  in cur - predicted

-- | Inverse Paeth prediction on LL residuals → original values.
unpredictLL :: Int -> Int -> Vector Int32 -> Vector Int32
unpredictLL w h residuals = V.create $ do
  mv <- VM.new (w * h)
  let go idx
        | idx >= w * h = pure ()
        | otherwise = do
            let x = idx `mod` w
                y = idx `div` w
            a <- if x > 0 then VM.read mv (idx - 1) else pure 0
            b <- if y > 0 then VM.read mv (idx - w) else pure 0
            c <- if x > 0 && y > 0 then VM.read mv (idx - w - 1) else pure 0
            let predicted = paethInt32 a b c
                val = (residuals V.! idx) + predicted
            VM.write mv idx val
            go (idx + 1)
  go 0
  pure mv

-- | Paeth predictor for Int32 values (same algorithm as PNG Paeth).
paethInt32 :: Int32 -> Int32 -> Int32 -> Int32
paethInt32 a b c =
  let p  = a + b - c
      pa = abs (p - a)
      pb = abs (p - b)
      pc = abs (p - c)
  in if pa <= pb && pa <= pc then a
     else if pb <= pc then b
     else c
```

Also add this import at the top:

```haskell
import qualified Data.Vector.Mutable as VM
import Control.Monad.ST (ST)
import qualified Data.Vector as V  -- (already imported, just ensure V.create is available)
```

Note: `V.create` uses `ST` under the hood. The existing import of `Data.Vector` should suffice since `V.create` is in `Data.Vector`. The `VM` import is needed for the mutable vector operations inside `unpredictLL`.

- [ ] **Step 3: Add `DwtANS` branch to `compress`**

In `sigil-hs/src/Sigil/Codec/Pipeline.hs`, in the `compress` function (around line 56), add a new case after the existing `DwtLosslessVarint` branch:

```haskell
      coeffBytes = case compressionMethod hdr of
        DwtANS -> serializeAllChannelsANS numLevels w h int32Channels
        DwtLosslessVarint -> serializeAllChannelsVarint numLevels w h int32Channels
        _                 -> serializeAllChannels numLevels w h int32Channels
```

And update the final packing. For DwtANS, we don't use zlib — the data is already entropy-coded:

```haskell
      -- For DwtANS: no zlib wrapper, data is already compressed by ANS
      result = case compressionMethod hdr of
        DwtANS ->
          let ctByte = if useRCT then 1 else 0 :: Word8
              numCh  = fromIntegral (length int32Channels) :: Word8
              llPred = 4 :: Word8  -- Paeth
          in BS.pack [fromIntegral numLevels, ctByte, numCh, llPred] <> coeffBytes
        _ ->
          let compressed = BL.toStrict $ Z.compress $ BL.fromStrict coeffBytes
              ctByte = if useRCT then 1 else 0 :: Word8
              numCh  = fromIntegral (length int32Channels) :: Word8
          in BS.pack [fromIntegral numLevels, ctByte, numCh] <> compressed
  in result
```

- [ ] **Step 4: Add the ANS serialization functions**

Add these functions to Pipeline.hs (after the existing `serializeAllChannelsVarint`):

```haskell
------------------------------------------------------------------------
-- DWT + ANS serialization
------------------------------------------------------------------------

-- | Serialize all channels using sub-band-adaptive ANS (v0.8).
serializeAllChannelsANS :: Int -> Int -> Int -> [Vector Int32] -> ByteString
serializeAllChannelsANS numLevels w h chans =
  BS.concat $ map (serializeChannelANS numLevels w h) chans

-- | Apply DWT, Paeth-predict LL, ANS-encode each sub-band.
serializeChannelANS :: Int -> Int -> Int -> Vector Int32 -> ByteString
serializeChannelANS numLevels w h chan =
  let chanU = VU.convert chan :: VU.Vector Int32
      (finalLLU, levelsU) = dwtForwardMultiMut numLevels w h chanU
      finalLL = V.convert finalLLU :: Vector Int32
      levels = map (\(a,b,c') -> (V.convert a, V.convert b, V.convert c')) levelsU
      -- Compute LL dimensions
      levelSizes = computeLevelSizes numLevels w h
      (llW, llH) = case levelSizes of
                     [] -> (w, h)
                     ((lw, lh, _, _) : _) -> (lw, lh)
      -- Paeth-predict the LL sub-band
      llResiduals = predictLL llW llH finalLL
      -- Encode LL with sub-band coder
      llBlob = encodeSubband llResiduals
      -- Encode detail sub-bands
      detailBlobs = concatMap (\(lh, hl, hh) ->
        [ encodeSubband lh
        , encodeSubband hl
        , encodeSubband hh
        ]) levels
      -- Pack with varint size prefixes
      allBlobs = llBlob : detailBlobs
      packed = BS.concat $ map (\blob ->
        encodeVarint (fromIntegral (BS.length blob)) <> blob) allBlobs
  in packed
```

- [ ] **Step 5: Build and run existing tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -20`

Expected: All existing tests still pass. The `DwtANS` encoder path exists but nothing calls it yet (existing tests use `DwtLosslessVarint`).

- [ ] **Step 6: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Pipeline.hs
git commit -m "feat: wire DwtANS encode path into Pipeline.hs"
```

---

### Task 5: Wire `DwtANS` into Pipeline.hs decoder

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs:124-152` (decompress function)

- [ ] **Step 1: Add `DwtANS` branch to `decompress`**

In the `decompress` function, add handling for the 4-byte header and ANS-coded payload. The key difference: no zlib decompression, and the header has an extra `ll_predictor` byte.

Add a new guard before the existing `otherwise` case:

```haskell
decompress hdr bs
  | compressionMethod hdr == Legacy = Left (IoError "Legacy decompression not supported in Pipeline")
  | compressionMethod hdr == DwtANS = decompressDwtANS hdr bs
  | BS.length bs < 3 = Left TruncatedInput
  | otherwise = ... -- existing code
```

- [ ] **Step 2: Implement `decompressDwtANS`**

Add this function to Pipeline.hs:

```haskell
-- | Decompress a DwtANS-encoded SDAT payload.
decompressDwtANS :: Header -> ByteString -> Either SigilError Image
decompressDwtANS hdr bs
  | BS.length bs < 4 = Left TruncatedInput
  | otherwise =
    let w  = fromIntegral (width hdr)  :: Int
        h  = fromIntegral (height hdr) :: Int
        numLevels = fromIntegral (BS.index bs 0) :: Int
        ctByte    = BS.index bs 1
        numCh     = fromIntegral (BS.index bs 2) :: Int
        _llPred   = BS.index bs 3  -- Paeth (4), reserved for future use
        useRCT    = ctByte == 1
        payload   = BS.drop 4 bs
        -- Compute level sizes
        levelSizes = computeLevelSizes numLevels w h
        (llW, llH) = case levelSizes of
                       [] -> (w, h)
                       ((lw, lh, _, _) : _) -> (lw, lh)
        -- Deserialize all channels
        (int32Channels, _) = deserializeAllChannelsANS w h llW llH levelSizes numCh payload
        -- Convert back to Word8 channels
        word8Channels = fromInt32Channels (colorSpace hdr) w h useRCT int32Channels
        ch = channels (colorSpace hdr)
        interleaved = interleaveChannels word8Channels (w * ch)
        rows = V.fromList [ V.slice (y * w * ch) (w * ch) interleaved
                          | y <- [0 .. h - 1] ]
    in Right rows

-- | Deserialize all channels from ANS-encoded payload.
deserializeAllChannelsANS :: Int -> Int -> Int -> Int
                          -> [(Int, Int, Int, Int)] -> Int -> ByteString
                          -> ([Vector Int32], ByteString)
deserializeAllChannelsANS _ _ _ _ _ 0 bs = ([], bs)
deserializeAllChannelsANS w h llW llH levelSizes n bs =
  let (chan, rest) = deserializeChannelANS w h llW llH levelSizes bs
      (chans, rest') = deserializeAllChannelsANS w h llW llH levelSizes (n - 1) rest
  in (chan : chans, rest')

-- | Deserialize one channel: read varint-prefixed blobs, decode sub-bands, inverse DWT.
deserializeChannelANS :: Int -> Int -> Int -> Int -> [(Int, Int, Int, Int)] -> ByteString
                      -> (Vector Int32, ByteString)
deserializeChannelANS w h llW llH levelSizes bs0 =
  let numLevels = length levelSizes
      -- Read LL blob
      (llBlobSize32, bs1) = decodeVarint bs0
      llBlobSize = fromIntegral llBlobSize32 :: Int
      (llBlob, bs2) = (BS.take llBlobSize bs1, BS.drop llBlobSize bs1)
      llCount = llW * llH
      llResiduals = decodeSubband llCount llBlob
      finalLL = unpredictLL llW llH llResiduals
      -- Read detail blobs
      (levels, bsRest) = readDetailBlobsANS levelSizes bs2
      -- Inverse DWT
      finalLLU = VU.convert finalLL :: VU.Vector Int32
      levelsU = map (\(a,b,c') -> (VU.convert a, VU.convert b, VU.convert c')) levels
      reconstructedU = dwtInverseMultiMut numLevels w h finalLLU levelsU
      reconstructed = V.convert reconstructedU :: Vector Int32
  in (reconstructed, bsRest)

-- | Read detail sub-band blobs (LH, HL, HH per level).
readDetailBlobsANS :: [(Int, Int, Int, Int)] -> ByteString
                   -> ([(Vector Int32, Vector Int32, Vector Int32)], ByteString)
readDetailBlobsANS [] bs = ([], bs)
readDetailBlobsANS ((wLow, hLow, wHigh, hHigh) : rest) bs =
  let lhCount = hLow * wHigh
      hlCount = hHigh * wLow
      hhCount = hHigh * wHigh
      -- LH
      (lhSize32, bs1) = decodeVarint bs
      lhSize = fromIntegral lhSize32 :: Int
      (lhBlob, bs2) = (BS.take lhSize bs1, BS.drop lhSize bs1)
      lh = decodeSubband lhCount lhBlob
      -- HL
      (hlSize32, bs3) = decodeVarint bs2
      hlSize = fromIntegral hlSize32 :: Int
      (hlBlob, bs4) = (BS.take hlSize bs3, BS.drop hlSize bs3)
      hl = decodeSubband hlCount hlBlob
      -- HH
      (hhSize32, bs5) = decodeVarint bs4
      hhSize = fromIntegral hhSize32 :: Int
      (hhBlob, bs6) = (BS.take hhSize bs5, BS.drop hhSize bs5)
      hh = decodeSubband hhCount hhBlob
      -- Recurse
      (restLevels, bsFinal) = readDetailBlobsANS rest bs6
  in ((lh, hl, hh) : restLevels, bsFinal)
```

- [ ] **Step 3: Add a Haskell round-trip test for DwtANS**

In `sigil-hs/test/Test/Pipeline.hs`, add a test that exercises the `DwtANS` compress/decompress path. Read the file first to find the right location. The test should follow the existing pattern:

```haskell
    it "DwtANS round-trip for small RGB image" $ property $
      forAll (choose (2, 16 :: Word32)) $ \w ->
        forAll (choose (2, 16 :: Word32)) $ \h ->
          forAll (arbitraryImage w h 3) $ \img ->
            let hdr = Header w h RGB Depth8 DwtANS
                encoded = compress hdr img
                decoded = decompress hdr encoded
            in decoded === Right img
```

- [ ] **Step 4: Run all tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All tests pass, including the new DwtANS round-trip.

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Pipeline.hs sigil-hs/test/Test/Pipeline.hs
git commit -m "feat: wire DwtANS decode path into Pipeline.hs with round-trip test"
```

---

### Task 6: Wire `DwtANS` into `compressWithProgress` and update `Convert.hs`

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs:69-122` (compressWithProgress)
- Modify: `sigil-hs/src/Sigil/IO/Convert.hs:68,114,140,166,177` (hardcoded compression method)

- [ ] **Step 1: Add `DwtANS` branch to `compressWithProgress`**

In the `compressWithProgress` function, update the serialization and final packing sections to handle `DwtANS`. The DWT-per-channel loop stays the same. Update the serialize + compress stages:

```haskell
  report "serialize" 80 Nothing
  let result = case compressionMethod hdr of
        DwtANS ->
          let levelSizes = computeLevelSizes numLevels w h
              (llW, llH) = case levelSizes of
                             [] -> (w, h)
                             ((lw, lh, _, _) : _) -> (lw, lh)
              coeffBytes = BS.concat $ map (\(finalLL, levels) ->
                let llResiduals = predictLL llW llH finalLL
                    llBlob = encodeSubband llResiduals
                    detailBlobs = concatMap (\(lh, hl, hh) ->
                      [encodeSubband lh, encodeSubband hl, encodeSubband hh]) levels
                    allBlobs = llBlob : detailBlobs
                in BS.concat $ map (\blob ->
                     encodeVarint (fromIntegral (BS.length blob)) <> blob) allBlobs
                ) dwtResults
              ctByte = if useRCT then 1 else 0 :: Word8
              numChByte = fromIntegral (length int32Channels) :: Word8
              llPred = 4 :: Word8
          in BS.pack [fromIntegral numLevels, ctByte, numChByte, llPred] <> coeffBytes
        _ ->
          let coeffBytes = case compressionMethod hdr of
                DwtLosslessVarint ->
                  let levelSizes = computeLevelSizes numLevels w h
                      (llW, llH) = case levelSizes of
                                     [] -> (w, h)
                                     ((lw, lh, _, _) : _) -> (lw, lh)
                  in BS.concat $ map (\(finalLL, levels) ->
                       serializeCoeffsVarint llW llH finalLL levels) dwtResults
                _ ->
                  BS.concat $ map (\(finalLL, levels) ->
                    serializeCoeffs finalLL levels) dwtResults
              compressed = BL.toStrict $ Z.compress $ BL.fromStrict coeffBytes
              ctByte = if useRCT then 1 else 0 :: Word8
              numChByte = fromIntegral (length int32Channels) :: Word8
          in BS.pack [fromIntegral numLevels, ctByte, numChByte] <> compressed

  report "compress" 90 Nothing
  -- Force evaluation (for DwtANS the heavy work is in serialize, but keep stage for consistency)

  report "done" 100 Nothing
  pure result
```

- [ ] **Step 2: Update `Convert.hs` to use `DwtANS` as default**

In `sigil-hs/src/Sigil/IO/Convert.hs`, replace all occurrences of `DwtLosslessVarint` with `DwtANS`. There are 5 locations (lines 68, 114, 140, 166, 177):

```haskell
-- Each hardcoded Header construction:
hdr = Header ... DwtANS
```

- [ ] **Step 3: Run all tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All tests pass. The conformance tests will now fail because the golden files were encoded with `DwtLosslessVarint` but `loadImage` now produces headers with `DwtANS`. This is expected — we'll regenerate golden files in Task 8.

Actually, conformance tests use `loadImage` which returns a header with the new `DwtANS` method, then re-encode and compare against golden files encoded with `DwtLosslessVarint`. They will fail. This is expected and addressed in Task 8. For now, verify non-conformance tests pass:

Run: `cd sigil-hs && stack test 2>&1 | grep -E "(FAIL|pass|Pipeline|MagClass|SubbandCoder|ANS)"`

- [ ] **Step 4: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Pipeline.hs sigil-hs/src/Sigil/IO/Convert.hs
git commit -m "feat: use DwtANS as default compression method"
```

---

### Task 7: Implement Rust `mag_class.rs` with tests

**Files:**
- Create: `sigil-rs/src/mag_class.rs`
- Modify: `sigil-rs/src/lib.rs:1-23` (add module)

- [ ] **Step 1: Create `mag_class.rs` with decode + tests**

Create `sigil-rs/src/mag_class.rs`:

```rust
/// Magnitude class decoding for DWT coefficients.
///
/// Each coefficient is encoded as:
/// - class 0: value = 0, no sign/residual bits
/// - class k > 0: k bits = [sign] + [residual as (k-1) MSB-first bits]
///   sign: 0 = positive, 1 = negative
///   value = (2^(k-1) + residual) * sign

/// Decode a single coefficient from its magnitude class and sign+residual bits.
/// Returns (decoded_value, number_of_bits_consumed).
pub fn decode_coeff(class: u16, bits: &[bool]) -> (i32, usize) {
    if class == 0 {
        return (0, 0);
    }
    let k = class as usize;
    let sign = bits[0];
    let base: u32 = 1 << (k - 1);
    let mut residual: u32 = 0;
    for i in 0..(k - 1) {
        residual = (residual << 1) | (bits[1 + i] as u32);
    }
    let abs_val = base + residual;
    let val = abs_val as i32;
    if sign {
        (-val, k)
    } else {
        (val, k)
    }
}

/// Decode a batch of coefficients from class stream + raw bits.
pub fn decode_coeffs(classes: &[u16], bits: &[bool]) -> Vec<i32> {
    let mut result = Vec::with_capacity(classes.len());
    let mut bit_offset = 0;
    for &cls in classes {
        let (val, consumed) = decode_coeff(cls, &bits[bit_offset..]);
        result.push(val);
        bit_offset += consumed;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_coeff(v: i32) -> (u16, Vec<bool>) {
        if v == 0 {
            return (0, vec![]);
        }
        let abs_v = v.unsigned_abs();
        let k = 32 - abs_v.leading_zeros() as usize; // floor(log2(abs_v)) + 1
        let sign = v < 0;
        let base: u32 = 1 << (k - 1);
        let residual = abs_v - base;
        let mut bits = vec![sign];
        for i in (0..(k - 1)).rev() {
            bits.push((residual >> i) & 1 == 1);
        }
        (k as u16, bits)
    }

    #[test]
    fn test_zero() {
        let (val, consumed) = decode_coeff(0, &[]);
        assert_eq!(val, 0);
        assert_eq!(consumed, 0);
    }

    #[test]
    fn test_one() {
        let (cls, bits) = encode_coeff(1);
        let (val, _) = decode_coeff(cls, &bits);
        assert_eq!(val, 1);
    }

    #[test]
    fn test_neg_one() {
        let (cls, bits) = encode_coeff(-1);
        let (val, _) = decode_coeff(cls, &bits);
        assert_eq!(val, -1);
    }

    #[test]
    fn test_five() {
        let (cls, bits) = encode_coeff(5);
        assert_eq!(cls, 3);
        let (val, _) = decode_coeff(cls, &bits);
        assert_eq!(val, 5);
    }

    #[test]
    fn test_neg_thirteen() {
        let (cls, bits) = encode_coeff(-13);
        assert_eq!(cls, 4);
        let (val, _) = decode_coeff(cls, &bits);
        assert_eq!(val, -13);
    }

    #[test]
    fn test_round_trip_batch() {
        let values = vec![0, 5, -13, 1, -1, 0, 127, -128];
        let mut classes = Vec::new();
        let mut all_bits = Vec::new();
        for &v in &values {
            let (cls, bits) = encode_coeff(v);
            classes.push(cls);
            all_bits.extend(bits);
        }
        let decoded = decode_coeffs(&classes, &all_bits);
        assert_eq!(decoded, values);
    }
}
```

- [ ] **Step 2: Register the module in `lib.rs`**

In `sigil-rs/src/lib.rs`, add:

```rust
mod mag_class;
```

- [ ] **Step 3: Run Rust tests**

Run: `cd sigil-rs && cargo test mag_class 2>&1`

Expected: All mag_class tests pass.

- [ ] **Step 4: Commit**

```bash
git add sigil-rs/src/mag_class.rs sigil-rs/src/lib.rs
git commit -m "feat: add Rust mag_class decoder with tests"
```

---

### Task 8: Implement Rust `subband_coder.rs` with tests

**Files:**
- Create: `sigil-rs/src/subband_coder.rs`
- Modify: `sigil-rs/src/lib.rs` (add module)

- [ ] **Step 1: Create `subband_coder.rs`**

Create `sigil-rs/src/subband_coder.rs`:

```rust
use crate::ans::ans_decode;
use crate::mag_class::decode_coeffs;
use crate::serialize::decode_varint;

/// Decode one sub-band from its encoded blob.
///
/// Format: [varint: rawBitCount] [ANS blob] [packed raw bits]
///
/// The ANS blob is self-delimiting (contains total_samples, freq table, state, bitCount).
pub fn decode_subband(data: &[u8], count: usize) -> Vec<i32> {
    if count == 0 {
        return Vec::new();
    }

    let mut offset = 0;

    // Read rawBitCount
    let raw_bit_count = decode_varint(data, &mut offset) as usize;

    // ANS decode: parse the self-delimiting ANS blob starting at offset
    let ans_data = &data[offset..];
    let classes = ans_decode(ans_data, count);

    // Compute ANS blob size to find raw bits
    let ans_blob_size = compute_ans_blob_size(ans_data);
    let raw_bytes = &data[offset + ans_blob_size..];

    // Unpack raw bits
    let raw_bits = unpack_bits(raw_bit_count, raw_bytes);

    // Reconstruct coefficients
    decode_coeffs(&classes, &raw_bits)
}

/// Compute byte size of an ANS blob by parsing its header.
/// Format: [u32 total_samples] [u16 num_unique] [N*6 freq] [u32 state] [u32 bitCount] [bits]
fn compute_ans_blob_size(data: &[u8]) -> usize {
    let num_unique = u16::from_be_bytes([data[4], data[5]]) as usize;
    let freq_end = 6 + num_unique * 6;
    // state is at freq_end (4 bytes), bitCount is at freq_end + 4 (4 bytes)
    let bit_count = u32::from_be_bytes([
        data[freq_end + 4],
        data[freq_end + 5],
        data[freq_end + 6],
        data[freq_end + 7],
    ]) as usize;
    let bitstream_bytes = (bit_count + 7) / 8;
    freq_end + 8 + bitstream_bytes
}

/// Unpack N bits from packed bytes (MSB-first).
fn unpack_bits(n: usize, data: &[u8]) -> Vec<bool> {
    let mut bits = Vec::with_capacity(n);
    for byte in data {
        for i in 0..8 {
            if bits.len() >= n {
                return bits;
            }
            bits.push((byte >> (7 - i)) & 1 == 1);
        }
    }
    bits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unpack_bits() {
        let data = [0b10110010];
        let bits = unpack_bits(8, &data);
        assert_eq!(bits, vec![true, false, true, true, false, false, true, false]);
    }

    #[test]
    fn test_unpack_bits_partial() {
        let data = [0b10110010];
        let bits = unpack_bits(3, &data);
        assert_eq!(bits, vec![true, false, true]);
    }
}
```

Note: The `compute_ans_blob_size` function has a deliberate fix — the state is at `freq_end` (4 bytes), and bitCount is at `freq_end + 4` (4 bytes). Remove the first incorrect `bit_count` line during implementation; the second one is correct.

- [ ] **Step 2: Register the module in `lib.rs`**

In `sigil-rs/src/lib.rs`, add:

```rust
mod subband_coder;
```

- [ ] **Step 3: Run Rust tests**

Run: `cd sigil-rs && cargo test subband_coder 2>&1`

Expected: Tests pass.

- [ ] **Step 4: Commit**

```bash
git add sigil-rs/src/subband_coder.rs sigil-rs/src/lib.rs
git commit -m "feat: add Rust subband_coder decoder"
```

---

### Task 9: Wire `DwtANS` decode into Rust `pipeline.rs`

**Files:**
- Modify: `sigil-rs/src/pipeline.rs:10-16` (match arm)
- Modify: `sigil-rs/src/pipeline.rs` (add new function)

- [ ] **Step 1: Add `DwtANS` match arm in `decompress`**

In `sigil-rs/src/pipeline.rs`, update the `decompress` function match:

```rust
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    match header.compression_method {
        CompressionMethod::Legacy            => decompress_legacy(header, sdat_payload),
        CompressionMethod::DwtLossless       => decompress_dwt(header, sdat_payload),
        CompressionMethod::DwtLosslessVarint => decompress_dwt_varint(header, sdat_payload),
        CompressionMethod::DwtANS            => decompress_dwt_ans(header, sdat_payload),
    }
}
```

- [ ] **Step 2: Implement `decompress_dwt_ans`**

Add to `sigil-rs/src/pipeline.rs`:

```rust
use crate::subband_coder::decode_subband;

// ---------------------------------------------------------------------------
// DWT + ANS path (v0.8)
// ---------------------------------------------------------------------------

fn decompress_dwt_ans(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    if sdat_payload.len() < 4 {
        return Err(SigilError::TruncatedInput);
    }

    let num_levels   = sdat_payload[0] as usize;
    let ct_byte      = sdat_payload[1];
    let num_channels = sdat_payload[2] as usize;
    let _ll_pred     = sdat_payload[3]; // Paeth (4), reserved
    let use_rct      = ct_byte == 1;

    let w = header.width  as usize;
    let h = header.height as usize;

    // Compute level sizes (deepest-first)
    let level_sizes: Vec<(usize, usize, usize, usize)> = {
        let mut raw = Vec::with_capacity(num_levels);
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

    let (ll_w, ll_h) = if level_sizes.is_empty() {
        (w, h)
    } else {
        let (wl, hl, _, _) = level_sizes[0];
        (wl, hl)
    };

    let mut offset = 4usize;
    let mut channels_i32: Vec<Vec<i32>> = Vec::with_capacity(num_channels);

    for _ in 0..num_channels {
        // Read LL blob
        let ll_blob_size = decode_varint(sdat_payload, &mut offset) as usize;
        let ll_blob = &sdat_payload[offset..offset + ll_blob_size];
        offset += ll_blob_size;
        let ll_count = ll_w * ll_h;
        let ll_residuals = decode_subband(ll_blob, ll_count);
        let final_ll = unpred_paeth_ll(&ll_residuals, ll_w, ll_h);

        // Read detail blobs
        let mut levels: Vec<(Vec<i32>, Vec<i32>, Vec<i32>)> = Vec::with_capacity(num_levels);
        for &(w_low, h_low, w_high, h_high) in &level_sizes {
            let lh_count = h_low  * w_high;
            let hl_count = h_high * w_low;
            let hh_count = h_high * w_high;

            let lh_size = decode_varint(sdat_payload, &mut offset) as usize;
            let lh = decode_subband(&sdat_payload[offset..offset + lh_size], lh_count);
            offset += lh_size;

            let hl_size = decode_varint(sdat_payload, &mut offset) as usize;
            let hl = decode_subband(&sdat_payload[offset..offset + hl_size], hl_count);
            offset += hl_size;

            let hh_size = decode_varint(sdat_payload, &mut offset) as usize;
            let hh = decode_subband(&sdat_payload[offset..offset + hh_size], hh_count);
            offset += hh_size;

            levels.push((lh, hl, hh));
        }

        let reconstructed = dwt_inverse_multi(&final_ll, &levels, w, h, num_levels);
        channels_i32.push(reconstructed);
    }

    // Inverse color transform + interleave (same as other paths)
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

/// Inverse Paeth prediction on LL residuals.
fn unpred_paeth_ll(residuals: &[i32], w: usize, h: usize) -> Vec<i32> {
    let mut out = vec![0i32; w * h];
    for idx in 0..(w * h) {
        let x = idx % w;
        let y = idx / w;
        let a = if x > 0 { out[idx - 1] } else { 0 };
        let b = if y > 0 { out[idx - w] } else { 0 };
        let c = if x > 0 && y > 0 { out[idx - w - 1] } else { 0 };
        let predicted = paeth_i32(a, b, c);
        out[idx] = residuals[idx] + predicted;
    }
    out
}

fn paeth_i32(a: i32, b: i32, c: i32) -> i32 {
    let p = a + b - c;
    let pa = (p - a).abs();
    let pb = (p - b).abs();
    let pc = (p - c).abs();
    if pa <= pb && pa <= pc { a }
    else if pb <= pc { b }
    else { c }
}
```

- [ ] **Step 3: Build Rust decoder**

Run: `cd sigil-rs && cargo build 2>&1 | tail -10`

Expected: Compiles successfully.

- [ ] **Step 4: Commit**

```bash
git add sigil-rs/src/pipeline.rs sigil-rs/src/lib.rs
git commit -m "feat: wire DwtANS decode path into Rust pipeline"
```

---

### Task 10: Regenerate golden files and run conformance tests

**Files:**
- Modify: `tests/corpus/expected/*.sgl` (regenerated)
- Modify: `sigil-rs/tests/conformance.rs:77` (update expected compression method)

- [ ] **Step 1: Delete old golden files**

```bash
rm tests/corpus/expected/*.sgl
```

- [ ] **Step 2: Regenerate golden files via Haskell conformance tests**

Run: `cd sigil-hs && stack test 2>&1 | grep -E "(Conformance|golden|pending)"`

Expected: Each conformance test should say "golden file created" (pending). The test runner creates the new `.sgl` files when they don't exist.

- [ ] **Step 3: Run Haskell conformance tests again to verify determinism**

Run: `cd sigil-hs && stack test 2>&1 | grep -E "(Conformance|FAIL|pass)"`

Expected: All conformance tests pass (golden files now match).

- [ ] **Step 4: Update Rust conformance test for compression method**

In `sigil-rs/tests/conformance.rs`, update the `read_header_only` test (line 77):

```rust
    assert_eq!(header.compression_method, sigil_decode::CompressionMethod::DwtANS);
```

- [ ] **Step 5: Run Rust conformance tests**

Run: `cd sigil-rs && cargo test conformance 2>&1`

Expected: All 5 conformance tests pass (pixel-exact match against source PNGs).

- [ ] **Step 6: Rebuild WASM decoder**

Run: `cd sigil-wasm && PATH="$HOME/.cargo/bin:$PATH" wasm-pack build --target bundler 2>&1 | tail -5`

Expected: Build succeeds (WASM inherits DwtANS support from sigil-rs).

- [ ] **Step 7: Commit**

```bash
git add tests/corpus/expected/ sigil-rs/tests/conformance.rs
git commit -m "feat: regenerate golden files with DwtANS, all conformance tests pass"
```

---

### Task 11: Compression ratio comparison

**Files:** None (informational only)

- [ ] **Step 1: Compare file sizes**

Print the size of each golden file and compare with the git history:

```bash
cd "$(git rev-parse --show-toplevel)"
echo "=== Current (DwtANS) ==="
ls -la tests/corpus/expected/*.sgl
echo ""
echo "=== Previous (DwtLosslessVarint) ==="
git show HEAD~1:tests/corpus/expected/gradient_256x256.sgl | wc -c
git show HEAD~1:tests/corpus/expected/flat_white_100x100.sgl | wc -c
git show HEAD~1:tests/corpus/expected/noise_128x128.sgl | wc -c
git show HEAD~1:tests/corpus/expected/checkerboard_64x64.sgl | wc -c
```

Expected: DwtANS files should be similar or smaller than DwtLosslessVarint for most images. Gradient and flat_white (very sparse detail bands) should show the biggest improvements. Noise may be slightly larger due to ANS frequency table overhead.

- [ ] **Step 2: Report results**

Print a comparison table. No code changes needed — this is a validation step.

- [ ] **Step 3: Final full test run**

```bash
cd sigil-hs && stack test
cd ../sigil-rs && cargo test
```

Expected: All tests pass in both Haskell and Rust.
