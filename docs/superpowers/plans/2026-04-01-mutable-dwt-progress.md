# Mutable DWT + Progress Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Sigil encoder handle real-world photos (5MP+) by replacing immutable Vector DWT with mutable arrays, and show encoding progress in the web UI.

**Architecture:** New `WaveletMut` module performs the 5/3 lifting in-place using `Data.Vector.Unboxed.Mutable` in the `ST` monad. `Pipeline.hs` switches to use it with boxed/unboxed conversion at the boundary. A new `compressWithProgress` function takes an IO callback that reports pipeline stages. The server exposes a polling endpoint for progress state, and the frontend replaces the spinner with a progress bar.

**Tech Stack:** Haskell (ST monad, Data.Vector.Unboxed.Mutable, IORef), Scotty (JSON polling endpoint), vanilla JS (setInterval polling)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `sigil-hs/src/Sigil/Codec/WaveletMut.hs` | Create | Mutable 5/3 DWT: forward/inverse 1D, 2D, and multi-level |
| `sigil-hs/test/Test/WaveletMut.hs` | Create | QuickCheck equivalence tests vs immutable Wavelet |
| `sigil-hs/src/Sigil/Codec/Pipeline.hs` | Modify | Switch to WaveletMut, add `compressWithProgress` |
| `sigil-hs/src/Sigil/IO/Writer.hs` | Modify | Add `encodeSigilFileWithPayload` that takes pre-compressed SDAT |
| `sigil-hs/src/Sigil.hs` | Modify | Re-export WaveletMut |
| `sigil-hs/package.yaml` | Modify | Add WaveletMut to exposed-modules, add test module |
| `sigil-hs/server/Main.hs` | Modify | Add progress polling endpoint, wire `compressWithProgress` |
| `sigil-hs/static/index.html` | Modify | Replace spinner with progress bar + polling |
| `sigil-hs/test/Spec.hs` | Modify | Wire Test.WaveletMut |

---

### Task 1: Create WaveletMut Module — 1D Lifting

**Files:**
- Create: `sigil-hs/src/Sigil/Codec/WaveletMut.hs`
- Create: `sigil-hs/test/Test/WaveletMut.hs`
- Modify: `sigil-hs/package.yaml`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Add WaveletMut to package.yaml exposed-modules**

In `sigil-hs/package.yaml`, add `Sigil.Codec.WaveletMut` to the `exposed-modules` list (after `Sigil.Codec.Wavelet`), and add `Test.WaveletMut` to the test `other-modules` list (after `Test.Wavelet`).

- [ ] **Step 2: Create WaveletMut.hs with 1D forward/inverse lifting**

Create `sigil-hs/src/Sigil/Codec/WaveletMut.hs`:

```haskell
module Sigil.Codec.WaveletMut
  ( lift53Forward1DMut
  , lift53Inverse1DMut
  ) where

import Control.Monad (forM_)
import Control.Monad.ST (runST)
import Data.Int (Int32)
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM

-- | Forward 1D 5/3 lifting using mutable vectors.
-- Returns (approximation, detail) — same semantics as lift53Forward1D.
lift53Forward1DMut :: VU.Vector Int32 -> (VU.Vector Int32, VU.Vector Int32)
lift53Forward1DMut xs
  | n == 0    = (VU.empty, VU.empty)
  | n == 1    = (xs, VU.empty)
  | otherwise = runST $ do
      let nDetail = n `div` 2
          nApprox = (n + 1) `div` 2

      detail <- VUM.new nDetail
      approx <- VUM.new nApprox

      -- Step 1: Predict (detail coefficients)
      forM_ [0 .. nDetail - 1] $ \i -> do
        let left   = xs `VU.unsafeIndex` (2 * i)
            center = xs `VU.unsafeIndex` (2 * i + 1)
            right  = if 2 * i + 2 < n
                       then xs `VU.unsafeIndex` (2 * i + 2)
                       else xs `VU.unsafeIndex` (2 * i)  -- mirror
        VUM.unsafeWrite detail i (center - (left + right) `div` 2)

      -- Step 2: Update (approximation coefficients)
      detailFrozen <- VU.unsafeFreeze detail
      forM_ [0 .. nApprox - 1] $ \i -> do
        let dLeft  = if i > 0       then detailFrozen `VU.unsafeIndex` (i - 1)
                                    else detailFrozen `VU.unsafeIndex` 0
            dRight = if i < nDetail  then detailFrozen `VU.unsafeIndex` i
                                    else detailFrozen `VU.unsafeIndex` (nDetail - 1)
            even_  = xs `VU.unsafeIndex` (2 * i)
        VUM.unsafeWrite approx i (even_ + (dLeft + dRight + 2) `div` 4)

      approxFrozen <- VU.unsafeFreeze approx
      pure (approxFrozen, detailFrozen)
  where
    n = VU.length xs

-- | Inverse 1D 5/3 lifting using mutable vectors.
-- Same semantics as lift53Inverse1D.
lift53Inverse1DMut :: VU.Vector Int32 -> VU.Vector Int32 -> VU.Vector Int32
lift53Inverse1DMut approx detail
  | nApprox == 0 = VU.empty
  | nDetail == 0 = approx
  | otherwise = runST $ do
      let n = nApprox + nDetail

      evens  <- VUM.new nApprox
      result <- VUM.new n

      -- Step 1: Undo update (recover even samples)
      forM_ [0 .. nApprox - 1] $ \i -> do
        let dLeft  = if i > 0       then detail `VU.unsafeIndex` (i - 1)
                                    else detail `VU.unsafeIndex` 0
            dRight = if i < nDetail  then detail `VU.unsafeIndex` i
                                    else detail `VU.unsafeIndex` (nDetail - 1)
        VUM.unsafeWrite evens i (approx `VU.unsafeIndex` i - (dLeft + dRight + 2) `div` 4)

      evensFrozen <- VU.unsafeFreeze evens

      -- Step 2: Undo predict (interleave even/odd)
      forM_ [0 .. n - 1] $ \idx ->
        if even idx
          then VUM.unsafeWrite result idx (evensFrozen `VU.unsafeIndex` (idx `div` 2))
          else do
            let i     = idx `div` 2
                left  = evensFrozen `VU.unsafeIndex` i
                right = if 2 * i + 2 < n
                          then evensFrozen `VU.unsafeIndex` (i + 1)
                          else evensFrozen `VU.unsafeIndex` i  -- mirror
            VUM.unsafeWrite result idx (detail `VU.unsafeIndex` i + (left + right) `div` 2)

      VU.unsafeFreeze result
  where
    nApprox = VU.length approx
    nDetail = VU.length detail
```

- [ ] **Step 3: Create Test.WaveletMut with 1D equivalence tests**

Create `sigil-hs/test/Test/WaveletMut.hs`:

```haskell
module Test.WaveletMut (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Sigil.Codec.Wavelet (lift53Forward1D, lift53Inverse1D)
import Sigil.Codec.WaveletMut (lift53Forward1DMut, lift53Inverse1DMut)

-- Helpers to convert between boxed and unboxed
toBoxed :: VU.Vector Int32 -> V.Vector Int32
toBoxed = V.convert

spec :: Spec
spec = describe "WaveletMut" $ do
  describe "1D lift53 equivalence" $ do
    it "forward matches immutable for arbitrary vectors" $ property $
      forAll (choose (2, 64 :: Int)) $ \n ->
        forAll (vectorOf n (choose (-500, 500) :: Gen Int32)) $ \xs ->
          let v = V.fromList xs
              vu = VU.fromList xs
              (sRef, dRef) = lift53Forward1D v
              (sMut, dMut) = lift53Forward1DMut vu
          in toBoxed sMut === sRef .&&. toBoxed dMut === dRef

    it "inverse matches immutable for arbitrary vectors" $ property $
      forAll (choose (2, 64 :: Int)) $ \n ->
        forAll (vectorOf n (choose (-500, 500) :: Gen Int32)) $ \xs ->
          let v = V.fromList xs
              vu = VU.fromList xs
              (sRef, dRef) = lift53Forward1D v
              (sMut, dMut) = lift53Forward1DMut vu
              resultRef = lift53Inverse1D sRef dRef
              resultMut = lift53Inverse1DMut sMut dMut
          in toBoxed resultMut === resultRef

    it "round-trips length 1" $
      let v = VU.fromList [42 :: Int32]
          (s, d) = lift53Forward1DMut v
      in lift53Inverse1DMut s d `shouldBe` v

    it "round-trips length 2" $
      let v = VU.fromList [10, 20 :: Int32]
          (s, d) = lift53Forward1DMut v
      in lift53Inverse1DMut s d `shouldBe` v
```

- [ ] **Step 4: Wire Test.WaveletMut into Spec.hs**

In `sigil-hs/test/Spec.hs`:
- Add import: `import qualified Test.WaveletMut`
- In the `main` hspec block, after `Test.Serialize.spec`, add: `Test.WaveletMut.spec`

- [ ] **Step 5: Run tests to verify 1D equivalence passes**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All existing tests pass plus the new WaveletMut 1D tests pass.

- [ ] **Step 6: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/WaveletMut.hs sigil-hs/test/Test/WaveletMut.hs sigil-hs/package.yaml sigil-hs/test/Spec.hs
git commit -m "feat(sigil-hs): mutable 1D 5/3 lifting with equivalence tests"
```

---

### Task 2: Add 2D Forward/Inverse DWT to WaveletMut

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/WaveletMut.hs`
- Modify: `sigil-hs/test/Test/WaveletMut.hs`

- [ ] **Step 1: Write the failing 2D equivalence test**

Add to the imports in `Test/WaveletMut.hs`:

```haskell
import Sigil.Codec.Wavelet (lift53Forward1D, lift53Inverse1D, dwt2DForward, dwt2DInverse)
import Sigil.Codec.WaveletMut (lift53Forward1DMut, lift53Inverse1DMut, dwt2DForwardMut, dwt2DInverseMut)
```

Add after the 1D tests block:

```haskell
  describe "2D DWT equivalence" $ do
    it "forward matches immutable for arbitrary 2D arrays" $ property $
      forAll (choose (1, 16 :: Int)) $ \w ->
        forAll (choose (1, 16 :: Int)) $ \h ->
          forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
            let vRef = V.fromList xs
                vMut = VU.fromList xs
                (llRef, lhRef, hlRef, hhRef) = dwt2DForward w h vRef
                (llMut, lhMut, hlMut, hhMut) = dwt2DForwardMut w h vMut
            in conjoin
                 [ toBoxed llMut === llRef
                 , toBoxed lhMut === lhRef
                 , toBoxed hlMut === hlRef
                 , toBoxed hhMut === hhRef
                 ]

    it "round-trips arbitrary 2D arrays" $ property $
      forAll (choose (1, 16 :: Int)) $ \w ->
        forAll (choose (1, 16 :: Int)) $ \h ->
          forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
            let vu = VU.fromList xs
                (ll, lh, hl, hh) = dwt2DForwardMut w h vu
                result = dwt2DInverseMut w h (ll, lh, hl, hh)
            in result === vu
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sigil-hs && stack test 2>&1 | tail -10`

Expected: Compilation error — `dwt2DForwardMut` and `dwt2DInverseMut` not exported.

- [ ] **Step 3: Implement dwt2DForwardMut and dwt2DInverseMut**

Add `dwt2DForwardMut` and `dwt2DInverseMut` to the module export list.

Add after the 1D functions in `WaveletMut.hs`:

```haskell
------------------------------------------------------------------------
-- 2D separable DWT (mutable)
------------------------------------------------------------------------

-- | Forward 2D DWT using mutable arrays.
-- Same semantics as dwt2DForward.
dwt2DForwardMut :: Int -> Int -> VU.Vector Int32
                -> (VU.Vector Int32, VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)
dwt2DForwardMut w h arr
  | w <= 0 || h <= 0 = (VU.empty, VU.empty, VU.empty, VU.empty)
  | w == 1 && h == 1 = (arr, VU.empty, VU.empty, VU.empty)
  | otherwise = runST $ do
      let wLow  = (w + 1) `div` 2
          wHigh = w `div` 2
          hLow  = (h + 1) `div` 2
          hHigh = h `div` 2

      -- Buffer for row-transformed data
      rowBuf <- VUM.new (h * w)

      -- Step 1: Transform rows
      forM_ [0 .. h - 1] $ \y -> do
        let row = VU.generate w $ \x -> arr `VU.unsafeIndex` (y * w + x)
            (lo, hi) = lift53Forward1DMut row
        forM_ [0 .. wLow - 1] $ \x ->
          VUM.unsafeWrite rowBuf (y * w + x) (lo `VU.unsafeIndex` x)
        forM_ [0 .. wHigh - 1] $ \x ->
          VUM.unsafeWrite rowBuf (y * w + wLow + x) (hi `VU.unsafeIndex` x)

      rowFrozen <- VU.unsafeFreeze rowBuf

      -- Step 2: Transform columns
      colBuf <- VUM.new (h * w)

      forM_ [0 .. w - 1] $ \x -> do
        let col = VU.generate h $ \y -> rowFrozen `VU.unsafeIndex` (y * w + x)
            (lo, hi) = lift53Forward1DMut col
        forM_ [0 .. hLow - 1] $ \y ->
          VUM.unsafeWrite colBuf (y * w + x) (lo `VU.unsafeIndex` y)
        forM_ [0 .. hHigh - 1] $ \y ->
          VUM.unsafeWrite colBuf ((hLow + y) * w + x) (hi `VU.unsafeIndex` y)

      colFrozen <- VU.unsafeFreeze colBuf

      -- Step 3: Extract subbands
      let ll = VU.generate (hLow * wLow) $ \idx ->
                 let y = idx `div` wLow; x = idx `mod` wLow
                 in colFrozen `VU.unsafeIndex` (y * w + x)
          lh = VU.generate (hLow * wHigh) $ \idx ->
                 let y = idx `div` wHigh; x = idx `mod` wHigh
                 in colFrozen `VU.unsafeIndex` (y * w + wLow + x)
          hl = VU.generate (hHigh * wLow) $ \idx ->
                 let y = idx `div` wLow; x = idx `mod` wLow
                 in colFrozen `VU.unsafeIndex` ((hLow + y) * w + x)
          hh = VU.generate (hHigh * wHigh) $ \idx ->
                 let y = idx `div` wHigh; x = idx `mod` wHigh
                 in colFrozen `VU.unsafeIndex` ((hLow + y) * w + wLow + x)
      pure (ll, lh, hl, hh)

-- | Inverse 2D DWT using mutable arrays.
-- Same semantics as dwt2DInverse.
dwt2DInverseMut :: Int -> Int -> (VU.Vector Int32, VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)
                -> VU.Vector Int32
dwt2DInverseMut w h (ll, lh, hl, hh)
  | w <= 0 || h <= 0 = VU.empty
  | w == 1 && h == 1 = ll
  | otherwise = runST $ do
      let wLow  = (w + 1) `div` 2
          wHigh = w `div` 2
          hLow  = (h + 1) `div` 2
          hHigh = h `div` 2

      -- Step 1: Reassemble subbands into coefficient layout
      colBuf <- VUM.new (h * w)

      forM_ [0 .. hLow * wLow - 1] $ \idx -> do
        let y = idx `div` wLow; x = idx `mod` wLow
        VUM.unsafeWrite colBuf (y * w + x) (ll `VU.unsafeIndex` idx)
      forM_ [0 .. hLow * wHigh - 1] $ \idx -> do
        let y = idx `div` wHigh; x = idx `mod` wHigh
        VUM.unsafeWrite colBuf (y * w + wLow + x) (lh `VU.unsafeIndex` idx)
      forM_ [0 .. hHigh * wLow - 1] $ \idx -> do
        let y = idx `div` wLow; x = idx `mod` wLow
        VUM.unsafeWrite colBuf ((hLow + y) * w + x) (hl `VU.unsafeIndex` idx)
      forM_ [0 .. hHigh * wHigh - 1] $ \idx -> do
        let y = idx `div` wHigh; x = idx `mod` wHigh
        VUM.unsafeWrite colBuf ((hLow + y) * w + wLow + x) (hh `VU.unsafeIndex` idx)

      colLayout <- VU.unsafeFreeze colBuf

      -- Step 2: Inverse column transform
      rowBuf <- VUM.new (h * w)

      forM_ [0 .. w - 1] $ \x -> do
        let colLo = VU.generate hLow  $ \y -> colLayout `VU.unsafeIndex` (y * w + x)
            colHi = VU.generate hHigh $ \y -> colLayout `VU.unsafeIndex` ((hLow + y) * w + x)
            col = lift53Inverse1DMut colLo colHi
        forM_ [0 .. h - 1] $ \y ->
          VUM.unsafeWrite rowBuf (y * w + x) (col `VU.unsafeIndex` y)

      rowLayout <- VU.unsafeFreeze rowBuf

      -- Step 3: Inverse row transform
      result <- VUM.new (h * w)

      forM_ [0 .. h - 1] $ \y -> do
        let rowLo = VU.generate wLow  $ \i -> rowLayout `VU.unsafeIndex` (y * w + i)
            rowHi = VU.generate wHigh $ \i -> rowLayout `VU.unsafeIndex` (y * w + wLow + i)
            row = lift53Inverse1DMut rowLo rowHi
        forM_ [0 .. w - 1] $ \x ->
          VUM.unsafeWrite result (y * w + x) (row `VU.unsafeIndex` x)

      VU.unsafeFreeze result
```

- [ ] **Step 4: Run tests to verify 2D equivalence passes**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All tests pass including new 2D equivalence and round-trip tests.

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/WaveletMut.hs sigil-hs/test/Test/WaveletMut.hs
git commit -m "feat(sigil-hs): mutable 2D DWT forward/inverse with equivalence tests"
```

---

### Task 3: Add Multi-Level DWT to WaveletMut

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/WaveletMut.hs`
- Modify: `sigil-hs/test/Test/WaveletMut.hs`

- [ ] **Step 1: Write the failing multi-level equivalence test**

Update imports in `Test/WaveletMut.hs`:

```haskell
import Sigil.Codec.Wavelet (lift53Forward1D, lift53Inverse1D, dwt2DForward, dwt2DInverse,
                             dwtForwardMulti, dwtInverseMulti, computeLevels)
import Sigil.Codec.WaveletMut (lift53Forward1DMut, lift53Inverse1DMut,
                                dwt2DForwardMut, dwt2DInverseMut,
                                dwtForwardMultiMut, dwtInverseMultiMut)
```

Add after the 2D tests:

```haskell
  describe "Multi-level DWT equivalence" $ do
    it "forward matches immutable for arbitrary multi-level" $ property $
      forAll (choose (4, 16 :: Int)) $ \w ->
        forAll (choose (4, 16 :: Int)) $ \h ->
          let lvls = computeLevels w h
          in forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
               let vRef = V.fromList xs
                   vMut = VU.fromList xs
                   (llRef, bandsRef) = dwtForwardMulti lvls w h vRef
                   (llMut, bandsMut) = dwtForwardMultiMut lvls w h vMut
               in conjoin $
                    (toBoxed llMut === llRef) :
                    [ conjoin [ toBoxed lhM === lhR
                              , toBoxed hlM === hlR
                              , toBoxed hhM === hhR ]
                    | ((lhR, hlR, hhR), (lhM, hlM, hhM)) <- zip bandsRef bandsMut
                    ]

    it "round-trips arbitrary multi-level" $ property $
      forAll (choose (4, 16 :: Int)) $ \w ->
        forAll (choose (4, 16 :: Int)) $ \h ->
          let lvls = computeLevels w h
          in forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
               let vu = VU.fromList xs
                   (ll, bands) = dwtForwardMultiMut lvls w h vu
                   result = dwtInverseMultiMut lvls w h ll bands
               in result === vu
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sigil-hs && stack test 2>&1 | tail -10`

Expected: Compilation error — `dwtForwardMultiMut` and `dwtInverseMultiMut` not exported.

- [ ] **Step 3: Implement dwtForwardMultiMut and dwtInverseMultiMut**

Add `dwtForwardMultiMut` and `dwtInverseMultiMut` to the module export list.

Add after the 2D functions in `WaveletMut.hs`:

```haskell
------------------------------------------------------------------------
-- Multi-level DWT (mutable)
------------------------------------------------------------------------

-- | Forward multi-level DWT using mutable arrays.
-- Same semantics as dwtForwardMulti.
dwtForwardMultiMut :: Int -> Int -> Int -> VU.Vector Int32
                   -> (VU.Vector Int32, [(VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)])
dwtForwardMultiMut levels w h arr = go levels w h arr []
  where
    go 0 _ _ ll bands = (ll, bands)
    go n cw ch img bands =
      let (ll, lh, hl, hh) = dwt2DForwardMut cw ch img
          cw' = (cw + 1) `div` 2
          ch' = (ch + 1) `div` 2
      in go (n - 1) cw' ch' ll ((lh, hl, hh) : bands)

-- | Inverse multi-level DWT using mutable arrays.
-- Same semantics as dwtInverseMulti.
dwtInverseMultiMut :: Int -> Int -> Int -> VU.Vector Int32
                   -> [(VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)]
                   -> VU.Vector Int32
dwtInverseMultiMut levels w h ll bands = go levels sizes ll bands
  where
    sizes = reverse $ take levels $ iterate shrink (w, h)
    shrink (cw, ch) = ((cw + 1) `div` 2, (ch + 1) `div` 2)

    go _ [] currentLL [] = currentLL
    go _ ((cw, ch) : rest) currentLL ((lh, hl, hh) : restBands) =
      let reconstructed = dwt2DInverseMut cw ch (currentLL, lh, hl, hh)
      in go (levels - 1) rest reconstructed restBands
    go _ _ currentLL _ = currentLL
```

- [ ] **Step 4: Run tests to verify multi-level equivalence passes**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/WaveletMut.hs sigil-hs/test/Test/WaveletMut.hs
git commit -m "feat(sigil-hs): mutable multi-level DWT with equivalence tests"
```

---

### Task 4: Wire WaveletMut into Pipeline

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs`
- Modify: `sigil-hs/src/Sigil.hs`

- [ ] **Step 1: Run existing tests as baseline**

Run: `cd sigil-hs && stack test 2>&1 | tail -10`

Expected: All tests pass.

- [ ] **Step 2: Update Pipeline.hs imports**

In `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

Add this import:

```haskell
import qualified Data.Vector.Unboxed as VU
import Sigil.Codec.WaveletMut (dwtForwardMultiMut, dwtInverseMultiMut)
```

Change the Wavelet import to only import `computeLevels`:

```haskell
import Sigil.Codec.Wavelet (computeLevels)
```

- [ ] **Step 3: Update serializeChannel to use mutable DWT**

Replace `serializeChannel`:

```haskell
serializeChannel :: Int -> Int -> Int -> Vector Int32 -> ByteString
serializeChannel numLevels w h chan =
  let chanU = VU.convert chan :: VU.Vector Int32
      (finalLLU, levelsU) = dwtForwardMultiMut numLevels w h chanU
      finalLL = V.convert finalLLU :: Vector Int32
      levels = map (\(a,b,c) -> (V.convert a, V.convert b, V.convert c)) levelsU
  in serializeCoeffs finalLL levels
```

- [ ] **Step 4: Update serializeChannelVarint to use mutable DWT**

Replace `serializeChannelVarint`:

```haskell
serializeChannelVarint :: Int -> Int -> Int -> Vector Int32 -> ByteString
serializeChannelVarint numLevels w h chan =
  let chanU = VU.convert chan :: VU.Vector Int32
      (finalLLU, levelsU) = dwtForwardMultiMut numLevels w h chanU
      finalLL = V.convert finalLLU :: Vector Int32
      levels = map (\(a,b,c) -> (V.convert a, V.convert b, V.convert c)) levelsU
      levelSizes = computeLevelSizes numLevels w h
      (llW, llH) = case levelSizes of
                     [] -> (w, h)
                     ((lw, lh, _, _) : _) -> (lw, lh)
  in serializeCoeffsVarint llW llH finalLL levels
```

- [ ] **Step 5: Update deserializeChannel to use mutable DWT**

Replace `deserializeChannel`:

```haskell
deserializeChannel :: Int -> Int -> Int -> ByteString -> (Vector Int32, ByteString)
deserializeChannel numLevels w h bs =
  let (finalLL, levels, remaining) = deserializeCoeffs numLevels w h bs
      finalLLU = VU.convert finalLL :: VU.Vector Int32
      levelsU = map (\(a,b,c) -> (VU.convert a, VU.convert b, VU.convert c)) levels
      reconstructedU = dwtInverseMultiMut numLevels w h finalLLU levelsU
      reconstructed = V.convert reconstructedU :: Vector Int32
  in (reconstructed, remaining)
```

- [ ] **Step 6: Update deserializeChannelVarint to use mutable DWT**

Replace `deserializeChannelVarint`:

```haskell
deserializeChannelVarint :: Int -> Int -> Int -> ByteString -> (Vector Int32, ByteString)
deserializeChannelVarint numLevels w h bs =
  let (finalLL, levels, remaining) = deserializeCoeffsVarint numLevels w h bs
      finalLLU = VU.convert finalLL :: VU.Vector Int32
      levelsU = map (\(a,b,c) -> (VU.convert a, VU.convert b, VU.convert c)) levels
      reconstructedU = dwtInverseMultiMut numLevels w h finalLLU levelsU
      reconstructed = V.convert reconstructedU :: Vector Int32
  in (reconstructed, remaining)
```

- [ ] **Step 7: Update Sigil.hs to re-export WaveletMut**

In `sigil-hs/src/Sigil.hs`, add to the module export list:

```haskell
  , module Sigil.Codec.WaveletMut
```

And add the import:

```haskell
import Sigil.Codec.WaveletMut
```

- [ ] **Step 8: Run all tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All 44+ existing tests pass. Golden file conformance tests confirm byte-identical output.

- [ ] **Step 9: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Pipeline.hs sigil-hs/src/Sigil.hs
git commit -m "feat(sigil-hs): wire mutable DWT into pipeline"
```

---

### Task 5: Verify Sample Photo Encodes Successfully

**Files:** None — verification only.

- [ ] **Step 1: Build the CLI**

Run: `cd sigil-hs && stack build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 2: Encode the sample photo with memory stats**

Run: `cd sigil-hs && stack exec sigil-hs -- encode "../sample photos/krists-luhaers-xS_9-CLMZAQ-unsplash.jpg" -o /tmp/test-photo.sgl +RTS -s 2>&1`

Expected: Encoding completes. Peak memory (look for "maximum residency" in `+RTS -s` output) should be well under 500MB. Previously this caused 20GB+ memory and never finished.

- [ ] **Step 3: Verify round-trip**

Run: `cd sigil-hs && stack exec sigil-hs -- verify "../sample photos/krists-luhaers-xS_9-CLMZAQ-unsplash.jpg" 2>&1`

Expected: Lossless round-trip verification passes.

- [ ] **Step 4: Run Rust conformance tests**

Run: `cd sigil-rs && cargo test 2>&1 | tail -10`

Expected: All conformance tests pass (golden files unchanged).

---

### Task 6: Add compressWithProgress to Pipeline

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs`

- [ ] **Step 1: Add compressWithProgress and ProgressCallback to module exports**

Update the module declaration:

```haskell
module Sigil.Codec.Pipeline
  ( compress
  , decompress
  , compressWithProgress
  , ProgressCallback
  ) where
```

- [ ] **Step 2: Add Text import**

Add to the imports:

```haskell
import Data.Text (Text)
import qualified Data.Text as T
```

- [ ] **Step 3: Implement compressWithProgress**

Add after the existing `compress` function:

```haskell
-- | Progress callback: stage name, percentage (0-100), optional detail text.
type ProgressCallback = Text -> Int -> Maybe Text -> IO ()

-- | Compress with progress reporting.
-- Same output as compress, but calls the callback at each pipeline stage.
compressWithProgress :: ProgressCallback -> Header -> Image -> IO ByteString
compressWithProgress report hdr img = do
  let w  = fromIntegral (width hdr)  :: Int
      h  = fromIntegral (height hdr) :: Int
      ch = channels (colorSpace hdr)

  report "decoding" 0 Nothing
  let flat = V.concat (V.toList img)
      chanVecs = deinterleave flat ch

  report "color_transform" 10 Nothing
  let (useRCT, int32Channels) = toInt32Channels (colorSpace hdr) w h chanVecs
      numLevels = computeLevels w h
      numCh = length int32Channels
      -- DWT spans pct 15-80 (65 percentage points), distributed across channels
      pctPerChan = 65 `div` max 1 numCh

  -- DWT per channel with progress
  dwtResults <- sequence
    [ do let basePct = 15 + i * pctPerChan
             detail = Just $ T.pack $ "channel " ++ show (i + 1) ++ "/" ++ show numCh
         report "dwt" basePct detail
         let chanU = VU.convert c :: VU.Vector Int32
             (finalLLU, levelsU) = dwtForwardMultiMut numLevels w h chanU
             finalLL = V.convert finalLLU :: Vector Int32
             levels = map (\(a,b,c') -> (V.convert a, V.convert b, V.convert c')) levelsU
         -- Force evaluation so progress is meaningful
         finalLL `seq` levels `seq` pure (finalLL, levels)
    | (i, c) <- zip [0..] int32Channels
    ]

  report "serialize" 80 Nothing
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

  report "compress" 90 Nothing
  let compressed = BL.toStrict $ Z.compress $ BL.fromStrict coeffBytes
      ctByte = if useRCT then 1 else 0 :: Word8
      numChByte  = fromIntegral (length int32Channels) :: Word8
      result = BS.pack [fromIntegral numLevels, ctByte, numChByte] <> compressed

  report "done" 100 Nothing
  pure result
```

- [ ] **Step 4: Run tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -10`

Expected: All tests pass. Existing `compress` is unchanged.

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/Codec/Pipeline.hs
git commit -m "feat(sigil-hs): add compressWithProgress for pipeline progress reporting"
```

---

### Task 7: Add encodeSigilFileWithProgress to Writer

**Files:**
- Modify: `sigil-hs/src/Sigil/IO/Writer.hs`

The existing `encodeSigilFile` calls `compress` internally (pure). For progress, we need an `IO` variant that calls `compressWithProgress` instead.

- [ ] **Step 1: Add encodeSigilFileWithProgress to module exports**

Update module declaration:

```haskell
module Sigil.IO.Writer
  ( encodeSigilFile
  , encodeSigilFileWithProgress
  , writeSigilFile
  ) where
```

- [ ] **Step 2: Add import for compressWithProgress**

Add to imports:

```haskell
import Sigil.Codec.Pipeline (compress, compressWithProgress, ProgressCallback)
```

- [ ] **Step 3: Implement encodeSigilFileWithProgress**

Add after `encodeSigilFile`:

```haskell
-- | Like encodeSigilFile but with progress reporting.
-- Runs in IO because the progress callback requires it.
encodeSigilFileWithProgress :: ProgressCallback -> Header -> Metadata -> Image -> IO BL.ByteString
encodeSigilFileWithProgress report hdr meta img = do
  payload <- compressWithProgress report hdr img
  pure $ runPut $ do
    putByteString magic
    putWord8 versionMajor
    putWord8 versionMinor
    putChunk (makeChunk SHDR (encodeHeader hdr))
    if not (null (metaEntries meta))
      then putChunk (makeChunk SMTA (encodeMetadata meta))
      else pure ()
    putChunk (makeChunk SDAT payload)
    putChunk (makeChunk SEND BS.empty)
```

- [ ] **Step 4: Run tests**

Run: `cd sigil-hs && stack test 2>&1 | tail -10`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/src/Sigil/IO/Writer.hs
git commit -m "feat(sigil-hs): add encodeSigilFileWithProgress for IO progress reporting"
```

---

### Task 8: Add Progress Polling to Server

**Files:**
- Modify: `sigil-hs/server/Main.hs`
- Modify: `sigil-hs/package.yaml`

- [ ] **Step 1: Add server dependencies**

In `sigil-hs/package.yaml`, add to `sigil-server` dependencies:

```yaml
      - containers
```

(`containers` provides `Data.Map.Strict`. The `text` and `bytestring` deps are already listed.)

- [ ] **Step 2: Rewrite server/Main.hs**

Replace the entire contents of `sigil-hs/server/Main.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Network.Wai.Middleware.Cors (simpleCors)
import Network.Wai.Handler.Warp (setPort, setTimeout, defaultSettings)
import Network.HTTP.Types.Status (status400, status404)

import qualified Codec.Picture as JP
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.Map.Strict as Map
import Data.IORef

import Control.Concurrent (forkIO, threadDelay)

import Sigil.Core.Types
import Sigil.IO.Convert (dynamicToSigil)
import Sigil.IO.Writer (encodeSigilFileWithProgress)
import Sigil.Codec.Pipeline (ProgressCallback)

import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data ProgressState = ProgressState
  { psStage  :: !T.Text
  , psPct    :: !Int
  , psDetail :: !(Maybe T.Text)
  }

type SessionId = T.Text
type Sessions = IORef (Map.Map SessionId (IORef ProgressState))

progressToJson :: ProgressState -> BL.ByteString
progressToJson (ProgressState stage pct detail) =
  BL.fromStrict $ TE.encodeUtf8 $ T.concat
    [ "{\"stage\":\""
    , stage
    , "\",\"pct\":"
    , T.pack (show pct)
    , case detail of
        Nothing -> ""
        Just d  -> T.concat [",\"detail\":\"", d, "\""]
    , "}"
    ]

main :: IO ()
main = do
  port <- maybe 3000 id . (>>= readMaybe) <$> lookupEnv "PORT"
  putStrLn $ "sigil-server starting on port " ++ show port
  sessions <- newIORef Map.empty
  let opts = Options 0 (setPort port $ setTimeout 300 defaultSettings) False
  scottyOpts opts $ do
    middleware simpleCors

    get "/" $ do
      setHeader "Content-Type" "text/html"
      file "static/index.html"

    get "/index.html" $ do
      setHeader "Content-Type" "text/html"
      file "static/index.html"

    get "/sigil_wasm.js" $ do
      setHeader "Content-Type" "application/javascript"
      file "static/sigil_wasm.js"

    get "/sigil_wasm_bg.wasm" $ do
      setHeader "Content-Type" "application/wasm"
      file "static/sigil_wasm_bg.wasm"

    get "/health" $ do
      text "ok"

    -- Progress polling endpoint
    get "/api/progress/:sessionId" $ do
      sid <- captureParam "sessionId"
      sessionMap <- liftIO $ readIORef sessions
      case Map.lookup sid sessionMap of
        Nothing -> do
          status status404
          json ("{\"error\":\"session not found\"}" :: T.Text)
        Just ref -> do
          ps <- liftIO $ readIORef ref
          setHeader "Content-Type" "application/json"
          setHeader "Access-Control-Allow-Origin" "*"
          raw (progressToJson ps)

    post "/api/encode" $ do
      body' <- body
      sidHeader <- header "X-Session-Id"
      case JP.decodeImage (BL.toStrict body') of
        Left err -> do
          status status400
          text (TL.pack $ "Failed to decode image: " ++ err)
        Right dynImg ->
          case dynamicToSigil dynImg of
            Left err -> do
              status status400
              text (TL.pack $ "Failed to convert image: " ++ show err)
            Right (hdr, img) -> do
              -- Set up progress callback
              callback <- liftIO $ case sidHeader of
                Nothing -> pure ((\_ _ _ -> pure ()) :: ProgressCallback)
                Just sessionIdLazy -> do
                  let sessionId = TL.toStrict sessionIdLazy
                  ref <- newIORef (ProgressState "starting" 0 Nothing)
                  modifyIORef' sessions (Map.insert sessionId ref)
                  -- Clean up session after 5 minutes
                  _ <- forkIO $ do
                    threadDelay (5 * 60 * 1000000)
                    modifyIORef' sessions (Map.delete sessionId)
                  pure $ \stage pct detail ->
                    writeIORef ref (ProgressState stage pct detail)

              sglBytes <- liftIO $ encodeSigilFileWithProgress callback hdr emptyMetadata img
              let originalSize = rowBytes hdr * fromIntegral (height hdr)
                  compressedSize = fromIntegral (BL.length sglBytes) :: Int
                  ratio = fromIntegral originalSize / fromIntegral compressedSize :: Double
              setHeader "Content-Type" "application/octet-stream"
              setHeader "X-Sigil-Width" (TL.pack $ show $ width hdr)
              setHeader "X-Sigil-Height" (TL.pack $ show $ height hdr)
              setHeader "X-Sigil-Color-Space" (TL.pack $ show $ colorSpace hdr)
              setHeader "X-Sigil-Original-Size" (TL.pack $ show originalSize)
              setHeader "X-Sigil-Compressed-Size" (TL.pack $ show compressedSize)
              setHeader "X-Sigil-Ratio" (TL.pack $ show ratio)
              raw sglBytes
```

- [ ] **Step 3: Build to verify server compiles**

Run: `cd sigil-hs && stack build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add sigil-hs/server/Main.hs sigil-hs/package.yaml
git commit -m "feat(server): add progress polling endpoint with session management"
```

---

### Task 9: Update Frontend with Progress Bar

**Files:**
- Modify: `sigil-hs/static/index.html`

- [ ] **Step 1: Replace the loading section HTML**

In `sigil-hs/static/index.html`, replace the `#loading` div (lines 243-245):

```html
  <div id="loading">
    <div class="spinner"></div>
    <p>Compressing...</p>
  </div>
```

With:

```html
  <div id="loading">
    <div class="progress-container">
      <div class="progress-bar" id="progress-bar"></div>
    </div>
    <p id="progress-label">Starting...</p>
    <p id="progress-detail" style="margin-top: 0.3rem; font-size: 0.7rem; color: var(--text-dim); font-family: var(--mono);"></p>
  </div>
```

- [ ] **Step 2: Replace the spinner CSS with progress bar CSS**

Replace the `.spinner` and `@keyframes spin` CSS rules (lines 196-205):

```css
    .spinner {
      width: 24px; height: 24px;
      border: 2px solid var(--border);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
      margin: 0 auto 1rem;
    }

    @keyframes spin { to { transform: rotate(360deg); } }
```

With:

```css
    .progress-container {
      width: 100%;
      max-width: 400px;
      height: 4px;
      background: var(--border);
      border-radius: 2px;
      margin: 0 auto 1rem;
      overflow: hidden;
    }

    .progress-bar {
      height: 100%;
      width: 0%;
      background: var(--accent);
      border-radius: 2px;
      transition: width 0.3s ease;
    }
```

- [ ] **Step 3: Update the handleFile JavaScript function**

Replace the `handleFile` function (the `async function handleFile(file)` block) with:

```javascript
async function handleFile(file) {
  if (!file.type.match(/^image\/(png|jpeg|bmp)/) && !file.name.match(/\.(png|jpe?g|bmp)$/i)) {
    showError('Please select a PNG, JPEG, or BMP image.');
    return;
  }

  dropZone.style.display = 'none';
  error.classList.remove('visible');
  results.classList.remove('visible');
  loading.classList.add('visible');

  // Reset progress
  const progressBar = document.getElementById('progress-bar');
  const progressLabel = document.getElementById('progress-label');
  const progressDetail = document.getElementById('progress-detail');
  progressBar.style.width = '0%';
  progressLabel.textContent = 'Starting...';
  progressDetail.textContent = '';

  // Generate session ID for progress tracking
  const sessionId = crypto.randomUUID();

  // Start polling for progress
  const pollInterval = setInterval(async () => {
    try {
      const resp = await fetch('/api/progress/' + sessionId);
      if (resp.ok) {
        const data = await resp.json();
        progressBar.style.width = data.pct + '%';
        const stageNames = {
          'starting': 'Starting...',
          'decoding': 'Decoding image...',
          'color_transform': 'Color transform...',
          'dwt': 'Wavelet transform...',
          'serialize': 'Serializing...',
          'compress': 'Compressing...',
          'done': 'Done!'
        };
        progressLabel.textContent = stageNames[data.stage] || data.stage;
        progressDetail.textContent = data.detail || '';
      }
    } catch (e) { /* ignore polling errors */ }
  }, 200);

  try {
    const bytes = new Uint8Array(await file.arrayBuffer());

    document.getElementById('original-img').src = URL.createObjectURL(file);

    const resp = await fetch('/api/encode', {
      method: 'POST',
      body: bytes,
      headers: { 'X-Session-Id': sessionId }
    });

    clearInterval(pollInterval);

    if (!resp.ok) throw new Error(await resp.text());

    const sglBytes = new Uint8Array(await resp.arrayBuffer());

    const w = resp.headers.get('X-Sigil-Width');
    const h = resp.headers.get('X-Sigil-Height');
    const origSize = parseInt(resp.headers.get('X-Sigil-Original-Size'));
    const compSize = parseInt(resp.headers.get('X-Sigil-Compressed-Size'));
    const ratio = parseFloat(resp.headers.get('X-Sigil-Ratio'));

    if (wasmReady) {
      try {
        const result = decode(sglBytes);
        const canvas = document.getElementById('decoded-canvas');
        canvas.width = result.width;
        canvas.height = result.height;
        const ctx = canvas.getContext('2d');
        const rgb = result.pixels;
        const channels = result.colorSpace === 'rgba' ? 4 : 3;
        const rgba = new Uint8ClampedArray(result.width * result.height * 4);
        if (channels === 4) {
          rgba.set(rgb);
        } else {
          for (let i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
            rgba[j] = rgb[i]; rgba[j+1] = rgb[i+1]; rgba[j+2] = rgb[i+2]; rgba[j+3] = 255;
          }
        }
        ctx.putImageData(new ImageData(rgba, result.width, result.height), 0, 0);
      } catch (e) { console.warn('WASM decode failed:', e); }
    }

    document.getElementById('stat-dimensions').textContent = w + '\u2009\u00d7\u2009' + h;
    document.getElementById('stat-original').textContent = formatBytes(origSize);
    document.getElementById('stat-compressed').textContent = formatBytes(compSize);
    document.getElementById('stat-ratio').textContent = ratio.toFixed(1) + 'x';
    document.getElementById('original-size').textContent = formatBytes(file.size) + ' (file)';
    document.getElementById('decoded-size').textContent = formatBytes(compSize) + ' (.sgl)';

    const downloadBtn = document.getElementById('download-btn');
    downloadBtn.download = file.name.replace(/\.[^.]+$/, '') + '.sgl';
    downloadBtn.href = URL.createObjectURL(new Blob([sglBytes]));

    loading.classList.remove('visible');
    results.classList.add('visible');
  } catch (e) {
    clearInterval(pollInterval);
    loading.classList.remove('visible');
    showError(e.message || 'Compression failed.');
    dropZone.style.display = '';
  }
}
```

- [ ] **Step 4: Build and manually test**

Run: `cd sigil-hs && stack build 2>&1 | tail -5`

Then start the server: `cd sigil-hs && stack exec sigil-server`

Open `http://localhost:3000` in a browser, drop an image, and confirm:
- The progress bar advances through stages
- Stage labels update ("Decoding image...", "Wavelet transform...", etc.)
- Detail text shows "channel 1/3" etc. during DWT
- Results display correctly after completion

- [ ] **Step 5: Commit**

```bash
git add sigil-hs/static/index.html
git commit -m "feat(ui): replace spinner with progress bar and stage labels"
```

---

### Task 10: Final Integration Test

**Files:** None — verification only.

- [ ] **Step 1: Run full Haskell test suite**

Run: `cd sigil-hs && stack test 2>&1 | tail -30`

Expected: All tests pass (existing 44 + new WaveletMut equivalence tests).

- [ ] **Step 2: Run Rust conformance tests**

Run: `cd sigil-rs && cargo test 2>&1 | tail -10`

Expected: All conformance tests pass.

- [ ] **Step 3: Encode sample photo with memory stats**

Run: `cd sigil-hs && stack exec sigil-hs -- encode "../sample photos/krists-luhaers-xS_9-CLMZAQ-unsplash.jpg" -o /tmp/final-test.sgl +RTS -s 2>&1`

Expected: Completes successfully. Maximum residency well under 500MB.

- [ ] **Step 4: Verify sample photo round-trip**

Run: `cd sigil-hs && stack exec sigil-hs -- verify "../sample photos/krists-luhaers-xS_9-CLMZAQ-unsplash.jpg" 2>&1`

Expected: Lossless round-trip verification passes.

- [ ] **Step 5: Test web UI end-to-end**

Start server: `cd sigil-hs && stack exec sigil-server`

Open `http://localhost:3000`, drop the sample photo. Verify:
- Progress bar advances from 0% to 100%
- Stage labels show correct progression
- Encoding completes and results display
- WASM decode shows the reconstructed image
- Download button works
