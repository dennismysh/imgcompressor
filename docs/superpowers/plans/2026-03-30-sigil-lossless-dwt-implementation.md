# Sigil Lossless DWT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Sigil's prediction-based compression pipeline with a 2D integer 5/3 wavelet transform (DWT) and reversible color transform (RCT). This is Sigil v0.5 -- a format-breaking change that produces significantly better compression through 2D energy compaction.

**Architecture:** Two new Haskell modules (`Sigil.Codec.Wavelet`, `Sigil.Codec.ColorTransform`) implement the core transforms. The pipeline replaces predict+zigzag+zlib with RCT+DWT+serialize+zlib. The Header struct drops the `predictor` field and gains `compression_method`. Two new Rust modules (`wavelet.rs`, `color_transform.rs`) implement the decode path. WASM is rebuilt after Rust changes. All existing tests are adapted; new property-based tests verify round-trip correctness at every level.

**Tech Stack:** Haskell (Stack, lts-22.43, GHC 9.6.6), Rust (stable), wasm-pack

**Spec:** `docs/superpowers/specs/2026-03-30-sigil-lossless-dwt-design.md`

---

## File Structure

```
sigil-hs/
├── src/Sigil/
│   ├── Codec/
│   │   ├── ColorTransform.hs    -- NEW: RCT forward/inverse
│   │   ├── Wavelet.hs           -- NEW: 5/3 lifting, 2D DWT, multi-level
│   │   ├── Pipeline.hs          -- MODIFIED: RCT+DWT+zlib pipeline
│   │   ├── Predict.hs           -- KEPT (unused by pipeline)
│   │   ├── ZigZag.hs            -- KEPT (unused by pipeline)
│   │   ├── Token.hs             -- KEPT (unused by pipeline)
│   │   ├── Rice.hs              -- KEPT (unused by pipeline)
│   │   └── ANS.hs               -- KEPT (unused by pipeline)
│   ├── Core/
│   │   ├── Types.hs             -- MODIFIED: new Header, CompressionMethod
│   │   └── Error.hs             -- MODIFIED: new error variants
│   ├── IO/
│   │   ├── Writer.hs            -- MODIFIED: v0.5, new SHDR format
│   │   ├── Reader.hs            -- MODIFIED: v0.5, new SHDR parsing
│   │   └── Convert.hs           -- MODIFIED: no predictor in Header
│   └── Sigil.hs                 -- MODIFIED: re-export new modules
├── test/
│   ├── Test/
│   │   ├── ColorTransform.hs    -- NEW: RCT tests
│   │   ├── Wavelet.hs           -- NEW: wavelet tests
│   │   ├── Pipeline.hs          -- MODIFIED: test new pipeline
│   │   └── Conformance.hs       -- MODIFIED: v0.5 golden files
│   ├── Gen.hs                   -- MODIFIED: new generators
│   └── Spec.hs                  -- MODIFIED: register new test modules
├── bench/Main.hs                -- MODIFIED: DWT benchmarks
└── package.yaml                 -- MODIFIED: new modules, exposed-modules

sigil-rs/
├── src/
│   ├── wavelet.rs               -- NEW: inverse 5/3 DWT
│   ├── color_transform.rs       -- NEW: inverse RCT
│   ├── pipeline.rs              -- MODIFIED: DWT decode path
│   ├── reader.rs                -- MODIFIED: v0.5 header parsing
│   ├── types.rs                 -- MODIFIED: new Header fields
│   ├── error.rs                 -- MODIFIED: new error variants
│   └── lib.rs                   -- MODIFIED: register new modules
└── tests/conformance.rs         -- MODIFIED: v0.5 golden files

sigil-wasm/                      -- REBUILT after Rust changes

tests/corpus/expected/           -- REGENERATED: v0.5 golden .sgl files
```

---

### Task 1: Reversible Color Transform Module (TDD)

**Files:**
- Create: `sigil-hs/src/Sigil/Codec/ColorTransform.hs`
- Create: `sigil-hs/test/Test/ColorTransform.hs`
- Modify: `sigil-hs/test/Spec.hs`
- Modify: `sigil-hs/package.yaml`

This module converts between RGB pixel data and decorrelated YCbCr-like channels using integer arithmetic. The transform is perfectly reversible. The module operates on `Data.Vector` (boxed) for consistency with the rest of the codebase.

- [ ] **Step 1: Write the test module first**

Create `sigil-hs/test/Test/ColorTransform.hs`:

```haskell
module Test.ColorTransform (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import Data.Word (Word8)
import qualified Data.Vector as V

import Sigil.Codec.ColorTransform

spec :: Spec
spec = describe "ColorTransform" $ do
  describe "RCT single-pixel" $ do
    it "round-trips all black (0,0,0)" $
      let (yr, cb, cr) = rctForwardPixel 0 0 0
          (r, g, b) = rctInversePixel yr cb cr
      in (r, g, b) `shouldBe` (0, 0, 0)

    it "round-trips all white (255,255,255)" $
      let (yr, cb, cr) = rctForwardPixel 255 255 255
          (r, g, b) = rctInversePixel yr cb cr
      in (r, g, b) `shouldBe` (255, 255, 255)

    it "round-trips pure red (255,0,0)" $
      let (yr, cb, cr) = rctForwardPixel 255 0 0
          (r, g, b) = rctInversePixel yr cb cr
      in (r, g, b) `shouldBe` (255, 0, 0)

    it "round-trips pure green (0,255,0)" $
      let (yr, cb, cr) = rctForwardPixel 0 255 0
          (r, g, b) = rctInversePixel yr cb cr
      in (r, g, b) `shouldBe` (0, 255, 0)

    it "round-trips pure blue (0,0,255)" $
      let (yr, cb, cr) = rctForwardPixel 0 0 255
          (r, g, b) = rctInversePixel yr cb cr
      in (r, g, b) `shouldBe` (0, 0, 255)

    it "round-trips arbitrary RGB (property)" $ property $
      \r g b ->
        let (yr, cb, cr) = rctForwardPixel (r :: Word8) (g :: Word8) (b :: Word8)
            (r', g', b') = rctInversePixel yr cb cr
        in (r', g', b') === (r, g, b)

  describe "RCT image" $ do
    it "round-trips a small RGB image" $ property $
      forAll (choose (1, 16 :: Int)) $ \w ->
        forAll (choose (1, 16 :: Int)) $ \h ->
          forAll (V.fromList <$> vectorOf (w * h * 3) (arbitrary :: Gen Word8)) $ \pixels ->
            let (yc, cbc, crc) = forwardRCT w h pixels
                reconstructed = inverseRCT w h (yc, cbc, crc)
            in reconstructed === pixels

  describe "grayscale passthrough" $ do
    it "grayscaleToInt32 and int32ToGrayscale round-trip" $ property $
      forAll (V.fromList <$> listOf (arbitrary :: Gen Word8)) $ \pixels ->
        let i32 = grayscaleToInt32 pixels
            back = int32ToGrayscale i32
        in back === pixels
```

- [ ] **Step 2: Write the implementation module**

Create `sigil-hs/src/Sigil/Codec/ColorTransform.hs`:

```haskell
module Sigil.Codec.ColorTransform
  ( forwardRCT
  , inverseRCT
  , rctForwardPixel
  , rctInversePixel
  , grayscaleToInt32
  , int32ToGrayscale
  ) where

import Data.Int (Int32)
import Data.Word (Word8)
import Data.Vector (Vector)
import qualified Data.Vector as V

-- | Forward RCT for a single pixel.
-- Yr = floor((R + 2G + B) / 4), Cb = B - G, Cr = R - G
rctForwardPixel :: Word8 -> Word8 -> Word8 -> (Int32, Int32, Int32)
rctForwardPixel r g b =
  let r' = fromIntegral r :: Int32
      g' = fromIntegral g :: Int32
      b' = fromIntegral b :: Int32
      yr = (r' + 2 * g' + b') `div` 4
      cb = b' - g'
      cr = r' - g'
  in (yr, cb, cr)

-- | Inverse RCT for a single pixel.
-- G = Yr - floor((Cb + Cr) / 4), R = Cr + G, B = Cb + G
rctInversePixel :: Int32 -> Int32 -> Int32 -> (Word8, Word8, Word8)
rctInversePixel yr cb cr =
  let g = yr - (cb + cr) `div` 4
      r = cr + g
      b = cb + g
  in (fromIntegral r, fromIntegral g, fromIntegral b)

-- | Forward RCT: interleaved RGB pixels -> (Y, Cb, Cr) channel vectors.
-- Input: width, height, Vector of interleaved [R,G,B,R,G,B,...] Word8 values.
-- Output: three separate Int32 channel vectors, each of length (w*h).
forwardRCT :: Int -> Int -> Vector Word8 -> (Vector Int32, Vector Int32, Vector Int32)
forwardRCT w h pixels =
  let n = w * h
      go i =
        let base = i * 3
            r = pixels V.! base
            g = pixels V.! (base + 1)
            b = pixels V.! (base + 2)
        in rctForwardPixel r g b
      results = V.generate n go
      yc  = V.map (\(y, _, _) -> y) results
      cbc = V.map (\(_, c, _) -> c) results
      crc = V.map (\(_, _, c) -> c) results
  in (yc, cbc, crc)

-- | Inverse RCT: (Y, Cb, Cr) channel vectors -> interleaved RGB pixels.
-- Output: Vector of interleaved [R,G,B,R,G,B,...] Word8 values.
inverseRCT :: Int -> Int -> (Vector Int32, Vector Int32, Vector Int32) -> Vector Word8
inverseRCT w h (yc, cbc, crc) =
  let n = w * h
      go i =
        let yr = yc V.! i
            cb = cbc V.! i
            cr = crc V.! i
            (r, g, b) = rctInversePixel yr cb cr
        in [r, g, b]
  in V.fromList $ concatMap go [0..n-1]

-- | Convert grayscale Word8 pixels to Int32 (no color transform needed).
grayscaleToInt32 :: Vector Word8 -> Vector Int32
grayscaleToInt32 = V.map fromIntegral

-- | Convert Int32 channel back to grayscale Word8 pixels.
int32ToGrayscale :: Vector Int32 -> Vector Word8
int32ToGrayscale = V.map fromIntegral
```

- [ ] **Step 3: Register the module in package.yaml**

In `sigil-hs/package.yaml`, add to the `exposed-modules` list under `library`:
```yaml
    - Sigil.Codec.ColorTransform
```

In the `tests` section, add to `other-modules`:
```yaml
      - Test.ColorTransform
```

- [ ] **Step 4: Register in Spec.hs**

In `sigil-hs/test/Spec.hs`, add the import and call:
```haskell
import qualified Test.ColorTransform
-- ... in main:
  Test.ColorTransform.spec
```

- [ ] **Step 5: Build and run tests**

```bash
cd sigil-hs && stack build && stack test 2>&1 | tail -30
```

Expected: All existing tests pass. New ColorTransform tests pass (approximately 7-8 new examples). The property test `round-trips arbitrary RGB` is the most critical -- it verifies lossless round-trip for all 16 million possible RGB values (QuickCheck will sample 100 random triples).

- [ ] **Step 6: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/src/Sigil/Codec/ColorTransform.hs sigil-hs/test/Test/ColorTransform.hs sigil-hs/test/Spec.hs sigil-hs/package.yaml sigil-hs/sigil-hs.cabal
git commit -m "feat(sigil-hs): add Sigil.Codec.ColorTransform — reversible color transform (RCT)"
```

---

### Task 2: Wavelet Module -- 1D Lifting Transform (TDD)

**Files:**
- Create: `sigil-hs/src/Sigil/Codec/Wavelet.hs`
- Create: `sigil-hs/test/Test/Wavelet.hs`
- Modify: `sigil-hs/test/Spec.hs`
- Modify: `sigil-hs/package.yaml`

The 1D integer 5/3 lifting scheme is the foundation for everything else. This must use `div` (Haskell's floor-division) for integer operations. Boundary handling uses mirror extension. Odd-length inputs are handled correctly (the last sample becomes an extra approximation coefficient).

**CRITICAL ALGORITHM NOTES:**
- `div` in Haskell truncates toward negative infinity. For the predict step `floor((left + right) / 2)`, use `(left + right) \`div\` 2`. For the update step `floor((d_left + d_right + 2) / 4)`, use `(dLeft + dRight + 2) \`div\` 4`. These are correct for both positive and negative inputs.
- The number of approximation coefficients is `(n + 1) \`div\` 2` (ceiling of n/2).
- The number of detail coefficients is `n \`div\` 2` (floor of n/2).
- For even-length inputs: nApprox == nDetail. For odd-length: nApprox == nDetail + 1.

- [ ] **Step 1: Write the test module first**

Create `sigil-hs/test/Test/Wavelet.hs`:

```haskell
module Test.Wavelet (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import qualified Data.Vector as V

import Sigil.Codec.Wavelet

spec :: Spec
spec = describe "Wavelet" $ do
  describe "1D forward/inverse" $ do
    it "round-trips a 2-element vector" $
      let input = V.fromList [10, 20 :: Int32]
          (s, d) = lift53Forward1D input
          output = lift53Inverse1D s d
      in output `shouldBe` input

    it "round-trips a 4-element vector" $
      let input = V.fromList [1, 2, 3, 4 :: Int32]
          (s, d) = lift53Forward1D input
          output = lift53Inverse1D s d
      in output `shouldBe` input

    it "round-trips a 3-element vector (odd length)" $
      let input = V.fromList [10, 20, 30 :: Int32]
          (s, d) = lift53Forward1D input
          output = lift53Inverse1D s d
      in output `shouldBe` input

    it "round-trips a 5-element vector (odd length)" $
      let input = V.fromList [100, -50, 200, -100, 50 :: Int32]
          (s, d) = lift53Forward1D input
          output = lift53Inverse1D s d
      in output `shouldBe` input

    it "round-trips a 1-element vector (degenerate)" $
      let input = V.fromList [42 :: Int32]
          (s, d) = lift53Forward1D input
          output = lift53Inverse1D s d
      in output `shouldBe` input

    it "round-trips an 8-element vector" $
      let input = V.fromList [10, 20, 30, 40, 50, 60, 70, 80 :: Int32]
          (s, d) = lift53Forward1D input
          output = lift53Inverse1D s d
      in output `shouldBe` input

    it "round-trips arbitrary vectors (property)" $ property $
      forAll (choose (1, 100)) $ \n ->
        forAll (V.fromList <$> vectorOf n (arbitrary :: Gen Int32)) $ \input ->
          let (s, d) = lift53Forward1D input
              output = lift53Inverse1D s d
          in output === input

    it "produces correct subband sizes for even input" $
      let input = V.fromList [1, 2, 3, 4, 5, 6 :: Int32]
          (s, d) = lift53Forward1D input
      in (V.length s, V.length d) `shouldBe` (3, 3)

    it "produces correct subband sizes for odd input" $
      let input = V.fromList [1, 2, 3, 4, 5 :: Int32]
          (s, d) = lift53Forward1D input
      in (V.length s, V.length d) `shouldBe` (3, 2)

    it "known values: [0, 0, 0, 0] produces all-zero subbands" $
      let input = V.fromList [0, 0, 0, 0 :: Int32]
          (s, d) = lift53Forward1D input
      in do
        V.all (== 0) d `shouldBe` True

    it "known values: constant signal has zero detail" $
      let input = V.fromList [42, 42, 42, 42 :: Int32]
          (_, d) = lift53Forward1D input
      in V.all (== 0) d `shouldBe` True

  describe "decomposition levels" $ do
    it "64x64 -> 3 levels" $ decompositionLevels 64 64 `shouldBe` 3
    it "256x256 -> 5 levels" $ decompositionLevels 256 256 `shouldBe` 5
    it "1920x1080 -> 5 levels" $ decompositionLevels 1920 1080 `shouldBe` 5
    it "16x16 -> 1 level" $ decompositionLevels 16 16 `shouldBe` 1
    it "8x8 -> 1 level (clamped)" $ decompositionLevels 8 8 `shouldBe` 1
    it "4x4 -> 1 level (clamped)" $ decompositionLevels 4 4 `shouldBe` 1
    it "1024x768 -> 5 levels" $ decompositionLevels 1024 768 `shouldBe` 5
    it "32x32 -> 2 levels" $ decompositionLevels 32 32 `shouldBe` 2
```

- [ ] **Step 2: Write the 1D lifting implementation**

Create `sigil-hs/src/Sigil/Codec/Wavelet.hs` with the 1D functions and `decompositionLevels`. The 2D and multi-level functions will be added in Tasks 3 and 4.

```haskell
module Sigil.Codec.Wavelet
  ( lift53Forward1D
  , lift53Inverse1D
  , decompositionLevels
  ) where

import Data.Int (Int32)
import Data.Vector (Vector)
import qualified Data.Vector as V

-- | Compute the number of DWT decomposition levels for a given image size.
-- levels = max(1, min(5, floor(log2(min(w, h))) - 3))
decompositionLevels :: Int -> Int -> Int
decompositionLevels w h =
  let minDim = min w h
      -- floor(log2(x)) for positive x
      floorLog2 :: Int -> Int
      floorLog2 1 = 0
      floorLog2 x = 1 + floorLog2 (x `div` 2)
      raw = floorLog2 minDim - 3
  in max 1 (min 5 raw)

-- | 1D forward 5/3 lifting transform.
-- Input: N samples.
-- Output: (approximation coefficients, detail coefficients).
-- nApprox = ceil(N/2), nDetail = floor(N/2).
lift53Forward1D :: Vector Int32 -> (Vector Int32, Vector Int32)
lift53Forward1D input
  | n <= 1 = (input, V.empty)  -- degenerate: 0 or 1 sample
  | otherwise =
      let nDetail = n `div` 2
          nApprox = (n + 1) `div` 2

          -- Step 1: Predict (compute detail coefficients)
          detail = V.generate nDetail $ \i ->
            let left  = input V.! (2 * i)
                right = if 2 * i + 2 < n
                        then input V.! (2 * i + 2)
                        else input V.! (2 * i)  -- mirror at boundary
            in input V.! (2 * i + 1) - (left + right) `div` 2

          -- Step 2: Update (compute approximation coefficients)
          approx = V.generate nApprox $ \i ->
            let dLeft  = if i > 0 then detail V.! (i - 1) else detail V.! 0
                dRight = if i < nDetail then detail V.! i else detail V.! (nDetail - 1)
            in input V.! (2 * i) + (dLeft + dRight + 2) `div` 4

      in (approx, detail)
  where
    n = V.length input

-- | 1D inverse 5/3 lifting transform.
-- Input: (approximation coefficients, detail coefficients).
-- Output: reconstructed samples.
lift53Inverse1D :: Vector Int32 -> Vector Int32 -> Vector Int32
lift53Inverse1D approx detail
  | V.null detail = approx  -- degenerate case (0 or 1 sample)
  | otherwise =
      let nApprox = V.length approx
          nDetail = V.length detail
          n = nApprox + nDetail

          -- Step 1: Undo update (recover even-indexed samples)
          evens = V.generate nApprox $ \i ->
            let dLeft  = if i > 0 then detail V.! (i - 1) else detail V.! 0
                dRight = if i < nDetail then detail V.! i else detail V.! (nDetail - 1)
            in approx V.! i - (dLeft + dRight + 2) `div` 4

          -- Step 2: Undo predict (recover odd-indexed samples)
          odds = V.generate nDetail $ \i ->
            let left  = evens V.! i
                right = if i + 1 < nApprox then evens V.! (i + 1) else evens V.! i
            in detail V.! i + (left + right) `div` 2

          -- Interleave evens and odds
      in V.generate n $ \i ->
            if even i
            then evens V.! (i `div` 2)
            else odds V.! (i `div` 2)
```

- [ ] **Step 3: Register the module**

In `sigil-hs/package.yaml`, add `Sigil.Codec.Wavelet` to `exposed-modules`. Add `Test.Wavelet` to the test `other-modules`. In `sigil-hs/test/Spec.hs`, import and call `Test.Wavelet.spec`.

- [ ] **Step 4: Build and run tests**

```bash
cd sigil-hs && stack build && stack test 2>&1 | tail -40
```

Expected: All existing tests still pass. All new 1D wavelet tests pass. The property test `round-trips arbitrary vectors` is the most critical -- it verifies perfect round-trip for random Int32 vectors of varying lengths including odd sizes.

- [ ] **Step 5: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/src/Sigil/Codec/Wavelet.hs sigil-hs/test/Test/Wavelet.hs sigil-hs/test/Spec.hs sigil-hs/package.yaml sigil-hs/sigil-hs.cabal
git commit -m "feat(sigil-hs): add 1D integer 5/3 lifting transform in Sigil.Codec.Wavelet"
```

---

### Task 3: Wavelet Module -- 2D Separable DWT (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Wavelet.hs`
- Modify: `sigil-hs/test/Test/Wavelet.hs`

The 2D separable transform applies the 1D transform to all rows (horizontal), then all columns (vertical). This produces 4 subbands: LL, LH, HL, HH.

**CRITICAL NOTES:**
- After row transform, each row of width W becomes nApprox = ceil(W/2) approximation samples and nDetail = floor(W/2) detail samples. The intermediate buffer has all rows' approx coefficients in the left half and detail coefficients in the right half.
- After column transform on the intermediate buffer, the four subbands emerge.
- The 2D transform must handle odd dimensions correctly. A 5x3 image (5 wide, 3 high) produces subbands of sizes: LL=(3x2), LH=(2x2), HL=(3x1), HH=(2x1).
- The functions use a flat Vector Int32 in row-major layout with explicit width/height parameters.

- [ ] **Step 1: Add 2D tests to Test/Wavelet.hs**

Append to the existing spec:

```haskell
  describe "2D forward/inverse" $ do
    it "round-trips a 4x4 matrix" $ property $
      forAll (V.fromList <$> vectorOf 16 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, lh, hl, hh) = dwt2DForward 4 4 input
            output = dwt2DInverse 4 4 (ll, lh, hl, hh)
        in output === input

    it "round-trips a 3x3 matrix (odd dimensions)" $ property $
      forAll (V.fromList <$> vectorOf 9 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, lh, hl, hh) = dwt2DForward 3 3 input
            output = dwt2DInverse 3 3 (ll, lh, hl, hh)
        in output === input

    it "round-trips a 5x3 matrix (odd width, odd height)" $ property $
      forAll (V.fromList <$> vectorOf 15 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, lh, hl, hh) = dwt2DForward 5 3 input
            output = dwt2DInverse 5 3 (ll, lh, hl, hh)
        in output === input

    it "round-trips a 6x4 matrix (even dimensions)" $ property $
      forAll (V.fromList <$> vectorOf 24 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, lh, hl, hh) = dwt2DForward 6 4 input
            output = dwt2DInverse 6 4 (ll, lh, hl, hh)
        in output === input

    it "round-trips a 1x1 matrix (degenerate)" $
      let input = V.fromList [99 :: Int32]
          (ll, lh, hl, hh) = dwt2DForward 1 1 input
          output = dwt2DInverse 1 1 (ll, lh, hl, hh)
      in output `shouldBe` input

    it "round-trips a 2x1 matrix" $
      let input = V.fromList [10, 20 :: Int32]
          (ll, lh, hl, hh) = dwt2DForward 2 1 input
          output = dwt2DInverse 2 1 (ll, lh, hl, hh)
      in output `shouldBe` input

    it "round-trips a 1x2 matrix" $
      let input = V.fromList [10, 20 :: Int32]
          (ll, lh, hl, hh) = dwt2DForward 1 2 input
          output = dwt2DInverse 1 2 (ll, lh, hl, hh)
      in output `shouldBe` input

    it "round-trips arbitrary rectangles (property)" $ property $
      forAll (choose (1, 32 :: Int)) $ \w ->
        forAll (choose (1, 32 :: Int)) $ \h ->
          forAll (V.fromList <$> vectorOf (w * h) (arbitrary :: Gen Int32)) $ \input ->
            let (ll, lh, hl, hh) = dwt2DForward w h input
                output = dwt2DInverse w h (ll, lh, hl, hh)
            in output === input

    it "constant image has zero detail subbands" $
      let input = V.replicate 16 (42 :: Int32)
          (_, lh, hl, hh) = dwt2DForward 4 4 input
      in do
        V.all (== 0) lh `shouldBe` True
        V.all (== 0) hl `shouldBe` True
        V.all (== 0) hh `shouldBe` True

    it "produces correct subband sizes for 4x4" $
      let input = V.replicate 16 (0 :: Int32)
          (ll, lh, hl, hh) = dwt2DForward 4 4 input
      in do
        V.length ll `shouldBe` 4  -- 2x2
        V.length lh `shouldBe` 4  -- 2x2
        V.length hl `shouldBe` 4  -- 2x2
        V.length hh `shouldBe` 4  -- 2x2

    it "produces correct subband sizes for 5x3" $
      let input = V.replicate 15 (0 :: Int32)
          (ll, lh, hl, hh) = dwt2DForward 5 3 input
      in do
        -- w=5: wApprox=3, wDetail=2. h=3: hApprox=2, hDetail=1.
        -- LL = wApprox * hApprox = 3*2 = 6
        -- LH = wDetail * hApprox = 2*2 = 4
        -- HL = wApprox * hDetail = 3*1 = 3
        -- HH = wDetail * hDetail = 2*1 = 2
        V.length ll `shouldBe` 6
        V.length lh `shouldBe` 4
        V.length hl `shouldBe` 3
        V.length hh `shouldBe` 2
```

- [ ] **Step 2: Implement 2D DWT functions**

Add to `sigil-hs/src/Sigil/Codec/Wavelet.hs`, updating the module export list to include `dwt2DForward` and `dwt2DInverse`:

```haskell
-- | Extract a row from a row-major flat vector.
getRow :: Int -> Int -> Vector Int32 -> Int -> Vector Int32
getRow _w cols flat row = V.slice (row * cols) cols flat

-- | Extract a column from a row-major flat vector.
getCol :: Int -> Int -> Vector Int32 -> Int -> Vector Int32
getCol rows cols flat col = V.generate rows $ \row -> flat V.! (row * cols + col)

-- | Set a column in a mutable-style update (returns new vector with column replaced).
setCol :: Int -> Int -> Vector Int32 -> Int -> Vector Int32 -> Vector Int32
setCol _rows cols flat col colData =
  V.imap (\i v -> if i `mod` cols == col then colData V.! (i `div` cols) else v) flat

-- | 2D separable forward DWT (one level).
-- Input: width, height, flat row-major Int32 array.
-- Output: (LL, LH, HL, HH) subbands, each as flat row-major vectors.
dwt2DForward :: Int -> Int -> Vector Int32 -> (Vector Int32, Vector Int32, Vector Int32, Vector Int32)
dwt2DForward w h input =
  let -- Step 1: Transform all rows horizontally
      -- After row transform, each row of width w becomes:
      --   nApproxW = (w+1) `div` 2 approx coefficients
      --   nDetailW = w `div` 2 detail coefficients
      -- We store them as: [approx0 ++ detail0, approx1 ++ detail1, ...]
      nApproxW = (w + 1) `div` 2
      nDetailW = w `div` 2

      -- Transform each row and concatenate approx|detail
      rowTransformed = V.concat
        [ let row = getRow h w input r
              (s, d) = lift53Forward1D row
          in s V.++ d
        | r <- [0..h-1]
        ]
      -- rowTransformed is h rows of (nApproxW + nDetailW) = w columns
      -- Left half columns [0..nApproxW-1] are L (low-pass horizontal)
      -- Right half columns [nApproxW..w-1] are H (high-pass horizontal)

      -- Step 2: Transform all columns vertically
      nApproxH = (h + 1) `div` 2
      nDetailH = h `div` 2

      -- Transform columns in the L region (columns 0..nApproxW-1)
      -- Each column has h entries. After vertical transform: nApproxH approx + nDetailH detail.
      lCols = [ let col = getCol h w rowTransformed c
                    (s, d) = lift53Forward1D col
                in (s, d)
              | c <- [0..nApproxW-1]
              ]

      -- Transform columns in the H region (columns nApproxW..w-1)
      hCols = [ let col = getCol h w rowTransformed c
                    (s, d) = lift53Forward1D col
                in (s, d)
              | c <- [0..nDetailW-1]
              , let cIdx = nApproxW + c
              , let col = getCol h w rowTransformed cIdx
              , let (s, d) = lift53Forward1D col
              ]

      -- Actually, let me redo hCols correctly:
      hColsFixed = [ let col = getCol h w rowTransformed (nApproxW + c)
                         (s, d) = lift53Forward1D col
                     in (s, d)
                   | c <- [0..nDetailW-1]
                   ]

      -- Assemble subbands:
      -- LL = top of L columns = approx part of each L column -> nApproxW * nApproxH
      -- HL = bottom of L columns = detail part of each L column -> nApproxW * nDetailH
      -- LH = top of H columns = approx part of each H column -> nDetailW * nApproxH
      -- HH = bottom of H columns = detail part of each H column -> nDetailW * nDetailH

      -- LL: row-major, nApproxH rows x nApproxW cols
      ll = V.generate (nApproxH * nApproxW) $ \i ->
        let r = i `div` nApproxW
            c = i `mod` nApproxW
            (s, _) = lCols !! c
        in s V.! r

      -- LH: row-major, nApproxH rows x nDetailW cols
      lh = V.generate (nApproxH * nDetailW) $ \i ->
        let r = i `div` nDetailW
            c = i `mod` nDetailW
            (s, _) = hColsFixed !! c
        in s V.! r

      -- HL: row-major, nDetailH rows x nApproxW cols
      hl = V.generate (nDetailH * nApproxW) $ \i ->
        let r = i `div` nApproxW
            c = i `mod` nApproxW
            (_, d) = lCols !! c
        in d V.! r

      -- HH: row-major, nDetailH rows x nDetailW cols
      hh = V.generate (nDetailH * nDetailW) $ \i ->
        let r = i `div` nDetailW
            c = i `mod` nDetailW
            (_, d) = hColsFixed !! c
        in d V.! r

  in (ll, lh, hl, hh)
```

**IMPORTANT:** The above code has a list-comprehension issue with `hCols` -- the corrected version uses `hColsFixed`. A cleaner implementation that avoids the `(!!)` list indexing for the column data (which is O(n) per access) would be to use vectors of pairs. Here is the corrected, cleaner approach the implementer should use:

```haskell
dwt2DForward :: Int -> Int -> Vector Int32 -> (Vector Int32, Vector Int32, Vector Int32, Vector Int32)
dwt2DForward w h input
  | w <= 1 && h <= 1 = (input, V.empty, V.empty, V.empty)
  | otherwise =
      let nApproxW = (w + 1) `div` 2
          nDetailW = w `div` 2
          nApproxH = (h + 1) `div` 2
          nDetailH = h `div` 2

          -- Step 1: Transform all rows horizontally
          -- Store as flat array: h rows, each row is (approx ++ detail) of length w
          rowTransformed = V.concat
            [ let row = V.slice (r * w) w input
                  (s, d) = lift53Forward1D row
              in s V.++ d
            | r <- [0..h-1]
            ]

          -- Step 2: Transform all columns vertically
          -- For columns in L region (0..nApproxW-1): produces LL (approx) and HL (detail)
          -- For columns in H region (nApproxW..w-1): produces LH (approx) and HH (detail)
          transformCol colIdx =
            let col = V.generate h $ \r -> rowTransformed V.! (r * w + colIdx)
            in lift53Forward1D col

          -- L region columns
          lColResults = V.fromList [ transformCol c | c <- [0..nApproxW-1] ]
          -- H region columns
          hColResults = V.fromList [ transformCol (nApproxW + c) | c <- [0..nDetailW-1] ]

          -- LL: nApproxH rows x nApproxW cols
          ll = V.generate (nApproxH * nApproxW) $ \i ->
            let r = i `div` nApproxW
                c = i `mod` nApproxW
                (s, _) = lColResults V.! c
            in s V.! r

          -- LH: nApproxH rows x nDetailW cols
          lh = V.generate (nApproxH * nDetailW) $ \i ->
            let r = i `div` nDetailW
                c = i `mod` nDetailW
                (s, _) = hColResults V.! c
            in s V.! r

          -- HL: nDetailH rows x nApproxW cols
          hl = V.generate (nDetailH * nApproxW) $ \i ->
            let r = i `div` nApproxW
                c = i `mod` nApproxW
                (_, d) = lColResults V.! c
            in d V.! r

          -- HH: nDetailH rows x nDetailW cols
          hh = V.generate (nDetailH * nDetailW) $ \i ->
            let r = i `div` nDetailW
                c = i `mod` nDetailW
                (_, d) = hColResults V.! c
            in d V.! r

      in (ll, lh, hl, hh)

dwt2DInverse :: Int -> Int -> (Vector Int32, Vector Int32, Vector Int32, Vector Int32) -> Vector Int32
dwt2DInverse w h (ll, lh, hl, hh)
  | w <= 1 && h <= 1 = ll
  | otherwise =
      let nApproxW = (w + 1) `div` 2
          nDetailW = w `div` 2
          nApproxH = (h + 1) `div` 2
          nDetailH = h `div` 2

          -- Step 1: Inverse vertical transform on all columns
          -- Reconstruct L region columns from LL (approx) + HL (detail)
          -- Reconstruct H region columns from LH (approx) + HH (detail)

          inverseLCol c =
            let s = V.generate nApproxH $ \r -> ll V.! (r * nApproxW + c)
                d = V.generate nDetailH $ \r -> hl V.! (r * nApproxW + c)
            in lift53Inverse1D s d  -- produces h-element column

          inverseHCol c =
            let s = V.generate nApproxH $ \r -> lh V.! (r * nDetailW + c)
                d = V.generate nDetailH $ \r -> hh V.! (r * nDetailW + c)
            in lift53Inverse1D s d  -- produces h-element column

          lColsRecon = V.fromList [ inverseLCol c | c <- [0..nApproxW-1] ]
          hColsRecon = V.fromList [ inverseHCol c | c <- [0..nDetailW-1] ]

          -- Assemble into row-transformed buffer: h rows x w cols
          -- Row r: [L_col_0[r], L_col_1[r], ..., L_col_{nApproxW-1}[r],
          --         H_col_0[r], H_col_1[r], ..., H_col_{nDetailW-1}[r]]
          rowTransformed = V.generate (h * w) $ \i ->
            let r = i `div` w
                c = i `mod` w
            in if c < nApproxW
               then (lColsRecon V.! c) V.! r
               else (hColsRecon V.! (c - nApproxW)) V.! r

          -- Step 2: Inverse horizontal transform on all rows
      in V.concat
            [ let row = V.slice (r * w) w rowTransformed
                  s = V.take nApproxW row
                  d = V.drop nApproxW row
              in lift53Inverse1D s d
            | r <- [0..h-1]
            ]
```

- [ ] **Step 3: Build and run tests**

```bash
cd sigil-hs && stack build && stack test 2>&1 | tail -50
```

Expected: All tests pass, including the new 2D property test that covers arbitrary rectangles up to 32x32.

- [ ] **Step 4: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/src/Sigil/Codec/Wavelet.hs sigil-hs/test/Test/Wavelet.hs
git commit -m "feat(sigil-hs): add 2D separable DWT forward/inverse in Wavelet module"
```

---

### Task 4: Wavelet Module -- Multi-Level DWT (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Wavelet.hs`
- Modify: `sigil-hs/test/Test/Wavelet.hs`

Multi-level DWT recursively decomposes the LL subband. The forward pass applies single-level 2D DWT, saves the (LH, HL, HH) detail subbands, then recurses on LL. The inverse starts from the deepest LL and applies inverse 2D DWT at each level outward.

- [ ] **Step 1: Add multi-level tests**

Append to `sigil-hs/test/Test/Wavelet.hs`:

```haskell
  describe "multi-level DWT" $ do
    it "1 level round-trips a 4x4 matrix" $ property $
      forAll (V.fromList <$> vectorOf 16 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, details) = dwtForwardMulti 1 4 4 input
            output = dwtInverseMulti 1 4 4 ll details
        in output === input

    it "2 levels round-trips an 8x8 matrix" $ property $
      forAll (V.fromList <$> vectorOf 64 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, details) = dwtForwardMulti 2 8 8 input
            output = dwtInverseMulti 2 8 8 ll details
        in output === input

    it "3 levels round-trips a 16x16 matrix" $ property $
      forAll (V.fromList <$> vectorOf 256 (arbitrary :: Gen Int32)) $ \input ->
        let (ll, details) = dwtForwardMulti 3 16 16 input
            output = dwtInverseMulti 3 16 16 ll details
        in output === input

    it "round-trips with computed levels for 64x64" $ property $
      forAll (V.fromList <$> vectorOf (64*64) (arbitrary :: Gen Int32)) $ \input ->
        let levels = decompositionLevels 64 64  -- 3
            (ll, details) = dwtForwardMulti levels 64 64 input
            output = dwtInverseMulti levels 64 64 ll details
        in output === input

    it "round-trips odd dimensions with multiple levels" $ property $
      forAll (V.fromList <$> vectorOf (13*11) (arbitrary :: Gen Int32)) $ \input ->
        let levels = decompositionLevels 13 11  -- 1
            (ll, details) = dwtForwardMulti levels 13 11 input
            output = dwtInverseMulti levels 13 11 ll details
        in output === input

    it "round-trips arbitrary sizes and auto-levels (property)" $ property $
      forAll (choose (2, 64 :: Int)) $ \w ->
        forAll (choose (2, 64 :: Int)) $ \h ->
          forAll (V.fromList <$> vectorOf (w * h) (arbitrary :: Gen Int32)) $ \input ->
            let levels = decompositionLevels w h
                (ll, details) = dwtForwardMulti levels w h input
                output = dwtInverseMulti levels w h ll details
            in output === input

    it "produces correct number of detail levels" $
      let input = V.replicate (64*64) (0 :: Int32)
          (_, details) = dwtForwardMulti 3 64 64 input
      in length details `shouldBe` 3
```

- [ ] **Step 2: Implement multi-level DWT**

Add to `sigil-hs/src/Sigil/Codec/Wavelet.hs`, updating exports to include `dwtForwardMulti` and `dwtInverseMulti`:

```haskell
-- | Multi-level forward DWT.
-- Returns: (final LL subband, [(LH, HL, HH)] per level from shallowest to deepest).
-- The list is ordered: index 0 = shallowest level (largest subbands),
-- last index = deepest level (smallest subbands).
dwtForwardMulti :: Int -> Int -> Int -> Vector Int32
                -> (Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)])
dwtForwardMulti 0 _ _ input = (input, [])
dwtForwardMulti levels w h input =
  let (ll, lh, hl, hh) = dwt2DForward w h input
      llW = (w + 1) `div` 2
      llH = (h + 1) `div` 2
      (deepLL, deepDetails) = dwtForwardMulti (levels - 1) llW llH ll
  in (deepLL, (lh, hl, hh) : deepDetails)

-- | Multi-level inverse DWT.
-- Input: final LL subband, [(LH, HL, HH)] per level from shallowest to deepest.
-- The levels parameter and original (w, h) are needed to compute subband sizes at each level.
dwtInverseMulti :: Int -> Int -> Int -> Vector Int32
               -> [(Vector Int32, Vector Int32, Vector Int32)]
               -> Vector Int32
dwtInverseMulti 0 _ _ ll _ = ll
dwtInverseMulti levels w h ll details =
  let -- Compute the LL size at this level
      llW = (w + 1) `div` 2
      llH = (h + 1) `div` 2
      -- First detail entry = this level's detail subbands
      (lh, hl, hh) = head details
      -- Recurse: inverse the deeper levels first to get the LL for this level
      reconLL = dwtInverseMulti (levels - 1) llW llH ll (tail details)
      -- Inverse this level's 2D DWT
  in dwt2DInverse w h (reconLL, lh, hl, hh)
```

- [ ] **Step 3: Build and run tests**

```bash
cd sigil-hs && stack build && stack test 2>&1 | tail -50
```

Expected: All tests pass. The `arbitrary sizes and auto-levels` property test is the key one -- it exercises the full round-trip for random sizes with automatically computed decomposition levels.

- [ ] **Step 4: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/src/Sigil/Codec/Wavelet.hs sigil-hs/test/Test/Wavelet.hs
git commit -m "feat(sigil-hs): add multi-level DWT forward/inverse to Wavelet module"
```

---

### Task 5: Header Changes -- Add CompressionMethod, Remove Predictor

**Files:**
- Modify: `sigil-hs/src/Sigil/Core/Types.hs`
- Modify: `sigil-hs/src/Sigil/Core/Error.hs`
- Modify: `sigil-hs/src/Sigil/IO/Writer.hs`
- Modify: `sigil-hs/src/Sigil/IO/Reader.hs`
- Modify: `sigil-hs/src/Sigil/IO/Convert.hs`
- Modify: `sigil-hs/app/Main.hs`
- Modify: `sigil-hs/bench/Main.hs`
- Modify: `sigil-hs/server/Main.hs`
- Modify: `sigil-hs/test/Spec.hs`
- Modify: `sigil-hs/test/Test/Pipeline.hs`
- Modify: `sigil-hs/test/Test/Predict.hs`
- Modify: `sigil-hs/test/Gen.hs`

This is a sweeping change. The `predictor` field is removed from `Header` and replaced with `compressionMethod`. All consumers of `Header` must be updated. The old `PredictorId` type is kept in the codebase (it is still used by `Sigil.Codec.Predict` which is retained but no longer called by the pipeline).

- [ ] **Step 1: Update Types.hs**

In `sigil-hs/src/Sigil/Core/Types.hs`:

Add `CompressionMethod` type:
```haskell
data CompressionMethod
  = CMlegacy        -- ^ 0: predict+zigzag+zlib (v0.4, not supported in v0.5 encoder)
  | CMDWT           -- ^ 1: DWT lossless (5/3 + zlib, v0.5)
  deriving (Eq, Show, Enum, Bounded)
```

Change the `Header` type:
```haskell
data Header = Header
  { width             :: Word32
  , height            :: Word32
  , colorSpace        :: ColorSpace
  , bitDepth          :: BitDepth
  , compressionMethod :: CompressionMethod
  } deriving (Eq, Show)
```

Remove `predictor` from the export list. Add `CompressionMethod(..)` and update `rowBytes` (it no longer references `predictor`, but the current implementation does not use it anyway -- just confirm it still compiles).

- [ ] **Step 2: Update Error.hs**

Add `InvalidCompressionMethod Word8` variant to `SigilError`:
```haskell
  | InvalidCompressionMethod Word8
```

- [ ] **Step 3: Update Writer.hs**

Change the version to 0.5:
```haskell
versionMajor = 0
versionMinor = 5
```

Change `encodeHeader` to write the new SHDR format:
```haskell
encodeHeader :: Header -> ByteString
encodeHeader hdr = BL.toStrict $ runPut $ do
  putWord32be (width hdr)
  putWord32be (height hdr)
  putWord8 (fromIntegral $ fromEnum $ colorSpace hdr)
  putWord8 (case bitDepth hdr of Depth8 -> 8; Depth16 -> 16)
  putWord8 (fromIntegral $ fromEnum $ compressionMethod hdr)
```

- [ ] **Step 4: Update Reader.hs**

Accept version 0.5 (change the check from `minor /= 4` to `minor /= 5`).

Change `decodeHeader` to parse the new SHDR format: the third byte after colorspace and bitdepth is now `compressionMethod` instead of `predictor`.

```haskell
    parser = do
      w <- getWord32be
      h <- getWord32be
      cs <- getWord8
      bd <- getWord8
      cm <- getWord8
      pure $ do
        colorSp <- toColorSpace cs
        bitD    <- toBitDepth bd
        compM   <- toCompressionMethod cm
        when' (w == 0 || h == 0) $ Left (InvalidDimensions w h)
        Right (Header w h colorSp bitD compM)

    toCompressionMethod :: Word8 -> Either SigilError CompressionMethod
    toCompressionMethod 0 = Right CMlegacy
    toCompressionMethod 1 = Right CMDWT
    toCompressionMethod n = Left (InvalidCompressionMethod n)
```

Remove the `toPredictorId` helper and `InvalidPredictor` import.

- [ ] **Step 5: Update Convert.hs**

All `Header` construction sites that previously used `PAdaptive` need to change to `CMDWT`. For example, in `imageToSigil`:
```haskell
      hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 CMDWT
```

Update all four `imageToSigil*` functions similarly.

- [ ] **Step 6: Update app/Main.hs**

Remove references to `predictor` field. In `runInfo`, change `putStrLn $ "Predictor: " ++ show (predictor hdr)` to `putStrLn $ "Compression: " ++ show (compressionMethod hdr)`. Remove `predictor`-related benchmark logic (the benchmarks will be rebuilt in Task 8). Remove the predictor-per-row loop -- the bench command now tests only DWT compression.

Simplify the bench command: remove `forAll predictors`, just bench a single DWT encode/decode.

- [ ] **Step 7: Update bench/Main.hs**

Remove `NFData PredictorId` instance (or keep it -- it does no harm). Change all `Header` constructions from `PAdaptive` to `CMDWT`. Remove the predictor-iteration loop. Bench just the DWT pipeline.

- [ ] **Step 8: Update server/Main.hs**

No changes needed beyond what Convert.hs handles (the server constructs Headers via `dynamicToSigil` which calls `imageToSigil`).

- [ ] **Step 9: Update test files**

In `sigil-hs/test/Gen.hs`:
- Remove `arbitraryFixedPredictor`.
- Change `arbitraryImage` to remain as-is (it generates raw pixel data, independent of Header).

In `sigil-hs/test/Test/Pipeline.hs`:
- Change all `Header` constructions to use `CMDWT` instead of `pid`/`PAdaptive`.
- Remove the `forAll arbitraryFixedPredictor` generators.
- Simplify to test just `CMDWT` compression method (3 tests: RGB, grayscale, RGBA).

In `sigil-hs/test/Test/Predict.hs`:
- This module still tests the Predict module independently (the module is kept).
- It constructs its own Headers with `PAdaptive`/etc. -- but wait, the `Header` no longer has a `predictor` field.
- **Decision**: The Predict test must construct `Header` values that still work. Since Predict is no longer used by the pipeline and its types are being decoupled, we have two options: (a) keep a `predictor` field but unused by pipeline, or (b) change Predict to not take a Header.
- **Recommended approach**: Keep the `PredictorId` type in `Types.hs` but remove it from `Header`. The `Predict` module functions that take `Header` (`predictImage`, `unpredictImage`) should be updated to take `PredictorId` directly instead of extracting from `Header`. However, this is a larger refactor of an unused module. **Simpler approach**: leave `Test.Predict` tests as-is but update them to construct a temporary header-like structure, or just have them call the row-level functions directly. Since the predict tests primarily test `predictRow`/`unpredictRow` and the property tests at the image level, the cleanest approach is to **remove `Test.Predict`'s image-level tests** and keep only the row-level tests which do not need a Header.

In `sigil-hs/test/Spec.hs`:
- All `Header` constructions in the "File I/O" test change to use `CMDWT`.

In `sigil-hs/test/Test/Conformance.hs`:
- No changes needed (it uses `loadImage` which constructs its own Header via Convert).

- [ ] **Step 10: Rebuild the .cabal file and build**

```bash
cd sigil-hs && stack build 2>&1 | head -50
```

Fix any compilation errors from the Header change propagation. This step may require several iterations.

- [ ] **Step 11: Run all tests (some will fail -- that is expected since Pipeline has not been updated yet)**

```bash
cd sigil-hs && stack test 2>&1 | tail -50
```

At this point, wavelet and color transform tests should pass. Pipeline tests and conformance tests will fail because the pipeline still uses predict+zigzag+zlib internally. That is addressed in Task 6.

- [ ] **Step 12: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/src/Sigil/Core/Types.hs sigil-hs/src/Sigil/Core/Error.hs sigil-hs/src/Sigil/IO/Writer.hs sigil-hs/src/Sigil/IO/Reader.hs sigil-hs/src/Sigil/IO/Convert.hs sigil-hs/app/Main.hs sigil-hs/bench/Main.hs sigil-hs/server/Main.hs sigil-hs/test/Spec.hs sigil-hs/test/Gen.hs sigil-hs/test/Test/Pipeline.hs sigil-hs/test/Test/Predict.hs sigil-hs/package.yaml sigil-hs/sigil-hs.cabal
git commit -m "refactor(sigil-hs): replace predictor with compressionMethod in Header, bump to v0.5"
```

---

### Task 6: Pipeline Integration -- RCT + DWT + zlib

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs`
- Modify: `sigil-hs/src/Sigil.hs`

This is the core integration task. The pipeline changes from `predict -> zigzag -> zlib` to `RCT -> DWT -> serialize -> zlib`. The old pipeline is removed from Pipeline.hs (the old modules Predict, ZigZag, Token, Rice, ANS are kept in the codebase but no longer imported by Pipeline).

The SDAT payload format is:
```
[u8: num_levels]
[u8: color_transform — 0=none, 1=RCT]
[u8: num_channels]
[zlib-compressed coefficient data]
```

The compressed coefficient data contains, for each channel:
- Final LL subband (row-major Int32 BE)
- For each level (deepest first): LH, HL, HH subbands (row-major Int32 BE)

- [ ] **Step 1: Rewrite Pipeline.hs**

Replace the contents of `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

```haskell
module Sigil.Codec.Pipeline
  ( compress
  , decompress
  ) where

import Data.Bits ((.&.), (.|.), shiftR, shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int32)
import Data.Word (Word8)
import Data.Vector (Vector)
import qualified Data.Vector as V

import qualified Codec.Compression.Zlib as Z

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.ColorTransform
import Sigil.Codec.Wavelet

-- | Compress an image to raw encoded bytes (SDAT payload).
compress :: Header -> Image -> ByteString
compress hdr img =
  let w = fromIntegral (width hdr) :: Int
      h = fromIntegral (height hdr) :: Int
      cs = colorSpace hdr
      nCh = channels cs
      levels = decompositionLevels w h

      -- Flatten image from Vector (Vector Word8) to single Vector Word8
      flatPixels = V.concat (V.toList img)

      -- Apply color transform and split into channels
      (channelData, useRCT) = case cs of
        RGB ->
          let (yc, cbc, crc) = forwardRCT w h flatPixels
          in ([yc, cbc, crc], True)
        RGBA ->
          let rgbPixels = extractRGBFromRGBA w h flatPixels
              alphaPixels = extractAlphaFromRGBA w h flatPixels
              (yc, cbc, crc) = forwardRCT w h rgbPixels
          in ([yc, cbc, crc, grayscaleToInt32 alphaPixels], True)
        Grayscale ->
          ([grayscaleToInt32 flatPixels], False)
        GrayscaleAlpha ->
          let gray = extractChannel w h flatPixels 2 0
              alpha = extractChannel w h flatPixels 2 1
          in ([grayscaleToInt32 gray, grayscaleToInt32 alpha], False)

      -- Apply DWT to each channel
      dwtResults = map (dwtForwardMulti levels w h) channelData

      -- Serialize coefficients
      coeffBytes = serializeCoefficients dwtResults

      -- Compress with zlib
      compressed = BL.toStrict $ Z.compress $ BL.fromStrict coeffBytes

      -- Build SDAT payload
      header = BS.pack
        [ fromIntegral levels
        , if useRCT then 1 else 0
        , fromIntegral (length channelData)
        ]

  in header <> compressed

-- | Decompress raw encoded bytes back to an image.
decompress :: Header -> ByteString -> Either SigilError Image
decompress hdr bs = do
  let w = fromIntegral (width hdr) :: Int
      h = fromIntegral (height hdr) :: Int
      cs = colorSpace hdr

  -- Parse SDAT header
  if BS.length bs < 3
    then Left TruncatedInput
    else do
      let levels = fromIntegral (BS.index bs 0) :: Int
          useRCT = BS.index bs 1 == 1
          numChannels = fromIntegral (BS.index bs 2) :: Int
          compressedData = BS.drop 3 bs

      -- Decompress with zlib
      let decompressed = BL.toStrict $ Z.decompress $ BL.fromStrict compressedData

      -- Deserialize coefficients
      let dwtResults = deserializeCoefficients levels w h numChannels decompressed

      -- Inverse DWT on each channel
      let channelData = map (\(ll, details) -> dwtInverseMulti levels w h ll details) dwtResults

      -- Inverse color transform and recombine
      let flatPixels = case cs of
            RGB | useRCT ->
              inverseRCT w h (channelData !! 0, channelData !! 1, channelData !! 2)
            RGBA | useRCT ->
              let rgbPixels = inverseRCT w h (channelData !! 0, channelData !! 1, channelData !! 2)
                  alphaPixels = int32ToGrayscale (channelData !! 3)
              in interleaveRGBA w h rgbPixels alphaPixels
            Grayscale ->
              int32ToGrayscale (head channelData)
            GrayscaleAlpha ->
              let gray = int32ToGrayscale (channelData !! 0)
                  alpha = int32ToGrayscale (channelData !! 1)
              in interleaveChannels w h [gray, alpha]
            _ -> flatPixels -- fallback, should not happen

      -- Rebuild row-based Image
      let nCh = channels cs
          rowLen = w * nCh
          rows = V.fromList
            [ V.slice (r * rowLen) rowLen flatPixels
            | r <- [0..h-1]
            ]
      Right rows

-- ── Channel extraction helpers ──────────────────────────

-- | Extract RGB channels from interleaved RGBA as interleaved RGB.
extractRGBFromRGBA :: Int -> Int -> Vector Word8 -> Vector Word8
extractRGBFromRGBA w h pixels =
  let n = w * h
  in V.generate (n * 3) $ \i ->
       let px = i `div` 3
           ch = i `mod` 3
       in pixels V.! (px * 4 + ch)

-- | Extract alpha channel from interleaved RGBA.
extractAlphaFromRGBA :: Int -> Int -> Vector Word8 -> Vector Word8
extractAlphaFromRGBA w h pixels =
  let n = w * h
  in V.generate n $ \px -> pixels V.! (px * 4 + 3)

-- | Extract a single channel from interleaved pixel data.
extractChannel :: Int -> Int -> Vector Word8 -> Int -> Int -> Vector Word8
extractChannel w h pixels numCh chIdx =
  let n = w * h
  in V.generate n $ \px -> pixels V.! (px * numCh + chIdx)

-- | Interleave RGB + alpha into RGBA.
interleaveRGBA :: Int -> Int -> Vector Word8 -> Vector Word8 -> Vector Word8
interleaveRGBA w h rgb alpha =
  let n = w * h
  in V.generate (n * 4) $ \i ->
       let px = i `div` 4
           ch = i `mod` 4
       in if ch < 3
          then rgb V.! (px * 3 + ch)
          else alpha V.! px

-- | Interleave multiple single-channel vectors.
interleaveChannels :: Int -> Int -> [Vector Word8] -> Vector Word8
interleaveChannels w h chs =
  let n = w * h
      numCh = length chs
  in V.generate (n * numCh) $ \i ->
       let px = i `div` numCh
           ch = i `mod` numCh
       in (chs !! ch) V.! px

-- ── Coefficient serialization ───────────────────────────

-- | Serialize DWT results for all channels.
-- Each channel: LL subband, then for each level (deepest first) LH, HL, HH.
-- All coefficients as big-endian Int32.
serializeCoefficients :: [(Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)])] -> ByteString
serializeCoefficients results = BS.concat $ map serializeChannel results
  where
    serializeChannel (ll, details) =
      let -- details is shallowest-first; we serialize deepest-first
          reversedDetails = reverse details
          llBytes = vectorToBytes ll
          detailBytes = BS.concat
            [ vectorToBytes lh <> vectorToBytes hl <> vectorToBytes hh
            | (lh, hl, hh) <- reversedDetails
            ]
      in llBytes <> detailBytes

-- | Deserialize DWT results for all channels.
deserializeCoefficients :: Int -> Int -> Int -> Int -> ByteString
                        -> [(Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)])]
deserializeCoefficients levels w h numChannels bs =
  let -- Compute subband sizes for each level
      subbandSizes = computeSubbandSizes levels w h
      channelByteSize = sum [ 4 * (llW * llH + sum [ lhW*lhH + hlW*hlH + hhW*hhH
                                                     | (_, _, lhW, lhH, hlW, hlH, hhW, hhH) <- lvls ])
                            | (llW, llH, lvls) <- [subbandSizes] ]
      -- Actually, we need to compute the total bytes per channel
      go offset 0 = []
      go offset n =
        let (result, offset') = deserializeChannel levels w h offset bs
        in result : go offset' (n - 1)
  in go 0 numChannels

deserializeChannel :: Int -> Int -> Int -> Int -> ByteString
                   -> ((Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)]), Int)
deserializeChannel levels w h offset bs =
  let sizes = computeAllSubbandSizes levels w h
      -- sizes: [(llW, llH)] for the final LL, then [(lhW,lhH,hlW,hlH,hhW,hhH)] for each level deepest-first
      (finalLLW, finalLLH) = fst sizes
      levelSizes = snd sizes

      -- Read LL
      llLen = finalLLW * finalLLH
      ll = bytesToVector llLen (BS.drop offset bs)
      offset1 = offset + llLen * 4

      -- Read detail subbands for each level (deepest first in the stream)
      (detailsDeepFirst, offsetFinal) = foldl
        (\(acc, off) (lhW, lhH, hlW, hlH, hhW, hhH) ->
          let lhLen = lhW * lhH
              hlLen = hlW * hlH
              hhLen = hhW * hhH
              lh = bytesToVector lhLen (BS.drop off bs)
              hl = bytesToVector hlLen (BS.drop (off + lhLen * 4) bs)
              hh = bytesToVector hhLen (BS.drop (off + (lhLen + hlLen) * 4) bs)
              off' = off + (lhLen + hlLen + hhLen) * 4
          in (acc ++ [(lh, hl, hh)], off')
        ) ([], offset1) levelSizes

      -- Reverse to get shallowest-first (matching dwtForwardMulti output order)
      detailsShallowFirst = reverse detailsDeepFirst

  in ((ll, detailsShallowFirst), offsetFinal)

-- | Compute final LL size and per-level detail sizes.
-- Returns: ((finalLLW, finalLLH), [(lhW, lhH, hlW, hlH, hhW, hhH)] deepest-first)
computeAllSubbandSizes :: Int -> Int -> Int -> ((Int, Int), [(Int, Int, Int, Int, Int, Int)])
computeAllSubbandSizes 0 w h = ((w, h), [])
computeAllSubbandSizes levels w h =
  let nApproxW = (w + 1) `div` 2
      nDetailW = w `div` 2
      nApproxH = (h + 1) `div` 2
      nDetailH = h `div` 2
      -- LH = nDetailW x nApproxH, HL = nApproxW x nDetailH, HH = nDetailW x nDetailH
      thisLevel = (nDetailW, nApproxH, nApproxW, nDetailH, nDetailW, nDetailH)
      (finalLL, deeperLevels) = computeAllSubbandSizes (levels - 1) nApproxW nApproxH
  in (finalLL, deeperLevels ++ [thisLevel])
  -- Note: we append this level at the end because deeper levels are serialized first,
  -- and this recursive structure builds from shallow to deep. The final list has
  -- deepest first, shallowest last. We reverse later.
  -- Actually, let me reconsider: deeperLevels has the levels deeper than this one.
  -- This level is the shallowest remaining. We want deepest-first output.
  -- deeperLevels already has levels deeper than ours in deepest-first order.
  -- So: deeperLevels ++ [thisLevel] = deepest-first, then this level (shallowest).
  -- That IS deepest-first. Correct.
```

**NOTE TO IMPLEMENTER:** The deserialization logic above is complex. The key insight is:
1. `computeAllSubbandSizes levels w h` recursively computes the final LL size and builds a list of per-level detail subband sizes ordered deepest-first.
2. The serialization writes LL first, then detail subbands from deepest to shallowest.
3. The deserialization reads them in the same order and reverses to match the shallowest-first convention used by `dwtForwardMulti`/`dwtInverseMulti`.

The helper functions `vectorToBytes` and `bytesToVector`:

```haskell
-- | Encode a Vector Int32 as big-endian bytes.
vectorToBytes :: Vector Int32 -> ByteString
vectorToBytes v = BS.pack $ concatMap int32ToBytes (V.toList v)
  where
    int32ToBytes :: Int32 -> [Word8]
    int32ToBytes x =
      [ fromIntegral (x `shiftR` 24)
      , fromIntegral (x `shiftR` 16)
      , fromIntegral (x `shiftR` 8)
      , fromIntegral x
      ]

-- | Decode big-endian bytes to a Vector Int32.
bytesToVector :: Int -> ByteString -> Vector Int32
bytesToVector n bs = V.generate n $ \i ->
  let off = i * 4
      b0 = fromIntegral (BS.index bs off) :: Int32
      b1 = fromIntegral (BS.index bs (off + 1)) :: Int32
      b2 = fromIntegral (BS.index bs (off + 2)) :: Int32
      b3 = fromIntegral (BS.index bs (off + 3)) :: Int32
  in (b0 `shiftL` 24) .|. (b1 `shiftL` 16) .|. (b2 `shiftL` 8) .|. b3
```

- [ ] **Step 2: Update Sigil.hs to re-export new modules**

In `sigil-hs/src/Sigil.hs`, add:
```haskell
import Sigil.Codec.Wavelet
import Sigil.Codec.ColorTransform
```

And add them to the module export list.

- [ ] **Step 3: Build**

```bash
cd sigil-hs && stack build 2>&1 | head -50
```

Fix compilation errors. The pipeline rewrite is large; expect several type-error iterations particularly around the `decompress` function's `Either` handling.

- [ ] **Step 4: Run tests**

```bash
cd sigil-hs && stack test 2>&1 | tail -50
```

Expected: ColorTransform tests pass, Wavelet tests pass, Pipeline round-trip tests pass, File I/O round-trip tests pass. Conformance tests will fail (golden files are v0.4).

- [ ] **Step 5: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/src/Sigil/Codec/Pipeline.hs sigil-hs/src/Sigil.hs
git commit -m "feat(sigil-hs): replace predict+zigzag pipeline with RCT+DWT+zlib"
```

---

### Task 7: Version Bump + Golden File Regeneration

**Files:**
- Modify: `sigil-hs/test/Test/Conformance.hs`
- Regenerate: `tests/corpus/expected/*.sgl`

- [ ] **Step 1: Delete old golden files**

```bash
rm "/Users/dennis/programming projects/imgcompressor/tests/corpus/expected/"*.sgl
```

- [ ] **Step 2: Run tests to regenerate golden files**

```bash
cd sigil-hs && stack test 2>&1 | tail -30
```

The conformance tests will create new golden files on first run (they use `pendingWith "golden file created"`). Run tests a second time to verify they match:

```bash
stack test 2>&1 | tail -30
```

Expected: All tests pass on second run. Golden files are deterministic.

- [ ] **Step 3: Verify round-trip with CLI**

```bash
cd sigil-hs
stack run sigil-hs -- verify ../tests/corpus/gradient_256x256.png
stack run sigil-hs -- verify ../tests/corpus/flat_white_100x100.png
stack run sigil-hs -- verify ../tests/corpus/noise_128x128.png
stack run sigil-hs -- verify ../tests/corpus/checkerboard_64x64.png
```

Expected: All print PASS.

- [ ] **Step 4: Check file info for the new format**

```bash
stack run sigil-hs -- info ../tests/corpus/expected/gradient_256x256.sgl
```

Expected: Shows Compression: CMDWT (not PAdaptive).

- [ ] **Step 5: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add tests/corpus/expected/
git commit -m "chore: regenerate v0.5 golden .sgl files with DWT compression"
```

---

### Task 8: Compression Comparison Benchmark

**Files:**
- Modify: `sigil-hs/bench/Main.hs`
- Modify: `sigil-hs/app/Main.hs`

- [ ] **Step 1: Update bench/Main.hs**

Remove the per-predictor benchmark loop. Replace with DWT pipeline benchmarks:
- `bgroup "pipeline-dwt"` with encode and decode at multiple sizes.
- Add wavelet-specific benchmarks: `bgroup "wavelet"` with 1D lift, 2D DWT, multi-level DWT.
- Add RCT benchmark: `bgroup "rct"` with forward/inverse on image data.
- Keep the existing tokenize/rice/zigzag benchmarks if desired (they test individual modules).

Add `NFData CompressionMethod` instance.

- [ ] **Step 2: Update app/Main.hs bench command**

Update `runBench` to compare DWT compression instead of per-predictor comparison. Print:
- Sigil v0.5 (DWT) compressed size and ratio
- PNG file size for comparison

Remove the residual analysis section (no longer relevant with DWT).

- [ ] **Step 3: Run benchmarks**

```bash
cd sigil-hs && stack bench 2>&1 | tail -40
```

Expected: Benchmarks run. DWT pipeline should be somewhat slower than prediction pipeline (DWT is more compute-intensive) but compressed sizes should be better especially for photographic content.

- [ ] **Step 4: Run corpus benchmark**

```bash
cd sigil-hs && stack run sigil-hs -- bench ../tests/corpus/gradient_256x256.png --iterations 5
```

Expected: Shows compressed size and ratio for DWT.

- [ ] **Step 5: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-hs/bench/Main.hs sigil-hs/app/Main.hs
git commit -m "feat(sigil-hs): update benchmarks for DWT pipeline"
```

---

### Task 9: Rust Decoder -- Wavelet + Color Transform + Pipeline Update

**Files:**
- Create: `sigil-rs/src/wavelet.rs`
- Create: `sigil-rs/src/color_transform.rs`
- Modify: `sigil-rs/src/pipeline.rs`
- Modify: `sigil-rs/src/reader.rs`
- Modify: `sigil-rs/src/types.rs`
- Modify: `sigil-rs/src/error.rs`
- Modify: `sigil-rs/src/lib.rs`
- Modify: `sigil-rs/tests/conformance.rs`

The Rust decoder needs only the inverse transforms (decode path).

- [ ] **Step 1: Update types.rs**

Replace `PredictorId` with `CompressionMethod`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompressionMethod {
    Legacy,  // 0
    Dwt,     // 1
}

impl CompressionMethod {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(CompressionMethod::Legacy),
            1 => Some(CompressionMethod::Dwt),
            _ => None,
        }
    }
}
```

Update `Header`:
```rust
pub struct Header {
    pub width: u32,
    pub height: u32,
    pub color_space: ColorSpace,
    pub bit_depth: BitDepth,
    pub compression_method: CompressionMethod,
}
```

Keep the old `PredictorId` type for the predict module (which is retained) but remove it from `Header`.

- [ ] **Step 2: Update error.rs**

Add `InvalidCompressionMethod(u8)` variant.

- [ ] **Step 3: Create color_transform.rs**

```rust
/// Inverse RCT: (Yr, Cb, Cr) -> (R, G, B) per pixel.
pub fn inverse_rct(width: usize, height: usize, yr: &[i32], cb: &[i32], cr: &[i32]) -> Vec<u8> {
    let n = width * height;
    let mut pixels = Vec::with_capacity(n * 3);
    for i in 0..n {
        let g = yr[i] - (cb[i] + cr[i]).div_euclid(4);
        let r = cr[i] + g;
        let b = cb[i] + g;
        pixels.push(r as u8);
        pixels.push(g as u8);
        pixels.push(b as u8);
    }
    pixels
}

/// Convert i32 channel back to u8.
pub fn int32_to_grayscale(data: &[i32]) -> Vec<u8> {
    data.iter().map(|&x| x as u8).collect()
}
```

**CRITICAL:** Use `div_euclid` (Rust's floor-division equivalent for signed integers) to match Haskell's `div`. Standard Rust `/` truncates toward zero, while Haskell's `div` truncates toward negative infinity. For the RCT inverse formula `floor((Cb + Cr) / 4)`, the dividend can be negative, so `div_euclid(4)` is required for correct round-trip. Same applies to the wavelet lifting steps.

- [ ] **Step 4: Create wavelet.rs**

Implement the inverse 1D, 2D, and multi-level transforms in Rust, mirroring the Haskell implementation. Use `div_euclid` for all integer division operations.

```rust
/// 1D inverse 5/3 lifting transform.
pub fn lift53_inverse_1d(approx: &[i32], detail: &[i32]) -> Vec<i32> {
    if detail.is_empty() {
        return approx.to_vec();
    }
    let n_approx = approx.len();
    let n_detail = detail.len();
    let n = n_approx + n_detail;

    // Step 1: Undo update
    let mut evens = vec![0i32; n_approx];
    for i in 0..n_approx {
        let d_left = if i > 0 { detail[i - 1] } else { detail[0] };
        let d_right = if i < n_detail { detail[i] } else { detail[n_detail - 1] };
        evens[i] = approx[i] - (d_left + d_right + 2).div_euclid(4);
    }

    // Step 2: Undo predict
    let mut odds = vec![0i32; n_detail];
    for i in 0..n_detail {
        let left = evens[i];
        let right = if i + 1 < n_approx { evens[i + 1] } else { evens[i] };
        odds[i] = detail[i] + (left + right).div_euclid(2);
    }

    // Interleave
    let mut result = vec![0i32; n];
    for i in 0..n_approx {
        result[2 * i] = evens[i];
    }
    for i in 0..n_detail {
        result[2 * i + 1] = odds[i];
    }
    result
}

/// 2D inverse DWT and multi-level inverse follow the same structure
/// as the Haskell implementation.
```

The 2D inverse and multi-level inverse follow the same logic as the Haskell code: inverse columns first, then inverse rows.

- [ ] **Step 5: Update pipeline.rs**

Rewrite `decompress` to:
1. Read 3-byte SDAT header (levels, color_transform flag, num_channels)
2. Zlib decompress the rest
3. Deserialize coefficients
4. Inverse multi-level DWT per channel
5. Inverse RCT
6. Return flat pixel data

- [ ] **Step 6: Update reader.rs**

Accept version 0.5. Parse new SHDR format (compression_method instead of predictor).

- [ ] **Step 7: Update lib.rs**

Add `mod wavelet;` and `mod color_transform;`. Update public exports.

- [ ] **Step 8: Update conformance tests**

In `sigil-rs/tests/conformance.rs`:
- Change `header.predictor` assertions to `header.compression_method` assertions.
- The conformance tests read the golden .sgl files (now v0.5) and compare against PNG source pixels.

- [ ] **Step 9: Build and test**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs" && cargo test 2>&1 | tail -40
```

Expected: All Rust tests pass, including conformance tests that verify the Rust decoder produces identical pixels from the v0.5 golden files.

- [ ] **Step 10: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-rs/src/wavelet.rs sigil-rs/src/color_transform.rs sigil-rs/src/pipeline.rs sigil-rs/src/reader.rs sigil-rs/src/types.rs sigil-rs/src/error.rs sigil-rs/src/lib.rs sigil-rs/tests/conformance.rs
git commit -m "feat(sigil-rs): add DWT+RCT decoder for Sigil v0.5"
```

---

### Task 10: WASM Rebuild + Smoke Test

**Files:**
- Modify: `sigil-wasm/src/lib.rs`
- Rebuild: `sigil-wasm/pkg/`
- Copy: rebuilt artifacts to `sigil-hs/static/`

- [ ] **Step 1: Update sigil-wasm/src/lib.rs**

Replace `predictor` field exposure with `compressionMethod`:
```rust
set(&obj, "compressionMethod", &JsValue::from(compression_method_str(header.compression_method)));
```

Add the helper:
```rust
fn compression_method_str(cm: sigil_decode::CompressionMethod) -> &'static str {
    match cm {
        sigil_decode::CompressionMethod::Legacy => "legacy",
        sigil_decode::CompressionMethod::Dwt => "dwt",
    }
}
```

Remove the `predictor_str` function and `PredictorId` import.

- [ ] **Step 2: Build WASM**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-wasm" && wasm-pack build --target web --release 2>&1 | tail -20
```

Expected: Build succeeds.

- [ ] **Step 3: Copy WASM artifacts to static directory**

```bash
cp "/Users/dennis/programming projects/imgcompressor/sigil-wasm/pkg/sigil_wasm_bg.wasm" "/Users/dennis/programming projects/imgcompressor/sigil-hs/static/"
cp "/Users/dennis/programming projects/imgcompressor/sigil-wasm/pkg/sigil_wasm.js" "/Users/dennis/programming projects/imgcompressor/sigil-hs/static/"
```

- [ ] **Step 4: Smoke test -- start server and test encode/decode**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-hs"
stack run sigil-server &
sleep 2

# Test encode
curl -s -X POST --data-binary @../tests/corpus/gradient_256x256.png \
  -H "Content-Type: image/png" \
  http://localhost:3000/api/encode -o /tmp/test_v05.sgl -v 2>&1 | grep "X-Sigil"

# Verify the .sgl file
stack run sigil-hs -- info /tmp/test_v05.sgl

kill %1
```

Expected: Server starts, encode returns proper headers. Info shows v0.5 format with CMDWT compression.

- [ ] **Step 5: Commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add sigil-wasm/src/lib.rs sigil-hs/static/sigil_wasm_bg.wasm sigil-hs/static/sigil_wasm.js
git commit -m "feat(sigil-wasm): rebuild WASM decoder for Sigil v0.5"
```

---

### Task 11: Full Stack Validation

**Files:** None (verification only)

- [ ] **Step 1: Run all Haskell tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-hs" && stack test 2>&1
```

Expected: All tests pass. Count should be higher than the original 62 (new wavelet and color transform tests added).

- [ ] **Step 2: Run all Rust tests**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-rs" && cargo test 2>&1
```

Expected: All tests pass. Count should be higher than the original 38.

- [ ] **Step 3: Cross-validate Haskell encoder with Rust decoder**

The conformance tests already do this (Haskell generates golden .sgl, Rust decodes them and compares against PNG source). But let us also test with the CLI:

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-hs"

# Encode all corpus images
for img in ../tests/corpus/*.png; do
  name=$(basename "$img" .png)
  stack run sigil-hs -- encode "$img" -o "/tmp/${name}_v05.sgl"
  echo "Encoded $name"
done

# Decode them back
for img in ../tests/corpus/*.png; do
  name=$(basename "$img" .png)
  stack run sigil-hs -- decode "/tmp/${name}_v05.sgl" -o "/tmp/${name}_v05_decoded.png"
  stack run sigil-hs -- verify "$img"
  echo "Verified $name"
done
```

Expected: All encode/decode/verify operations succeed.

- [ ] **Step 4: Run compression comparison**

```bash
cd "/Users/dennis/programming projects/imgcompressor/sigil-hs"
stack run sigil-hs -- bench ../tests/corpus/gradient_256x256.png --iterations 5
stack run sigil-hs -- bench ../tests/corpus/noise_128x128.png --iterations 5
```

Expected: DWT should compress gradient images significantly better than v0.4's prediction approach (which was already quite good on gradients). Noise should show minimal difference.

- [ ] **Step 5: Update README.md if desired**

Note the version bump to v0.5 and the new DWT-based compression in the project README.

- [ ] **Step 6: Final commit**

```bash
cd "/Users/dennis/programming projects/imgcompressor"
git add -A
git commit -m "chore: Sigil v0.5 complete — DWT lossless compression, all tests passing"
```

---

## Key Technical Decisions

1. **`Data.Vector` (boxed) throughout** -- consistent with existing codebase. Performance optimization to `Data.Vector.Storable` or `Data.Vector.Unboxed` can be done later as a separate task.

2. **Haskell `div` vs Rust `div_euclid`** -- Both floor toward negative infinity, which is required for lossless round-trip with the 5/3 lifting scheme. Standard C-style division (truncation toward zero) would break the transform for negative values.

3. **Detail list ordering** -- `dwtForwardMulti` returns details in shallowest-first order (consistent with the recursive decomposition structure). The serialized format writes deepest-first (smallest subbands first). The serialization/deserialization handles the reversal.

4. **Boundary handling** -- Mirror extension at edges. For the predict step, `right = x[2*i]` when `2*i+2 >= N` (mirror the left neighbor). For the update step, `d_left = d[0]` when `i = 0`, and `d_right = d[nDetail-1]` when `i >= nDetail`.

5. **Old modules retained** -- `Predict`, `ZigZag`, `Token`, `Rice`, `ANS` are kept in the codebase but no longer imported by Pipeline. This avoids unnecessary churn and allows potential future use or comparison.

---

### Critical Files for Implementation
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Wavelet.hs`
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/ColorTransform.hs`
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Codec/Pipeline.hs`
- `/Users/dennis/programming projects/imgcompressor/sigil-hs/src/Sigil/Core/Types.hs`
- `/Users/dennis/programming projects/imgcompressor/sigil-rs/src/wavelet.rs`