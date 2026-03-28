# Sigil Haskell Reference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Sigil Haskell reference implementation — a working CLI that encodes/decodes images to the `.sgl` format with full property-based testing and benchmarks.

**Architecture:** Single Stack project with library (core types, codec pipeline with Category-based Stage composition, file I/O via binary/JuicyPixels), executable (CLI via optparse-applicative), test suite (hspec + QuickCheck), and criterion benchmarks. Images stored as `Vector (Vector Word8)` rows. Pipeline stages compose with `>>>`.

**Tech Stack:** Haskell, Stack (hpack), bytestring, vector, binary, JuicyPixels, optparse-applicative, QuickCheck, hspec, criterion

**Spec:** `docs/superpowers/specs/2026-03-25-sigil-hs-reference-design.md`

---

### Task 1: Project Scaffold & Stack Setup

**Files:**
- Create: `sigil-hs/package.yaml`
- Create: `sigil-hs/stack.yaml`
- Create: `sigil-hs/src/Sigil/Core/Types.hs`
- Create: `sigil-hs/src/Sigil/Core/Error.hs`
- Create: `sigil-hs/app/Main.hs`
- Create: `sigil-hs/test/Spec.hs`
- Create: `sigil-hs/bench/Main.hs`
- Create: `tests/corpus/.gitkeep`
- Create: `tests/corpus/expected/.gitkeep`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p sigil-hs/src/Sigil/Core
mkdir -p sigil-hs/src/Sigil/Codec
mkdir -p sigil-hs/src/Sigil/IO
mkdir -p sigil-hs/app
mkdir -p sigil-hs/test/Test
mkdir -p sigil-hs/bench
mkdir -p tests/corpus/expected
touch tests/corpus/.gitkeep
touch tests/corpus/expected/.gitkeep
```

- [ ] **Step 2: Write package.yaml and stack.yaml**

Create `sigil-hs/stack.yaml`:

```yaml
resolver: lts-22.43
packages:
  - .
```

Note: `resolver` pins the exact Stackage snapshot — every dependency version is locked. This guarantees reproducible builds. `lts-22.43` uses GHC 9.6.6. Stack will download this GHC automatically on first build.

Create `sigil-hs/package.yaml`:

```yaml
name: sigil-hs
version: 0.2.0.0
synopsis: Sigil image codec — Haskell reference implementation
license: MIT

default-extensions:
  - StrictData
  - OverloadedStrings

ghc-options:
  - -Wall
  - -O2

dependencies:
  - base >= 4.17 && < 5
  - bytestring >= 0.11
  - vector >= 0.13
  - binary >= 0.8
  - text >= 2.0

library:
  source-dirs: src
  exposed-modules:
    - Sigil
    - Sigil.Core.Types
    - Sigil.Core.Error
    - Sigil.Core.Chunk
    - Sigil.Codec.Predict
    - Sigil.Codec.ZigZag
    - Sigil.Codec.Token
    - Sigil.Codec.Rice
    - Sigil.Codec.Pipeline
    - Sigil.IO.Reader
    - Sigil.IO.Writer
    - Sigil.IO.Convert
  dependencies:
    - JuicyPixels >= 3.3
    - time >= 1.12
    - directory >= 1.3
    - filepath >= 1.4

executables:
  sigil-hs:
    source-dirs: app
    main: Main.hs
    dependencies:
      - sigil-hs
      - optparse-applicative >= 0.18
      - filepath
      - directory
      - time
      - JuicyPixels >= 3.3

tests:
  sigil-hs-test:
    source-dirs: test
    main: Spec.hs
    dependencies:
      - sigil-hs
      - hspec >= 2.11
      - QuickCheck >= 2.14
      - filepath
      - directory

benchmarks:
  sigil-hs-bench:
    source-dirs: bench
    main: Main.hs
    dependencies:
      - sigil-hs
      - criterion >= 1.6
      - deepseq
```

Note: `package.yaml` is hpack format — Stack auto-generates the `.cabal` file from it. Much cleaner YAML syntax vs raw cabal. `StrictData` makes all data type fields strict by default — no `!` bangs needed. `OverloadedStrings` lets string literals work as `ByteString` or `Text`. Shared `dependencies` at the top level are inherited by all components.

- [ ] **Step 3: Write minimal source files so stack can build**

Create `sigil-hs/src/Sigil/Core/Types.hs`:

```haskell
module Sigil.Core.Types
  ( ColorSpace(..)
  , BitDepth(..)
  , PredictorId(..)
  , Header(..)
  , Row
  , Image
  , Metadata(..)
  , channels
  , bytesPerChannel
  , rowBytes
  , emptyMetadata
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Word (Word8, Word32)

-- | A row of interleaved channel samples: [r,g,b, r,g,b, ...]
type Row = Vector Word8

-- | An image is a vector of rows.
type Image = Vector Row

data ColorSpace
  = Grayscale       -- ^ 1 channel
  | GrayscaleAlpha  -- ^ 2 channels
  | RGB             -- ^ 3 channels
  | RGBA            -- ^ 4 channels
  deriving (Eq, Show, Enum, Bounded)

data BitDepth
  = Depth8          -- ^ 8 bits per channel
  | Depth16         -- ^ 16 bits per channel
  deriving (Eq, Show, Enum, Bounded)

data PredictorId
  = PNone           -- ^ 0: no prediction
  | PSub            -- ^ 1: left neighbor
  | PUp             -- ^ 2: above neighbor
  | PAverage        -- ^ 3: average of left and above
  | PPaeth          -- ^ 4: Paeth predictor
  | PGradient       -- ^ 5: clamped gradient
  | PAdaptive       -- ^ 6: per-row optimal
  deriving (Eq, Show, Enum, Bounded)

data Header = Header
  { width      :: Word32
  , height     :: Word32
  , colorSpace :: ColorSpace
  , bitDepth   :: BitDepth
  , predictor  :: PredictorId
  } deriving (Eq, Show)

data Metadata = Metadata
  { metaEntries :: [(Text, ByteString)]
  } deriving (Eq, Show)

channels :: ColorSpace -> Int
channels Grayscale      = 1
channels GrayscaleAlpha = 2
channels RGB            = 3
channels RGBA           = 4

bytesPerChannel :: BitDepth -> Int
bytesPerChannel Depth8  = 1
bytesPerChannel Depth16 = 2

rowBytes :: Header -> Int
rowBytes hdr =
  fromIntegral (width hdr) * channels (colorSpace hdr) * bytesPerChannel (bitDepth hdr)

emptyMetadata :: Metadata
emptyMetadata = Metadata []
```

Create `sigil-hs/src/Sigil/Core/Error.hs`:

```haskell
module Sigil.Core.Error
  ( SigilError(..)
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word8, Word32)

data SigilError
  = InvalidMagic ByteString
  | UnsupportedVersion Word8 Word8
  | CrcMismatch { expected :: Word32, actual :: Word32 }
  | InvalidPredictor Word8
  | TruncatedInput
  | InvalidDimensions Word32 Word32
  | InvalidColorSpace Word8
  | InvalidBitDepth Word8
  | InvalidTag ByteString
  | MissingChunk String
  | IoError String
  deriving (Show, Eq)
```

Create stub modules so stack doesn't error on missing modules. Each of these will be filled in later tasks:

Create `sigil-hs/src/Sigil/Core/Chunk.hs`:

```haskell
module Sigil.Core.Chunk where
```

Create `sigil-hs/src/Sigil/Codec/Predict.hs`:

```haskell
module Sigil.Codec.Predict where
```

Create `sigil-hs/src/Sigil/Codec/ZigZag.hs`:

```haskell
module Sigil.Codec.ZigZag where
```

Create `sigil-hs/src/Sigil/Codec/Token.hs`:

```haskell
module Sigil.Codec.Token where
```

Create `sigil-hs/src/Sigil/Codec/Rice.hs`:

```haskell
module Sigil.Codec.Rice where
```

Create `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

```haskell
module Sigil.Codec.Pipeline where
```

Create `sigil-hs/src/Sigil/IO/Reader.hs`:

```haskell
module Sigil.IO.Reader where
```

Create `sigil-hs/src/Sigil/IO/Writer.hs`:

```haskell
module Sigil.IO.Writer where
```

Create `sigil-hs/src/Sigil/IO/Convert.hs`:

```haskell
module Sigil.IO.Convert where
```

Create `sigil-hs/src/Sigil.hs`:

```haskell
module Sigil
  ( module Sigil.Core.Types
  , module Sigil.Core.Error
  ) where

import Sigil.Core.Types
import Sigil.Core.Error
```

Create `sigil-hs/app/Main.hs`:

```haskell
module Main where

main :: IO ()
main = putStrLn "sigil-hs: not yet implemented"
```

Create `sigil-hs/test/Spec.hs`:

```haskell
module Main where

main :: IO ()
main = putStrLn "Tests not yet implemented"
```

Create `sigil-hs/bench/Main.hs`:

```haskell
module Main where

main :: IO ()
main = putStrLn "Benchmarks not yet implemented"
```

- [ ] **Step 4: Build the project to verify setup**

```bash
cd sigil-hs && stack build
```

Expected: Stack downloads GHC 9.6.6 (first time only), resolves dependencies, successful build. The `.cabal` file is auto-generated from `package.yaml` by hpack — add it to `.gitignore`.

- [ ] **Step 5: Run the executable to verify it works**

```bash
stack run
```

Expected: prints `sigil-hs: not yet implemented`

- [ ] **Step 6: Initialize git and commit**

```bash
cd .. && git init
git add sigil-hs/ tests/
git commit -m "feat: scaffold sigil-hs stack project with core types"
```

---

### Task 2: ZigZag Encoding (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/ZigZag.hs`
- Create: `sigil-hs/test/Test/ZigZag.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Set up hspec test runner**

Replace `sigil-hs/test/Spec.hs`:

```haskell
module Main where

import Test.Hspec

import qualified Test.ZigZag

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
```

- [ ] **Step 2: Write the failing tests**

Create `sigil-hs/test/Test/ZigZag.hs`:

```haskell
module Test.ZigZag (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int16)
import Data.Word (Word16)

import Sigil.Codec.ZigZag (zigzag, unzigzag)

spec :: Spec
spec = describe "ZigZag" $ do
  it "maps 0 -> 0" $
    zigzag 0 `shouldBe` (0 :: Word16)

  it "maps -1 -> 1" $
    zigzag (-1) `shouldBe` 1

  it "maps 1 -> 2" $
    zigzag 1 `shouldBe` 2

  it "maps -2 -> 3" $
    zigzag (-2) `shouldBe` 3

  it "maps 2 -> 4" $
    zigzag 2 `shouldBe` 4

  it "round-trips all values in [-255, 255]" $ property $
    \n -> (n :: Int16) >= -255 && n <= 255 ==>
      unzigzag (zigzag n) == n

  it "produces non-negative output" $ property $
    \n -> (n :: Int16) >= -255 && n <= 255 ==>
      zigzag n >= (0 :: Word16)

  it "is monotonic on absolute value" $ property $
    \a b -> let a' = abs (a :: Int16) `mod` 256
                b' = abs (b :: Int16) `mod` 256
            in a' < b' ==> zigzag a' < zigzag b'
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd sigil-hs && stack test
```

Expected: compilation error — `zigzag` and `unzigzag` not exported from `Sigil.Codec.ZigZag`.

- [ ] **Step 4: Implement zigzag**

Replace `sigil-hs/src/Sigil/Codec/ZigZag.hs`:

```haskell
module Sigil.Codec.ZigZag
  ( zigzag
  , unzigzag
  ) where

import Data.Bits ((.&.), xor, shiftL, shiftR)
import Data.Int (Int16)
import Data.Word (Word16)

-- | Map signed residual to unsigned via zig-zag encoding.
-- 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, 2 -> 4, ...
zigzag :: Int16 -> Word16
zigzag n = fromIntegral ((n `shiftL` 1) `xor` (n `shiftR` 15))

-- | Inverse of zigzag.
unzigzag :: Word16 -> Int16
unzigzag n = fromIntegral ((n `shiftR` 1) `xor` negate (n .&. 1))
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
stack test
```

Expected: all ZigZag tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: zigzag encoding with property tests"
```

---

### Task 3: Predictors (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Predict.hs`
- Create: `sigil-hs/test/Test/Predict.hs`
- Create: `sigil-hs/test/Gen.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write QuickCheck generators**

Create `sigil-hs/test/Gen.hs`:

```haskell
module Gen
  ( arbitraryPixel
  , arbitraryRow
  , arbitraryImage
  , arbitraryFixedPredictor
  ) where

import Test.QuickCheck

import Data.Word (Word8, Word32)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types (PredictorId(..), Header(..), ColorSpace(..), BitDepth(..), Image, Row)

arbitraryPixel :: Gen Word8
arbitraryPixel = arbitrary

arbitraryRow :: Int -> Gen Row
arbitraryRow len = V.fromList <$> vectorOf len arbitraryPixel

arbitraryImage :: Word32 -> Word32 -> Int -> Gen Image
arbitraryImage w h ch =
  let rowLen = fromIntegral w * ch
  in V.fromList <$> vectorOf (fromIntegral h) (arbitraryRow rowLen)

-- | Only fixed predictors (not PAdaptive)
arbitraryFixedPredictor :: Gen PredictorId
arbitraryFixedPredictor = elements [PNone, PSub, PUp, PAverage, PPaeth, PGradient]
```

- [ ] **Step 2: Write the failing predictor tests**

Create `sigil-hs/test/Test/Predict.hs`:

```haskell
module Test.Predict (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int16)
import Data.Word (Word8)
import qualified Data.Vector as V

import Sigil.Codec.Predict
  ( predict, residual, paeth
  , predictRow, unpredictRow
  , predictImage, unpredictImage
  )
import Sigil.Core.Types
import Gen (arbitraryFixedPredictor, arbitraryImage)

spec :: Spec
spec = describe "Predict" $ do
  describe "individual predictors" $ do
    it "PNone always predicts 0" $ property $
      \a b c -> predict PNone a b (c :: Word8) == (0 :: Word8)

    it "PSub predicts left neighbor" $ property $
      \a b c -> predict PSub a b (c :: Word8) == a

    it "PUp predicts above neighbor" $ property $
      \a b c -> predict PUp a b (c :: Word8) == b

    it "PAverage predicts average of left and above" $ property $
      \a b c -> predict PAverage a b (c :: Word8) ==
        fromIntegral ((fromIntegral a + fromIntegral b :: Int) `div` 2)

  describe "residual law" $ do
    it "predict + residual == original for all fixed predictors" $ property $
      forAll arbitraryFixedPredictor $ \pid ->
        \a b c x ->
          let r = residual pid a b (c :: Word8) (x :: Word8)
          in fromIntegral (predict pid a b c) + r == fromIntegral x

  describe "row round-trip" $ do
    it "unpredictRow . predictRow == identity" $ property $
      forAll arbitraryFixedPredictor $ \pid ->
        forAll (choose (1 :: Int, 20)) $ \rowLen ->
          forAll (V.fromList <$> vectorOf rowLen (arbitrary :: Gen Word8)) $ \row ->
            let prevRow = V.replicate rowLen 0
                ch = 1
                residuals = predictRow pid prevRow row ch
                recovered = unpredictRow pid prevRow residuals ch
            in recovered == row

  describe "image round-trip" $ do
    it "unpredictImage . predictImage == identity for fixed predictors" $ property $
      forAll arbitraryFixedPredictor $ \pid ->
        forAll (choose (1, 8)) $ \w ->
          forAll (choose (1, 8)) $ \h ->
            forAll (arbitraryImage w h 3) $ \img ->
              let hdr = Header w h RGB Depth8 pid
                  (pids, residuals) = predictImage hdr img
                  recovered = unpredictImage hdr (pids, residuals)
              in recovered == img

  describe "adaptive" $ do
    it "adaptive picks the predictor with lowest cost" $ property $
      forAll (choose (3, 30)) $ \rowLen ->
        forAll (V.fromList <$> vectorOf rowLen (arbitrary :: Gen Word8)) $ \row ->
          forAll (V.fromList <$> vectorOf rowLen (arbitrary :: Gen Word8)) $ \prevRow ->
            let ch = 1
                (_, adaptiveResiduals) = adaptiveRow prevRow row ch
                fixedCost pid =
                  let rs = predictRow pid prevRow row ch
                  in sum (fmap (fromIntegral . abs) rs :: V.Vector Int)
                adaptiveCost = sum (fmap (fromIntegral . abs) adaptiveResiduals :: V.Vector Int)
                bestFixedCost = minimum [fixedCost pid | pid <- [PNone .. PGradient]]
            in adaptiveCost <= bestFixedCost
```

- [ ] **Step 3: Add Predict tests to test runner**

Update `sigil-hs/test/Spec.hs`:

```haskell
module Main where

import Test.Hspec

import qualified Test.ZigZag
import qualified Test.Predict

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
  Test.Predict.spec
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd sigil-hs && stack test
```

Expected: compilation error — `predict`, `residual`, etc. not exported.

- [ ] **Step 5: Implement predictors**

Replace `sigil-hs/src/Sigil/Codec/Predict.hs`:

```haskell
module Sigil.Codec.Predict
  ( predict
  , residual
  , paeth
  , predictRow
  , unpredictRow
  , predictImage
  , unpredictImage
  , adaptiveRow
  ) where

import Data.Int (Int16)
import Data.Word (Word8)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types

-- | Predict a single sample given left (a), above (b), above-left (c).
predict :: PredictorId -> Word8 -> Word8 -> Word8 -> Word8
predict PNone     _ _ _ = 0
predict PSub      a _ _ = a
predict PUp       _ b _ = b
predict PAverage  a b _ = fromIntegral ((fromIntegral a + fromIntegral b :: Int) `div` 2)
predict PPaeth    a b c = paeth a b c
predict PGradient a b c = fromIntegral (clamp (fromIntegral a + fromIntegral b - fromIntegral c :: Int))
predict PAdaptive _ _ _ = error "adaptive is resolved per-row, not per-sample"

paeth :: Word8 -> Word8 -> Word8 -> Word8
paeth a b c =
  let p  = fromIntegral a + fromIntegral b - fromIntegral c :: Int
      pa = abs (p - fromIntegral a)
      pb = abs (p - fromIntegral b)
      pc = abs (p - fromIntegral c)
  in if pa <= pb && pa <= pc then a
     else if pb <= pc then b
     else c

clamp :: Int -> Int
clamp = max 0 . min 255

residual :: PredictorId -> Word8 -> Word8 -> Word8 -> Word8 -> Int16
residual pid a b c x = fromIntegral x - fromIntegral (predict pid a b c)

-- | Get the left neighbor (ch positions back) or 0 if at row start.
leftNeighbor :: Vector Word8 -> Int -> Int -> Word8
leftNeighbor row ch i = if i >= ch then row V.! (i - ch) else 0

-- | Predict an entire row, producing signed residuals.
predictRow :: PredictorId -> Vector Word8 -> Vector Word8 -> Int -> Vector Int16
predictRow pid prevRow curRow ch = V.imap go curRow
  where
    go i x =
      let a = leftNeighbor curRow ch i
          b = prevRow V.! i
          c = leftNeighbor prevRow ch i
      in residual pid a b c x

-- | Inverse of predictRow: reconstruct pixels from residuals.
-- We must build left-to-right since each pixel depends on the previous.
unpredictRow :: PredictorId -> Vector Word8 -> Vector Int16 -> Int -> Vector Word8
unpredictRow pid prevRow residuals ch =
  V.unfoldrExactN (V.length residuals) go (0, V.empty)
  where
    go (i, built) =
      let a = if i >= ch then built V.! (i - ch) else 0
          b = prevRow V.! i
          c = if i >= ch then prevRow V.! (i - ch) else 0
          predicted = predict pid a b c
          x = fromIntegral (fromIntegral predicted + (residuals V.! i) :: Int16) :: Word8
      in (x, (i + 1, V.snoc built x))

-- | Predict all rows of an image. Returns per-row predictor IDs and residuals.
predictImage :: Header -> Image -> (Vector PredictorId, Vector (Vector Int16))
predictImage hdr img
  | predictor hdr == PAdaptive = adaptiveImage img ch
  | otherwise =
      let pid = predictor hdr
          zeroRow = V.replicate (rowBytes hdr) 0
          residuals = V.imap (\i row ->
            let prev = if i == 0 then zeroRow else img V.! (i - 1)
            in predictRow pid prev row ch) img
          pids = V.replicate (V.length img) pid
      in (pids, residuals)
  where
    ch = channels (colorSpace hdr)

-- | Inverse: reconstruct image from predictor IDs and residuals.
unpredictImage :: Header -> (Vector PredictorId, Vector (Vector Int16)) -> Image
unpredictImage hdr (pids, residuals) =
  V.unfoldrExactN (V.length residuals) go (0, V.empty)
  where
    ch = channels (colorSpace hdr)
    rowLen = rowBytes hdr
    go (i, prevRows) =
      let prevRow = if i == 0 then V.replicate rowLen 0 else prevRows V.! (i - 1)
          pid = pids V.! i
          row = unpredictRow pid prevRow (residuals V.! i) ch
      in (row, (i + 1, V.snoc prevRows row))

-- | Try all fixed predictors on a row, pick the best.
adaptiveRow :: Vector Word8 -> Vector Word8 -> Int -> (PredictorId, Vector Int16)
adaptiveRow prevRow curRow ch =
  let candidates =
        [ (pid, predictRow pid prevRow curRow ch)
        | pid <- [PNone .. PGradient]
        ]
      cost rs = V.sum (V.map (fromIntegral . abs) rs :: Vector Int)
  in minimumBy (\(_, a) (_, b) -> compare (cost a) (cost b)) candidates

-- | Adaptive prediction for the whole image.
adaptiveImage :: Image -> Int -> (Vector PredictorId, Vector (Vector Int16))
adaptiveImage img ch =
  let rowLen = if V.null img then 0 else V.length (V.head img)
      zeroRow = V.replicate rowLen 0
      results = V.imap (\i row ->
        let prev = if i == 0 then zeroRow else img V.! (i - 1)
        in adaptiveRow prev row ch) img
  in (V.map fst results, V.map snd results)

```

Wait — I'm making this messy with inline edits. Let me write the clean final version:

```haskell
module Sigil.Codec.Predict
  ( predict
  , residual
  , paeth
  , predictRow
  , unpredictRow
  , predictImage
  , unpredictImage
  , adaptiveRow
  ) where

import Data.Int (Int16)
import Data.List (minimumBy)
import Data.Ord (comparing)
import Data.Word (Word8)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types

predict :: PredictorId -> Word8 -> Word8 -> Word8 -> Word8
predict PNone     _ _ _ = 0
predict PSub      a _ _ = a
predict PUp       _ b _ = b
predict PAverage  a b _ = fromIntegral ((fromIntegral a + fromIntegral b :: Int) `div` 2)
predict PPaeth    a b c = paeth a b c
predict PGradient a b c = fromIntegral $ max 0 $ min 255
                            (fromIntegral a + fromIntegral b - fromIntegral c :: Int)
predict PAdaptive _ _ _ = error "adaptive is resolved per-row"

paeth :: Word8 -> Word8 -> Word8 -> Word8
paeth a b c =
  let p  = fromIntegral a + fromIntegral b - fromIntegral c :: Int
      pa = abs (p - fromIntegral a)
      pb = abs (p - fromIntegral b)
      pc = abs (p - fromIntegral c)
  in if pa <= pb && pa <= pc then a
     else if pb <= pc then b
     else c

residual :: PredictorId -> Word8 -> Word8 -> Word8 -> Word8 -> Int16
residual pid a b c x = fromIntegral x - fromIntegral (predict pid a b c)

predictRow :: PredictorId -> Vector Word8 -> Vector Word8 -> Int -> Vector Int16
predictRow pid prevRow curRow ch = V.imap go curRow
  where
    go i x =
      let a = if i >= ch then curRow V.! (i - ch) else 0
          b = prevRow V.! i
          c = if i >= ch then prevRow V.! (i - ch) else 0
      in residual pid a b c x

unpredictRow :: PredictorId -> Vector Word8 -> Vector Int16 -> Int -> Vector Word8
unpredictRow pid prevRow residuals ch =
  V.unfoldrExactN (V.length residuals) step (0, V.empty)
  where
    step (i, built) =
      let a = if i >= ch then built V.! (i - ch) else 0
          b = prevRow V.! i
          c = if i >= ch then prevRow V.! (i - ch) else 0
          predicted = predict pid a b c
          x = fromIntegral (fromIntegral predicted + (residuals V.! i) :: Int16) :: Word8
      in (x, (i + 1, V.snoc built x))

predictImage :: Header -> Image -> (Vector PredictorId, Vector (Vector Int16))
predictImage hdr img
  | predictor hdr == PAdaptive =
      let results = V.imap (\i row ->
            let prev = if i == 0 then zeroRow else img V.! (i - 1)
            in adaptiveRow prev row ch) img
      in (V.map fst results, V.map snd results)
  | otherwise =
      let pid = predictor hdr
          residuals = V.imap (\i row ->
            let prev = if i == 0 then zeroRow else img V.! (i - 1)
            in predictRow pid prev row ch) img
      in (V.replicate (V.length img) pid, residuals)
  where
    ch = channels (colorSpace hdr)
    rl = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
    zeroRow = V.replicate rl 0

unpredictImage :: Header -> (Vector PredictorId, Vector (Vector Int16)) -> Image
unpredictImage hdr (pids, residuals) =
  V.unfoldrExactN (V.length residuals) step (0, V.empty)
  where
    ch = channels (colorSpace hdr)
    rl = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
    zeroRow = V.replicate rl 0
    step (i, prevRows) =
      let prevRow = if i == 0 then zeroRow else prevRows V.! (i - 1)
          row = unpredictRow (pids V.! i) prevRow (residuals V.! i) ch
      in (row, (i + 1, V.snoc prevRows row))

adaptiveRow :: Vector Word8 -> Vector Word8 -> Int -> (PredictorId, Vector Int16)
adaptiveRow prevRow curRow ch =
  minimumBy (comparing cost) candidates
  where
    candidates =
      [ (pid, predictRow pid prevRow curRow ch)
      | pid <- [PNone .. PGradient]
      ]
    cost (_, rs) = V.sum (V.map (fromIntegral . abs) rs :: Vector Int)
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
stack test
```

Expected: all ZigZag and Predict tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: predictors with adaptive selection and property tests"
```

---

### Task 4: Token (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Token.hs`
- Create: `sigil-hs/test/Test/Token.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write failing tests**

Create `sigil-hs/test/Test/Token.hs`:

```haskell
module Test.Token (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word16)
import qualified Data.Vector as V

import Sigil.Codec.Token (Token(..), tokenize, untokenize)

spec :: Spec
spec = describe "Token" $ do
  it "tokenizes all-zero vector as single ZeroRun" $ do
    tokenize (V.replicate 10 0) `shouldBe` [TZeroRun 10]

  it "tokenizes non-zero values as TValue" $ do
    tokenize (V.fromList [3, 5]) `shouldBe` [TValue 3, TValue 5]

  it "tokenizes mixed: zeros then value" $ do
    tokenize (V.fromList [0, 0, 0, 7]) `shouldBe` [TZeroRun 3, TValue 7]

  it "tokenizes value then zeros" $ do
    tokenize (V.fromList [4, 0, 0]) `shouldBe` [TValue 4, TZeroRun 2]

  it "handles empty input" $ do
    tokenize V.empty `shouldBe` []

  it "round-trips any Word16 vector" $ property $
    \xs -> let v = V.fromList (xs :: [Word16])
           in untokenize (tokenize v) == v
```

- [ ] **Step 2: Add to test runner**

Update `sigil-hs/test/Spec.hs` to add:

```haskell
import qualified Test.Token
-- and in main:
  Test.Token.spec
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
stack test
```

Expected: compilation error — `Token`, `tokenize`, `untokenize` not defined.

- [ ] **Step 4: Implement Token**

Replace `sigil-hs/src/Sigil/Codec/Token.hs`:

```haskell
module Sigil.Codec.Token
  ( Token(..)
  , tokenize
  , untokenize
  ) where

import Data.Word (Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

data Token
  = TZeroRun Word16
  | TValue Word16
  deriving (Eq, Show)

tokenize :: Vector Word16 -> [Token]
tokenize v = go 0
  where
    len = V.length v
    go i
      | i >= len = []
      | v V.! i == 0 =
          let n = countZerosFrom i
          in TZeroRun (fromIntegral n) : go (i + n)
      | otherwise =
          TValue (v V.! i) : go (i + 1)
    countZerosFrom start = length $ takeWhile id
      [ j < len && v V.! j == 0 && j - start < fromIntegral (maxBound :: Word16)
      | j <- [start..len - 1]
      ]

untokenize :: [Token] -> Vector Word16
untokenize tokens = V.fromList $ concatMap expand tokens
  where
    expand (TZeroRun n) = replicate (fromIntegral n) 0
    expand (TValue x)   = [x]
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
stack test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: token RLE with round-trip property tests"
```

---

### Task 5: Rice-Golomb Coding (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Rice.hs`
- Create: `sigil-hs/test/Test/Rice.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write failing tests**

Create `sigil-hs/test/Test/Rice.hs`:

```haskell
module Test.Rice (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word16, Word8)
import qualified Data.ByteString as BS

import Sigil.Codec.Rice
  ( BitWriter, BitReader
  , newBitWriter, writeBit, flushBits
  , newBitReader, readBit
  , riceEncode, riceDecode
  , optimalK
  , encodeTokens, decodeTokens
  , blockSize
  )
import Sigil.Codec.Token (Token(..), tokenize)

spec :: Spec
spec = describe "Rice" $ do
  describe "BitWriter/BitReader" $ do
    it "round-trips individual bits" $ do
      let bs = flushBits $ foldl (\w b -> writeBit b w) newBitWriter
                 [True, False, True, True, False, False, True, False]
          -- 10110010 = 0xB2
      BS.length bs `shouldBe` 1
      BS.index bs 0 `shouldBe` 0xB2

  describe "Rice coding" $ do
    it "round-trips value 0 with k=0" $ do
      let encoded = flushBits $ riceEncode 0 0 newBitWriter
          (val, _) = riceDecode 0 (newBitReader encoded)
      val `shouldBe` 0

    it "round-trips value 5 with k=2" $ do
      let encoded = flushBits $ riceEncode 2 5 newBitWriter
          (val, _) = riceDecode 2 (newBitReader encoded)
      val `shouldBe` 5

    it "round-trips any value with any k" $ property $
      \k' val' ->
        let k = (k' :: Word8) `mod` 9    -- k in [0,8]
            val = (val' :: Word16) `mod` 4096
            encoded = flushBits $ riceEncode k val newBitWriter
            (decoded, _) = riceDecode k (newBitReader encoded)
        in decoded == val

  describe "optimal k" $ do
    it "selects k=0 for all-zero block" $ do
      optimalK (replicate 64 0) `shouldBe` 0

    it "selects higher k for larger values" $ do
      let block = replicate 64 255
      optimalK block `shouldSatisfy` (> 0)

  describe "token stream" $ do
    it "round-trips a token stream" $ property $
      \xs -> let vals = map (\x -> (x :: Word16) `mod` 512) xs
                 tokens = tokenize (V.fromList vals)
                 encoded = encodeTokens tokens
                 decoded = decodeTokens encoded (length vals)
             in decoded == tokens
```

Wait — the token stream encoding includes the block structure with k values. Let me simplify the test interface. The `encodeTokens`/`decodeTokens` API needs to handle the full SDAT encoding including per-block k.

Let me revise:

```haskell
module Test.Rice (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word16, Word8)
import qualified Data.ByteString as BS
import qualified Data.Vector as V

import Sigil.Codec.Rice

spec :: Spec
spec = describe "Rice" $ do
  describe "BitWriter/BitReader" $ do
    it "round-trips 8 bits as one byte" $ do
      let bits = [True, False, True, True, False, False, True, False]
          bs = flushBits $ foldr (flip writeBit) newBitWriter bits
      BS.length bs `shouldBe` 1
      BS.index bs 0 `shouldBe` 0xB2

  describe "Rice coding" $ do
    it "round-trips any value with any k in [0,8]" $ property $
      forAll (choose (0, 8 :: Word8)) $ \k ->
        forAll (choose (0, 4095 :: Word16)) $ \val ->
          let encoded = flushBits $ riceEncode k val newBitWriter
              (decoded, _) = riceDecode k (newBitReader encoded)
          in decoded === val

  describe "optimal k" $ do
    it "selects k in range [0,8]" $ property $
      forAll (listOf1 (choose (0, 511 :: Word16))) $ \block ->
        let k = optimalK block
        in k >= 0 .&&. k <= 8

  describe "block encode/decode" $ do
    it "round-trips a block of values" $ property $
      forAll (vectorOf blockSize (choose (0, 511 :: Word16))) $ \block ->
        let encoded = encodeBlock block
            decoded = decodeBlock encoded blockSize
        in decoded === block
```

- [ ] **Step 2: Add to test runner**

Add `import qualified Test.Rice` and `Test.Rice.spec` to `Spec.hs`.

- [ ] **Step 3: Run tests to verify they fail**

```bash
stack test
```

Expected: compilation error.

- [ ] **Step 4: Implement Rice-Golomb coding**

Replace `sigil-hs/src/Sigil/Codec/Rice.hs`:

```haskell
module Sigil.Codec.Rice
  ( BitWriter
  , BitReader
  , newBitWriter
  , writeBit
  , writeBits
  , flushBits
  , newBitReader
  , readBit
  , readBits
  , riceEncode
  , riceDecode
  , optimalK
  , encodeBlock
  , decodeBlock
  , blockSize
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit, setBit)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word8, Word16)

blockSize :: Int
blockSize = 64

-- ── BitWriter ──────────────────────────────────────────────

data BitWriter = BitWriter
  { bwBytes   :: [Word8]  -- accumulated bytes, reversed
  , bwCurrent :: Word8    -- current byte being filled
  , bwBitPos  :: Int      -- bits written in current byte (0..7)
  }

newBitWriter :: BitWriter
newBitWriter = BitWriter [] 0 0

writeBit :: Bool -> BitWriter -> BitWriter
writeBit b (BitWriter bytes cur pos) =
  let cur' = if b then setBit cur (7 - pos) else cur
      pos' = pos + 1
  in if pos' == 8
     then BitWriter (cur' : bytes) 0 0
     else BitWriter bytes cur' pos'

writeBits :: Int -> Word16 -> BitWriter -> BitWriter
writeBits n val w = foldl (\w' i -> writeBit (testBit val i) w') w [(n-1), (n-2) .. 0]

flushBits :: BitWriter -> ByteString
flushBits (BitWriter bytes cur pos) =
  BS.pack $ reverse $ if pos > 0 then cur : bytes else bytes

-- ── BitReader ──────────────────────────────────────────────

data BitReader = BitReader
  { brBytes  :: ByteString
  , brByteIx :: Int
  , brBitPos :: Int  -- 0..7, next bit to read within current byte
  }

newBitReader :: ByteString -> BitReader
newBitReader bs = BitReader bs 0 0

readBit :: BitReader -> (Bool, BitReader)
readBit (BitReader bs bi bp) =
  let byte = BS.index bs bi
      bit  = testBit byte (7 - bp)
      bp'  = bp + 1
      (bi', bp'') = if bp' == 8 then (bi + 1, 0) else (bi, bp')
  in (bit, BitReader bs bi' bp'')

readBits :: Int -> BitReader -> (Word16, BitReader)
readBits n r = foldl step (0, r) [0..n-1]
  where
    step (val, r') _ =
      let (b, r'') = readBit r'
      in (val `shiftL` 1 .|. (if b then 1 else 0), r'')

-- ── Rice-Golomb ────────────────────────────────────────────

riceEncode :: Word8 -> Word16 -> BitWriter -> BitWriter
riceEncode k val w =
  let q = val `shiftR` fromIntegral k
      r = val .&. ((1 `shiftL` fromIntegral k) - 1)
      -- unary: q ones then a zero
      w1 = iterate (writeBit True) w !! fromIntegral q
      w2 = writeBit False w1
      -- binary: k bits of remainder
      w3 = writeBits (fromIntegral k) r w2
  in w3

riceDecode :: Word8 -> BitReader -> (Word16, BitReader)
riceDecode k r0 =
  -- read unary: count ones until zero
  let (q, r1) = readUnary r0 0
      (remainder, r2) = readBits (fromIntegral k) r1
      val = (q `shiftL` fromIntegral k) .|. remainder
  in (val, r2)
  where
    readUnary r acc =
      let (b, r') = readBit r
      in if b then readUnary r' (acc + 1) else (acc, r')

-- ── Optimal k ──────────────────────────────────────────────

optimalK :: [Word16] -> Word8
optimalK block = snd $ minimum
  [ (encodedBits k, k)
  | k <- [0..8]
  ]
  where
    encodedBits k = sum
      [ fromIntegral (val `shiftR` fromIntegral k) + 1 + fromIntegral k
      | val <- block
      ] :: Int

-- ── Block encode/decode ────────────────────────────────────

encodeBlock :: [Word16] -> ByteString
encodeBlock vals =
  let k = optimalK vals
      w0 = writeBits 4 (fromIntegral k) newBitWriter
      w1 = foldl (\w v -> riceEncode k v w) w0 vals
  in flushBits w1

decodeBlock :: ByteString -> Int -> [Word16]
decodeBlock bs n =
  let r0 = newBitReader bs
      (kVal, r1) = readBits 4 r0
      k = fromIntegral kVal :: Word8
  in fst $ foldl (\(acc, r) _ ->
      let (v, r') = riceDecode k r
      in (acc ++ [v], r')) ([], r1) [1..n]
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
stack test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: Rice-Golomb coding with bit-level I/O"
```

---

### Task 6: CRC32 and Chunk (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/Core/Chunk.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write failing tests inline in Spec.hs**

Add to `Spec.hs`:

```haskell
import qualified Data.ByteString as BS
import Sigil.Core.Chunk (Tag(..), Chunk(..), crc32, makeChunk, verifyChunk)

-- in main:
  describe "Chunk" $ do
    it "CRC32 of empty is 0x00000000" $
      crc32 BS.empty `shouldBe` 0x00000000

    it "CRC32 of 'IEND' matches PNG reference" $
      -- PNG IEND CRC32 is well-known: 0xAE426082
      crc32 (BS.pack [0x49, 0x45, 0x4E, 0x44]) `shouldBe` 0xAE426082

    it "makeChunk computes CRC and verifyChunk accepts it" $ do
      let chunk = makeChunk SHDR (BS.pack [1, 2, 3])
      verifyChunk chunk `shouldBe` Right ()

    it "verifyChunk rejects corrupted payload" $ do
      let chunk = makeChunk SHDR (BS.pack [1, 2, 3])
          bad = chunk { chunkPayload = BS.pack [9, 9, 9] }
      verifyChunk bad `shouldSatisfy` isLeft
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test
```

- [ ] **Step 3: Implement Chunk with CRC32**

Replace `sigil-hs/src/Sigil/Core/Chunk.hs`:

```haskell
module Sigil.Core.Chunk
  ( Tag(..)
  , Chunk(..)
  , crc32
  , makeChunk
  , verifyChunk
  , tagBytes
  , tagFromBytes
  ) where

import Data.Bits (xor, shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word8, Word32)

import Sigil.Core.Error (SigilError(..))

data Tag = SHDR | SMTA | SPAL | SDAT | SEND
  deriving (Eq, Show, Enum, Bounded)

data Chunk = Chunk
  { chunkTag     :: Tag
  , chunkPayload :: ByteString
  , chunkCRC     :: Word32
  } deriving (Eq, Show)

makeChunk :: Tag -> ByteString -> Chunk
makeChunk tag payload = Chunk tag payload (crc32 payload)

verifyChunk :: Chunk -> Either SigilError ()
verifyChunk c =
  let computed = crc32 (chunkPayload c)
  in if computed == chunkCRC c
     then Right ()
     else Left (CrcMismatch { expected = chunkCRC c, actual = computed })

tagBytes :: Tag -> ByteString
tagBytes SHDR = "SHDR"
tagBytes SMTA = "SMTA"
tagBytes SPAL = "SPAL"
tagBytes SDAT = "SDAT"
tagBytes SEND = "SEND"

tagFromBytes :: ByteString -> Either SigilError Tag
tagFromBytes "SHDR" = Right SHDR
tagFromBytes "SMTA" = Right SMTA
tagFromBytes "SPAL" = Right SPAL
tagFromBytes "SDAT" = Right SDAT
tagFromBytes "SEND" = Right SEND
tagFromBytes bs     = Left (InvalidTag bs)

-- ── CRC32 (ISO 3309 / ITU-T V.42, same as PNG) ───────────

crc32 :: ByteString -> Word32
crc32 = xor 0xFFFFFFFF . BS.foldl' step 0xFFFFFFFF
  where
    step crc byte =
      let idx = fromIntegral ((crc `xor` fromIntegral byte) .&. 0xFF)
      in (crc `shiftR` 8) `xor` (crcTable !! idx)

crcTable :: [Word32]
crcTable = [ go n 8 | n <- [0..255] ]
  where
    go :: Word32 -> Int -> Word32
    go c 0 = c
    go c k = go (if c .&. 1 == 1
                  then 0xEDB88320 `xor` (c `shiftR` 1)
                  else c `shiftR` 1) (k - 1)
```

Note: the CRC32 table is computed once at program start via Haskell's lazy evaluation. The polynomial `0xEDB88320` is the standard CRC32 polynomial in reflected form, matching PNG and Ethernet.

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: CRC32 and chunk types with verification"
```

---

### Task 7: Pipeline Stage & Category

**Files:**
- Modify: `sigil-hs/src/Sigil/Codec/Pipeline.hs`
- Create: `sigil-hs/test/Test/Pipeline.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write failing pipeline round-trip test**

Create `sigil-hs/test/Test/Pipeline.hs`:

```haskell
module Test.Pipeline (spec) where

import Test.Hspec
import Test.QuickCheck

import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Codec.Pipeline (compress, decompress)
import Gen (arbitraryImage, arbitraryFixedPredictor)

spec :: Spec
spec = describe "Pipeline" $ do
  it "round-trips small images with fixed predictors" $ property $
    forAll arbitraryFixedPredictor $ \pid ->
      forAll (choose (1, 16 :: Word32)) $ \w ->
        forAll (choose (1, 16 :: Word32)) $ \h ->
          forAll (arbitraryImage w h 3) $ \img ->
            let hdr = Header w h RGB Depth8 pid
                encoded = compress hdr img
                decoded = decompress hdr encoded
            in decoded === Right img

  it "round-trips with adaptive predictor" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 3) $ \img ->
          let hdr = Header w h RGB Depth8 PAdaptive
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips grayscale" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 1) $ \img ->
          let hdr = Header w h Grayscale Depth8 PAdaptive
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips RGBA" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 4) $ \img ->
          let hdr = Header w h RGBA Depth8 PAdaptive
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img
```

- [ ] **Step 2: Add to test runner and run to verify failure**

```bash
stack test
```

Expected: `compress` and `decompress` not defined.

- [ ] **Step 3: Implement Pipeline**

Replace `sigil-hs/src/Sigil/Codec/Pipeline.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
module Sigil.Codec.Pipeline
  ( Stage(..)
  , compress
  , decompress
  ) where

import Prelude hiding (id, (.))
import Control.Category (Category(..), (>>>))

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int16)
import Data.Word (Word8, Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.Predict (predictImage, unpredictImage)
import Sigil.Codec.ZigZag (zigzag, unzigzag)
import Sigil.Codec.Token (Token(..), tokenize, untokenize)
import Sigil.Codec.Rice

newtype Stage a b = Stage { runStage :: a -> b }

instance Category Stage where
  id = Stage Prelude.id
  (Stage f) . (Stage g) = Stage (f Prelude.. g)

-- | Compress an image to raw encoded bytes (SDAT payload).
compress :: Header -> Image -> ByteString
compress hdr img = runStage (compressPipeline hdr) img

-- | Decompress raw encoded bytes back to an image.
decompress :: Header -> ByteString -> Either SigilError Image
decompress hdr bs = Right $ runStage (decompressPipeline hdr) bs

compressPipeline :: Header -> Stage Image ByteString
compressPipeline hdr =
      Stage (predictImage hdr)
  >>> Stage applyZigZag
  >>> Stage (encodeData hdr)

decompressPipeline :: Header -> Stage ByteString Image
decompressPipeline hdr =
      Stage (decodeData hdr)
  >>> Stage unapplyZigZag
  >>> Stage (unpredictImage hdr)

-- | Apply zigzag to all residuals.
applyZigZag :: (Vector PredictorId, Vector (Vector Int16))
            -> (Vector PredictorId, Vector (Vector Word16))
applyZigZag (pids, residuals) = (pids, V.map (V.map zigzag) residuals)

-- | Undo zigzag.
unapplyZigZag :: (Vector PredictorId, Vector (Vector Word16))
              -> (Vector PredictorId, Vector (Vector Int16))
unapplyZigZag (pids, encoded) = (pids, V.map (V.map unzigzag) encoded)

-- | Encode predicted+zigzagged data into bytes.
-- Format: [predictor IDs if adaptive] [per-block k (4 bits)] [rice-coded tokens]
encodeData :: Header -> (Vector PredictorId, Vector (Vector Word16)) -> ByteString
encodeData hdr (pids, rows) =
  let -- Predictor IDs (only for adaptive)
      pidBytes = if predictor hdr == PAdaptive
                 then BS.pack $ V.toList $ V.map (fromIntegral . fromEnum) pids
                 else BS.empty
      -- Flatten all rows into one stream
      flat = V.toList $ V.concatMap Prelude.id rows
      -- Tokenize
      tokens = tokenize (V.fromList flat)
      -- Encode tokens in blocks
      tokenBytes = encodeTokenStream tokens
  in pidBytes <> tokenBytes

-- | Decode bytes back into predictor IDs and zigzagged values.
decodeData :: Header -> ByteString -> (Vector PredictorId, Vector (Vector Word16))
decodeData hdr bs =
  let numRows = fromIntegral (height hdr)
      ch = channels (colorSpace hdr)
      rowLen = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
      totalSamples = numRows * rowLen
      -- Read predictor IDs
      (pids, rest) = if predictor hdr == PAdaptive
                     then let pidBs = BS.take numRows bs
                              ps = V.fromList $ map (toEnum . fromIntegral) $ BS.unpack pidBs
                          in (ps, BS.drop numRows bs)
                     else (V.replicate numRows (predictor hdr), bs)
      -- Decode token stream
      tokens = decodeTokenStream rest totalSamples
      flat = untokenize tokens
      -- Split into rows
      rows = V.fromList [ V.slice (i * rowLen) rowLen flat | i <- [0..numRows - 1] ]
  in (pids, rows)

-- | Encode a token stream: 1-bit flag per token, then value.
-- TZeroRun: flag 0, 16-bit run length
-- TValue: flag 1, rice-coded value
-- Tokens are grouped into blocks for rice k selection.
encodeTokenStream :: [Token] -> ByteString
encodeTokenStream tokens =
  let -- Extract values for k selection
      values = [ v | TValue v <- tokens ]
      blocks = chunksOf blockSize values
      -- For each block, compute optimal k
      ks = map optimalK blocks
      -- Now encode: first the k values, then the token stream
      w0 = newBitWriter
      -- Write number of blocks as 16 bits
      w1 = writeBits 16 (fromIntegral $ length blocks) w0
      -- Write k for each block (4 bits each)
      w2 = foldl (\w k -> writeBits 4 (fromIntegral k) w) w1 ks
      -- Write tokens using block-local k values
      w3 = encodeTokensWithKs tokens ks w2
  in flushBits w3

encodeTokensWithKs :: [Token] -> [Word8] -> BitWriter -> BitWriter
encodeTokensWithKs [] _ w = w
encodeTokensWithKs _ [] w = w  -- shouldn't happen
encodeTokensWithKs tokens (k:ks) w =
  let (blockTokens, rest, remaining) = takeBlock blockSize tokens
      w1 = foldl (encodeToken k) w blockTokens
  in encodeTokensWithKs rest (if remaining then ks else (k:ks)) w1

encodeToken :: Word8 -> BitWriter -> Token -> BitWriter
encodeToken _ w (TZeroRun n) = writeBits 16 n $ writeBit False w
encodeToken k w (TValue v)   = riceEncode k v $ writeBit True w

-- | Take tokens consuming up to n TValue slots from the block budget.
takeBlock :: Int -> [Token] -> ([Token], [Token], Bool)
takeBlock _ [] = ([], [], True)
takeBlock 0 rest = ([], rest, True)
takeBlock budget (t@(TZeroRun _) : rest) =
  let (taken, remaining, done) = takeBlock budget rest
  in (t : taken, remaining, done)
takeBlock budget (t@(TValue _) : rest) =
  let (taken, remaining, done) = takeBlock (budget - 1) rest
  in (t : taken, remaining, done)

decodeTokenStream :: ByteString -> Int -> [Token]
decodeTokenStream bs totalSamples =
  let r0 = newBitReader bs
      (numBlocksW, r1) = readBits 16 r0
      numBlocks = fromIntegral numBlocksW :: Int
      (ks, r2) = readKs numBlocks r1
      (tokens, _) = decodeTokensWithKs ks totalSamples r2
  in tokens

readKs :: Int -> BitReader -> ([Word8], BitReader)
readKs 0 r = ([], r)
readKs n r =
  let (kVal, r') = readBits 4 r
      (rest, r'') = readKs (n - 1) r'
  in (fromIntegral kVal : rest, r'')

decodeTokensWithKs :: [Word8] -> Int -> BitReader -> ([Token], BitReader)
decodeTokensWithKs _ 0 r = ([], r)
decodeTokensWithKs [] _ r = ([], r)
decodeTokensWithKs (k:ks) remaining r =
  let (blockTokens, remaining', r') = decodeBlockTokens k (min blockSize remaining) r
      (rest, r'') = decodeTokensWithKs ks remaining' r'
  in (blockTokens ++ rest, r'')

decodeBlockTokens :: Word8 -> Int -> BitReader -> ([Token], Int, BitReader)
decodeBlockTokens _ 0 r = ([], 0, r)
decodeBlockTokens k budget r =
  let (flag, r1) = readBit r
  in if flag
     then -- TValue
       let (val, r2) = riceDecode k r1
           (rest, remaining, r3) = decodeBlockTokens k (budget - 1) r2
       in (TValue val : rest, remaining, r3)
     else -- TZeroRun
       let (runLen, r2) = readBits 16 r1
           consumed = fromIntegral runLen
           remaining = budget - consumed
           (rest, remaining', r3) = decodeBlockTokens k (max 0 remaining) r2
       in (TZeroRun runLen : rest, remaining', r3)

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (a, b) = splitAt n xs in a : chunksOf n b
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test
```

Expected: all pipeline round-trip tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Stage pipeline with Category composition and full round-trip"
```

---

### Task 8: File I/O — Writer & Reader (TDD)

**Files:**
- Modify: `sigil-hs/src/Sigil/IO/Writer.hs`
- Modify: `sigil-hs/src/Sigil/IO/Reader.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write failing file I/O round-trip test**

Add to `Spec.hs`:

```haskell
import qualified Data.ByteString.Lazy as BL
import Sigil.IO.Writer (encodeSigilFile)
import Sigil.IO.Reader (decodeSigilFile)

-- in main:
  describe "File I/O" $ do
    it "round-trips a small image through .sgl format" $ property $
      forAll (choose (1, 8 :: Word32)) $ \w ->
        forAll (choose (1, 8 :: Word32)) $ \h ->
          forAll (arbitraryImage w h 3) $ \img ->
            let hdr = Header w h RGB Depth8 PAdaptive
                encoded = encodeSigilFile hdr emptyMetadata img
                decoded = decodeSigilFile encoded
            in case decoded of
                 Left err -> counterexample (show err) False
                 Right (hdr', _, img') -> hdr' === hdr .&&. img' === img
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test
```

- [ ] **Step 3: Implement Writer**

Replace `sigil-hs/src/Sigil/IO/Writer.hs`:

```haskell
module Sigil.IO.Writer
  ( encodeSigilFile
  , writeSigilFile
  ) where

import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word8, Word32)

import Sigil.Core.Types
import Sigil.Core.Chunk
import Sigil.Codec.Pipeline (compress)

-- | Magic bytes: 0x89 S G L \r \n
magic :: ByteString
magic = BS.pack [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A]

versionMajor, versionMinor :: Word8
versionMajor = 0
versionMinor = 2

encodeSigilFile :: Header -> Metadata -> Image -> BL.ByteString
encodeSigilFile hdr meta img = runPut $ do
  putByteString magic
  putWord8 versionMajor
  putWord8 versionMinor
  putChunk (makeChunk SHDR (encodeHeader hdr))
  if not (null (metaEntries meta))
    then putChunk (makeChunk SMTA (encodeMetadata meta))
    else pure ()
  let payload = compress hdr img
  putChunk (makeChunk SDAT payload)
  putChunk (makeChunk SEND BS.empty)

putChunk :: Chunk -> Put
putChunk c = do
  putByteString (tagBytes (chunkTag c))
  putWord32be (fromIntegral (BS.length (chunkPayload c)))
  putByteString (chunkPayload c)
  putWord32be (chunkCRC c)

encodeHeader :: Header -> ByteString
encodeHeader hdr = BL.toStrict $ runPut $ do
  putWord32be (width hdr)
  putWord32be (height hdr)
  putWord8 (fromIntegral $ fromEnum $ colorSpace hdr)
  putWord8 (case bitDepth hdr of Depth8 -> 8; Depth16 -> 16)
  putWord8 (fromIntegral $ fromEnum $ predictor hdr)

encodeMetadata :: Metadata -> ByteString
encodeMetadata (Metadata entries) = BL.toStrict $ runPut $
  mapM_ (\(k, v) -> do
    let kbs = encodeUtf8 k
    putWord16be (fromIntegral (BS.length kbs))
    putByteString kbs
    putWord32be (fromIntegral (BS.length v))
    putByteString v
  ) entries
  where
    encodeUtf8 = Data.Text.Encoding.encodeUtf8

writeSigilFile :: FilePath -> Header -> Metadata -> Image -> IO ()
writeSigilFile path hdr meta img =
  BL.writeFile path (encodeSigilFile hdr meta img)
```

Add the `text` import to the module. `text` is already in the shared dependencies in `package.yaml`.

- [ ] **Step 4: Implement Reader**

Replace `sigil-hs/src/Sigil/IO/Reader.hs`:

```haskell
module Sigil.IO.Reader
  ( decodeSigilFile
  , readSigilFile
  ) where

import Data.Binary.Get
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text.Encoding (decodeUtf8')
import Data.Word (Word8)

import Sigil.Core.Types
import Sigil.Core.Error
import Sigil.Core.Chunk
import Sigil.Codec.Pipeline (decompress)

magic :: ByteString
magic = BS.pack [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A]

decodeSigilFile :: BL.ByteString -> Either SigilError (Header, Metadata, Image)
decodeSigilFile input = case runGetOrFail parser input of
  Left (_, _, err) -> Left (IoError err)
  Right (_, _, result) -> result
  where
    parser = do
      m <- getByteString 6
      if m /= magic
        then pure $ Left (InvalidMagic m)
        else do
          major <- getWord8
          minor <- getWord8
          if major /= 0 || minor /= 2
            then pure $ Left (UnsupportedVersion major minor)
            else do
              chunks <- readChunks
              parseChunks chunks

readChunks :: Get [Chunk]
readChunks = do
  tag <- getByteString 4
  len <- getWord32be
  payload <- getByteString (fromIntegral len)
  crcVal <- getWord32be
  case tagFromBytes tag of
    Left err -> pure []
    Right t -> do
      let chunk = Chunk t payload crcVal
      if t == SEND
        then pure [chunk]
        else do
          rest <- readChunks
          pure (chunk : rest)

parseChunks :: [Chunk] -> Get (Either SigilError (Header, Metadata, Image))
parseChunks chunks = pure $ do
  -- Verify all CRCs
  mapM_ verifyChunk chunks
  -- Find SHDR
  shdr <- case filter (\c -> chunkTag c == SHDR) chunks of
    (c:_) -> Right c
    []    -> Left (MissingChunk "SHDR")
  hdr <- decodeHeader (chunkPayload shdr)
  -- Optional SMTA
  let meta = case filter (\c -> chunkTag c == SMTA) chunks of
        (c:_) -> case decodeMetadata (chunkPayload c) of
                   Right m -> m
                   Left _  -> emptyMetadata
        []    -> emptyMetadata
  -- Concatenate SDAT payloads
  let sdatPayload = BS.concat
        [ chunkPayload c | c <- chunks, chunkTag c == SDAT ]
  img <- decompress hdr sdatPayload
  Right (hdr, meta, img)

decodeHeader :: ByteString -> Either SigilError Header
decodeHeader bs = case runGetOrFail parser (BL.fromStrict bs) of
  Left (_, _, err) -> Left TruncatedInput
  Right (_, _, hdr) -> hdr
  where
    parser = do
      w <- getWord32be
      h <- getWord32be
      cs <- getWord8
      bd <- getWord8
      p  <- getWord8
      pure $ do
        colorSp <- toColorSpace cs
        bitD    <- toBitDepth bd
        pred'   <- toPredictorId p
        when (w == 0 || h == 0) $ Left (InvalidDimensions w h)
        Right (Header w h colorSp bitD pred')

    toColorSpace :: Word8 -> Either SigilError ColorSpace
    toColorSpace 0 = Right Grayscale
    toColorSpace 1 = Right GrayscaleAlpha
    toColorSpace 2 = Right RGB
    toColorSpace 3 = Right RGBA
    toColorSpace n = Left (InvalidColorSpace n)

    toBitDepth :: Word8 -> Either SigilError BitDepth
    toBitDepth 8  = Right Depth8
    toBitDepth 16 = Right Depth16
    toBitDepth n  = Left (InvalidBitDepth n)

    toPredictorId :: Word8 -> Either SigilError PredictorId
    toPredictorId n
      | n <= fromIntegral (fromEnum (maxBound :: PredictorId)) = Right (toEnum (fromIntegral n))
      | otherwise = Left (InvalidPredictor n)

    when False _ = Right ()
    when True e  = e

decodeMetadata :: ByteString -> Either SigilError Metadata
decodeMetadata bs = case runGetOrFail parser (BL.fromStrict bs) of
  Left _ -> Right emptyMetadata
  Right (_, _, entries) -> Right (Metadata entries)
  where
    parser = do
      empty <- isEmpty
      if empty then pure []
      else do
        kLen <- getWord16be
        kBs <- getByteString (fromIntegral kLen)
        vLen <- getWord32be
        vBs <- getByteString (fromIntegral vLen)
        case decodeUtf8' kBs of
          Left _  -> pure []
          Right k -> do
            rest <- parser
            pure ((k, vBs) : rest)

readSigilFile :: FilePath -> IO (Either SigilError (Header, Metadata, Image))
readSigilFile path = do
  bs <- BL.readFile path
  pure (decodeSigilFile bs)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
stack test
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: .sgl file reader and writer with chunk serialization"
```

---

### Task 9: JuicyPixels Image Conversion

**Files:**
- Modify: `sigil-hs/src/Sigil/IO/Convert.hs`

- [ ] **Step 1: Write a test that loads a synthetic image**

Add to `Spec.hs`:

```haskell
import Sigil.IO.Convert (imageToSigil, sigilToImage)
import Codec.Picture (generateImage, PixelRGB8(..))

-- in main:
  describe "Convert" $ do
    it "round-trips a JuicyPixels image through Sigil types" $ do
      let jp = generateImage (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y) 128) 4 4
          (hdr, img) = imageToSigil jp
      width hdr `shouldBe` 4
      height hdr `shouldBe` 4
      colorSpace hdr `shouldBe` RGB
      let jp' = sigilToImage hdr img
      -- Round-trip should produce identical pixel data
      jp' `shouldBe` jp
```

- [ ] **Step 2: Run test to verify it fails**

```bash
stack test
```

- [ ] **Step 3: Implement Convert**

Replace `sigil-hs/src/Sigil/IO/Convert.hs`:

```haskell
module Sigil.IO.Convert
  ( loadImage
  , saveImage
  , imageToSigil
  , sigilToImage
  ) where

import Codec.Picture
  ( DynamicImage(..)
  , Image(..)
  , PixelRGB8(..)
  , PixelRGBA8(..)
  , Pixel8
  , readImage
  , writePng
  , generateImage
  , pixelAt
  , imageWidth
  , imageHeight
  )
import qualified Codec.Picture as JP
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import Data.Word (Word8)

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))

loadImage :: FilePath -> IO (Either SigilError (Header, Sigil.Core.Types.Image))
loadImage path = do
  result <- readImage path
  case result of
    Left err -> pure $ Left (IoError err)
    Right dyn -> pure $ dynamicToSigil dyn

saveImage :: FilePath -> Header -> Sigil.Core.Types.Image -> IO ()
saveImage path hdr img = case colorSpace hdr of
  RGB  -> writePng path (sigilToImage hdr img)
  RGBA -> writePng path (sigilToImageRGBA hdr img)
  _    -> writePng path (sigilToImage hdr img)  -- fallback to RGB

dynamicToSigil :: DynamicImage -> Either SigilError (Header, Sigil.Core.Types.Image)
dynamicToSigil (ImageRGB8 img)  = Right (imageToSigil img)
dynamicToSigil (ImageRGBA8 img) = Right (imageToSigilRGBA img)
dynamicToSigil (ImageY8 img)    = Right (imageToSigilGray img)
dynamicToSigil (ImageYA8 img)   = Right (imageToSigilGrayAlpha img)
dynamicToSigil _ = Left (IoError "unsupported pixel format (try 8-bit RGB/RGBA)")

imageToSigil :: JP.Image PixelRGB8 -> (Header, Sigil.Core.Types.Image)
imageToSigil img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 PAdaptive
      rows = V.fromList
        [ V.fromList
            [ comp
            | x <- [0..w-1]
            , let PixelRGB8 r g b = pixelAt img x y
            , comp <- [r, g, b]
            ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

sigilToImage :: Header -> Sigil.Core.Types.Image -> JP.Image PixelRGB8
sigilToImage hdr img =
  let w = fromIntegral (width hdr)
      h = fromIntegral (height hdr)
  in generateImage (\x y ->
    let row = img V.! y
        base = x * 3
    in PixelRGB8 (row V.! base) (row V.! (base + 1)) (row V.! (base + 2))
  ) w h

imageToSigilRGBA :: JP.Image PixelRGBA8 -> (Header, Sigil.Core.Types.Image)
imageToSigilRGBA img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) RGBA Depth8 PAdaptive
      rows = V.fromList
        [ V.fromList
            [ comp
            | x <- [0..w-1]
            , let PixelRGBA8 r g b a = pixelAt img x y
            , comp <- [r, g, b, a]
            ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

sigilToImageRGBA :: Header -> Sigil.Core.Types.Image -> JP.Image PixelRGBA8
sigilToImageRGBA hdr img =
  let w = fromIntegral (width hdr)
      h = fromIntegral (height hdr)
  in generateImage (\x y ->
    let row = img V.! y
        base = x * 4
    in PixelRGBA8 (row V.! base) (row V.! (base+1)) (row V.! (base+2)) (row V.! (base+3))
  ) w h

imageToSigilGray :: JP.Image Pixel8 -> (Header, Sigil.Core.Types.Image)
imageToSigilGray img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) Grayscale Depth8 PAdaptive
      rows = V.fromList
        [ V.fromList [ pixelAt img x y | x <- [0..w-1] ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

imageToSigilGrayAlpha :: JP.Image JP.PixelYA8 -> (Header, Sigil.Core.Types.Image)
imageToSigilGrayAlpha img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) GrayscaleAlpha Depth8 PAdaptive
      rows = V.fromList
        [ V.fromList
            [ comp
            | x <- [0..w-1]
            , let JP.PixelYA8 y' a = pixelAt img x y
            , comp <- [y', a]
            ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: JuicyPixels image conversion for PNG/JPEG"
```

---

### Task 10: Top-Level Re-exports

**Files:**
- Modify: `sigil-hs/src/Sigil.hs`

- [ ] **Step 1: Update Sigil.hs to re-export everything**

```haskell
module Sigil
  ( module Sigil.Core.Types
  , module Sigil.Core.Error
  , module Sigil.Core.Chunk
  , module Sigil.Codec.Pipeline
  , module Sigil.IO.Reader
  , module Sigil.IO.Writer
  , module Sigil.IO.Convert
  ) where

import Sigil.Core.Types
import Sigil.Core.Error
import Sigil.Core.Chunk
import Sigil.Codec.Pipeline
import Sigil.IO.Reader
import Sigil.IO.Writer
import Sigil.IO.Convert
```

- [ ] **Step 2: Build to verify**

```bash
stack build
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: top-level Sigil module re-exports"
```

---

### Task 11: CLI — Encode, Decode, Info, Verify

**Files:**
- Modify: `sigil-hs/app/Main.hs`

- [ ] **Step 1: Implement CLI with optparse-applicative**

Replace `sigil-hs/app/Main.hs`:

```haskell
module Main where

import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import qualified Data.ByteString.Lazy as BL

import Sigil

data Command
  = Encode FilePath FilePath (Maybe String)
  | Decode FilePath FilePath
  | Info FilePath
  | Verify FilePath
  | Bench FilePath Int (Maybe FilePath)
  | GenerateCorpus FilePath

commandParser :: Parser Command
commandParser = subparser
  ( command "encode" (info encodeCmd (progDesc "Encode an image to .sgl"))
  <> command "decode" (info decodeCmd (progDesc "Decode .sgl to image"))
  <> command "info" (info infoCmd (progDesc "Show .sgl file metadata"))
  <> command "verify" (info verifyCmd (progDesc "Verify round-trip integrity"))
  <> command "bench" (info benchCmd (progDesc "Benchmark compression"))
  <> command "generate-corpus" (info corpusCmd (progDesc "Generate synthetic test corpus"))
  )

encodeCmd :: Parser Command
encodeCmd = Encode
  <$> argument str (metavar "INPUT")
  <*> strOption (short 'o' <> long "output" <> metavar "OUTPUT")
  <*> optional (strOption (long "predictor" <> metavar "PREDICTOR"))

decodeCmd :: Parser Command
decodeCmd = Decode
  <$> argument str (metavar "INPUT")
  <*> strOption (short 'o' <> long "output" <> metavar "OUTPUT")

infoCmd :: Parser Command
infoCmd = Info <$> argument str (metavar "INPUT")

verifyCmd :: Parser Command
verifyCmd = Verify <$> argument str (metavar "INPUT")

benchCmd :: Parser Command
benchCmd = Bench
  <$> argument str (metavar "INPUT")
  <*> option auto (long "iterations" <> value 10 <> metavar "N")
  <*> optional (strOption (long "compare" <> metavar "DIR"))

corpusCmd :: Parser Command
corpusCmd = GenerateCorpus
  <$> strOption (short 'o' <> long "output-dir" <> value "tests/corpus" <> metavar "DIR")

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper)
    (fullDesc <> progDesc "Sigil image codec — Haskell reference" <> header "sigil-hs"))
  case cmd of
    Encode input output mPred -> runEncode input output mPred
    Decode input output       -> runDecode input output
    Info input                -> runInfo input
    Verify input              -> runVerify input
    Bench input iters mDir    -> runBench input iters mDir
    GenerateCorpus dir        -> runGenerateCorpus dir

runEncode :: FilePath -> FilePath -> Maybe String -> IO ()
runEncode input output _mPred = do
  result <- loadImage input
  case result of
    Left err -> die (show err)
    Right (hdr, img) -> do
      writeSigilFile output hdr emptyMetadata img
      putStrLn $ "Encoded " ++ input ++ " -> " ++ output

runDecode :: FilePath -> FilePath -> IO ()
runDecode input output = do
  result <- readSigilFile input
  case result of
    Left err -> die (show err)
    Right (hdr, _, img) -> do
      saveImage output hdr img
      putStrLn $ "Decoded " ++ input ++ " -> " ++ output

runInfo :: FilePath -> IO ()
runInfo input = do
  bs <- BL.readFile input
  case decodeSigilFile bs of
    Left err -> die (show err)
    Right (hdr, meta, _) -> do
      putStrLn $ "File: " ++ input
      putStrLn $ "Dimensions: " ++ show (width hdr) ++ "x" ++ show (height hdr)
      putStrLn $ "Color space: " ++ show (colorSpace hdr)
      putStrLn $ "Bit depth: " ++ show (bitDepth hdr)
      putStrLn $ "Predictor: " ++ show (predictor hdr)
      putStrLn $ "Raw size: " ++ show (rowBytes hdr * fromIntegral (height hdr)) ++ " bytes"

runVerify :: FilePath -> IO ()
runVerify input = do
  result <- loadImage input
  case result of
    Left err -> die (show err)
    Right (hdr, original) -> do
      let encoded = encodeSigilFile hdr emptyMetadata original
      case decodeSigilFile encoded of
        Left err -> die ("Decode failed: " ++ show err)
        Right (_, _, decoded) ->
          if decoded == original
          then putStrLn $ "PASS: " ++ input ++ " round-trip verified"
          else do
            putStrLn $ "FAIL: " ++ input ++ " round-trip mismatch"
            exitFailure

runBench :: FilePath -> Int -> Maybe FilePath -> IO ()
runBench _ _ _ = putStrLn "bench: not yet implemented (Task 12)"

runGenerateCorpus :: FilePath -> IO ()
runGenerateCorpus _ = putStrLn "generate-corpus: not yet implemented (Task 13)"

die :: String -> IO ()
die msg = hPutStrLn stderr msg >> exitFailure
```

- [ ] **Step 2: Build and test manually**

```bash
stack build
stack run -- --help
stack run -- encode --help
```

Expected: help text for each subcommand.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: CLI with encode/decode/info/verify commands"
```

---

### Task 12: CLI Bench Command

**Files:**
- Modify: `sigil-hs/app/Main.hs`

- [ ] **Step 1: Implement runBench**

Add these imports to `app/Main.hs`:

```haskell
import Data.Time.Clock (getCurrentTime, diffUTCTime, NominalDiffTime)
import System.Directory (listDirectory, doesFileExist)
import System.FilePath ((</>), takeExtension)
import Data.List (sortBy, intercalate)
import Data.Ord (comparing, Down(..))
import Text.Printf (printf)
import qualified Data.Vector as V
import qualified Data.ByteString as BS

import Sigil.Core.Types
import Sigil.Codec.Predict (predictRow, predictImage)
import Sigil.Codec.Pipeline (compress)
```

Replace `runBench`:

```haskell
runBench :: FilePath -> Int -> Maybe FilePath -> IO ()
runBench input iters Nothing = benchSingleImage input iters
runBench _input iters (Just dir) = benchCorpus dir iters

benchSingleImage :: FilePath -> Int -> IO ()
benchSingleImage input iters = do
  result <- loadImage input
  case result of
    Left err -> die (show err)
    Right (hdr, img) -> do
      let rawSize = rowBytes hdr * fromIntegral (height hdr)
      putStrLn $ "Image: " ++ input ++ " ("
        ++ show (width hdr) ++ "x" ++ show (height hdr)
        ++ ", " ++ show (colorSpace hdr) ++ ", " ++ show (bitDepth hdr) ++ ")"
      putStrLn $ "Raw size: " ++ show rawSize ++ " bytes"
      putStrLn ""
      putStrLn "Predictor       Encoded      Ratio    Encode ms    Decode ms"
      putStrLn "--------------------------------------------------------------"

      let predictors = [ (PNone, "None"), (PSub, "Sub"), (PUp, "Up")
                       , (PAverage, "Average"), (PPaeth, "Paeth")
                       , (PGradient, "Gradient"), (PAdaptive, "Adaptive") ]

      results <- mapM (\(pid, name) -> do
        let hdr' = hdr { predictor = pid }
        (encTime, encoded) <- benchmark iters (compress hdr' img)
        let encSize = BS.length encoded
        (decTime, _decoded) <- benchmark iters (decompress hdr' encoded)
        let ratio = fromIntegral rawSize / fromIntegral encSize :: Double
        printf "%-14s %9d %8.2fx %10.1f %12.1f\n"
          name encSize ratio
          (encTime * 1000) (decTime * 1000)
        pure (name, encSize, ratio)
        ) predictors

      -- PNG comparison via JuicyPixels
      fileSize <- BS.length <$> BS.readFile input
      printf "\n%-14s %9d %8.2fx\n" ("PNG (file)" :: String) fileSize
        (fromIntegral rawSize / fromIntegral fileSize :: Double)

      -- Residual analysis
      putStrLn "\nResidual analysis:"
      putStrLn "Predictor       Mean|r|  Median|r|  Stddev|r|  Zeros"
      putStrLn "------------------------------------------------------"
      mapM_ (\(pid, name) -> do
        let hdr' = hdr { predictor = pid }
            (_, residuals) = predictImage hdr' img
            allResiduals = V.toList $ V.concatMap (V.map (fromIntegral . abs)) residuals :: [Int]
            sorted = sortBy compare allResiduals
            n = length sorted
            mean' = fromIntegral (sum allResiduals) / fromIntegral n :: Double
            median' = if even n
                      then fromIntegral (sorted !! (n `div` 2 - 1) + sorted !! (n `div` 2)) / 2
                      else fromIntegral (sorted !! (n `div` 2)) :: Double
            variance = sum (map (\x -> (fromIntegral x - mean') ^ (2 :: Int)) allResiduals) / fromIntegral n
            stddev' = sqrt variance :: Double
            zeros = length (filter (== 0) allResiduals)
        printf "%-14s %8.1f %10.1f %10.1f %8d\n"
          name mean' median' stddev' zeros
        ) (init predictors)  -- skip adaptive for residual analysis (it's per-row)

      putStrLn ""
      let (bestName, _, bestRatio) = head $ sortBy (comparing (\(_, _, r) -> Down r)) results
      putStrLn $ "Best: " ++ bestName ++ " (" ++ printf "%.2fx" bestRatio ++ " compression ratio)"

benchmark :: Int -> a -> IO (Double, a)
benchmark iters x = do
  start <- getCurrentTime
  let go 0 = pure x
      go n = x `seq` go (n - 1)
  result <- go iters
  end <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime end start) / fromIntegral iters :: Double
  pure (elapsed, result)

benchCorpus :: FilePath -> Int -> IO ()
benchCorpus dir iters = do
  files <- listDirectory dir
  let imageFiles = filter (\f -> takeExtension f `elem` [".png", ".jpg", ".jpeg", ".bmp"]) files
  if null imageFiles
    then die $ "No image files found in " ++ dir
    else do
      putStrLn $ "Corpus: " ++ dir ++ " (" ++ show (length imageFiles) ++ " images)"
      mapM_ (\f -> do
        putStrLn $ "\n" ++ replicate 60 '='
        benchSingleImage (dir </> f) iters
        ) imageFiles
```

- [ ] **Step 2: Build and test**

```bash
stack build
```

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: CLI bench command with per-predictor analysis and corpus mode"
```

---

### Task 13: Corpus Generation

**Files:**
- Modify: `sigil-hs/app/Main.hs`

- [ ] **Step 1: Implement runGenerateCorpus**

Replace `runGenerateCorpus`:

```haskell
runGenerateCorpus :: FilePath -> IO ()
runGenerateCorpus dir = do
  createDirectoryIfMissing True dir

  -- Gradient 256x256
  let gradient = generateImage
        (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y)
                           (fromIntegral ((x + y) `mod` 256))) 256 256
  writePng (dir </> "gradient_256x256.png") gradient
  putStrLn "Generated gradient_256x256.png"

  -- Flat white 100x100
  let flat = generateImage (\_ _ -> PixelRGB8 255 255 255) 100 100
  writePng (dir </> "flat_white_100x100.png") flat
  putStrLn "Generated flat_white_100x100.png"

  -- Noise 128x128 (deterministic via simple LCG)
  let noise = generateImage
        (\x y -> let seed = x * 128 + y
                     v = fromIntegral ((seed * 1103515245 + 12345) `mod` 256)
                 in PixelRGB8 v v v) 128 128
  writePng (dir </> "noise_128x128.png") noise
  putStrLn "Generated noise_128x128.png"

  -- Checkerboard 64x64
  let checker = generateImage
        (\x y -> if (x `div` 8 + y `div` 8) `mod` 2 == 0
                 then PixelRGB8 0 0 0
                 else PixelRGB8 255 255 255) 64 64
  writePng (dir </> "checkerboard_64x64.png") checker
  putStrLn "Generated checkerboard_64x64.png"

  putStrLn $ "\nCorpus written to " ++ dir
  putStrLn "Supply photo images manually: 640x480, 1920x1080, 3840x2160, 7680x4320"
```

Add these imports:

```haskell
import Codec.Picture (generateImage, PixelRGB8(..), writePng)
import System.Directory (createDirectoryIfMissing)
```

- [ ] **Step 2: Generate the corpus**

```bash
stack run -- generate-corpus -o tests/corpus
```

Expected: four PNG files created in `tests/corpus/`.

- [ ] **Step 3: Test encode/decode on generated images**

```bash
stack run -- verify tests/corpus/gradient_256x256.png
stack run -- verify tests/corpus/flat_white_100x100.png
stack run -- verify tests/corpus/noise_128x128.png
stack run -- verify tests/corpus/checkerboard_64x64.png
```

Expected: `PASS` for all four.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: synthetic test corpus generation"
```

---

### Task 14: Conformance Golden Tests

**Files:**
- Create: `sigil-hs/test/Test/Conformance.hs`
- Modify: `sigil-hs/test/Spec.hs`

- [ ] **Step 1: Write conformance test**

Create `sigil-hs/test/Test/Conformance.hs`:

```haskell
module Test.Conformance (spec) where

import Test.Hspec

import qualified Data.ByteString.Lazy as BL
import System.Directory (doesFileExist, createDirectoryIfMissing)
import System.FilePath ((</>), takeBaseName, replaceExtension)

import Sigil

spec :: Spec
spec = describe "Conformance" $ do
  let corpusDir = "../tests/corpus"
      expectedDir = corpusDir </> "expected"
      testImages =
        [ "gradient_256x256.png"
        , "flat_white_100x100.png"
        , "noise_128x128.png"
        , "checkerboard_64x64.png"
        ]

  mapM_ (\imgName -> do
    let imgPath = corpusDir </> imgName
        sglName = replaceExtension imgName ".sgl"
        expectedPath = expectedDir </> sglName

    describe imgName $ do
      it "encodes deterministically (matches golden .sgl)" $ do
        exists <- doesFileExist imgPath
        if not exists
          then pendingWith $ "corpus image not found: " ++ imgPath
          else do
            result <- loadImage imgPath
            case result of
              Left err -> expectationFailure (show err)
              Right (hdr, img) -> do
                let encoded = encodeSigilFile hdr emptyMetadata img
                goldenExists <- doesFileExist expectedPath
                if goldenExists
                  then do
                    expected <- BL.readFile expectedPath
                    encoded `shouldBe` expected
                  else do
                    createDirectoryIfMissing True expectedDir
                    BL.writeFile expectedPath encoded
                    pendingWith $ "golden file created: " ++ expectedPath

      it "round-trips through .sgl format" $ do
        exists <- doesFileExist imgPath
        if not exists
          then pendingWith $ "corpus image not found: " ++ imgPath
          else do
            result <- loadImage imgPath
            case result of
              Left err -> expectationFailure (show err)
              Right (hdr, original) -> do
                let encoded = encodeSigilFile hdr emptyMetadata original
                case decodeSigilFile encoded of
                  Left err -> expectationFailure (show err)
                  Right (_, _, decoded) -> decoded `shouldBe` original
    ) testImages
```

- [ ] **Step 2: Add to test runner**

Add `import qualified Test.Conformance` and `Test.Conformance.spec` to `Spec.hs`.

- [ ] **Step 3: Generate corpus if not present, then run tests**

```bash
stack run -- generate-corpus -o tests/corpus
stack test
```

Expected: first run creates golden files and marks those tests as pending. Second run passes.

```bash
stack test
```

Expected: all conformance tests pass.

- [ ] **Step 4: Commit golden files**

```bash
git add tests/corpus/ && git commit -m "feat: conformance golden tests and test corpus"
```

---

### Task 15: Criterion Benchmarks

**Files:**
- Modify: `sigil-hs/bench/Main.hs`

- [ ] **Step 1: Implement criterion benchmarks**

Replace `sigil-hs/bench/Main.hs`:

```haskell
module Main where

import Criterion.Main
import Control.DeepSeq (NFData(..), force)

import Data.Int (Int16)
import Data.Word (Word8, Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Codec.Predict (predictImage, unpredictImage, predictRow)
import Sigil.Codec.ZigZag (zigzag, unzigzag)
import Sigil.Codec.Token (tokenize, untokenize)
import Sigil.Codec.Rice (optimalK, encodeBlock, blockSize)
import Sigil.Codec.Pipeline (compress, decompress)

-- Generate a synthetic gradient image
makeGradient :: Int -> Int -> Image
makeGradient w h = V.fromList
  [ V.fromList
      [ fromIntegral ((x * 3 + c + y) `mod` 256)
      | x <- [0..w-1], c <- [0..2]  -- RGB
      ]
  | y <- [0..h-1]
  ]

-- Generate a noise image (deterministic LCG)
makeNoise :: Int -> Int -> Image
makeNoise w h = V.fromList
  [ V.fromList
      [ fromIntegral (((y * w + x) * 3 + c) * 1103515245 + 12345 :: Int) `mod` 256
      | x <- [0..w-1], c <- [0..2]
      ]
  | y <- [0..h-1]
  ]

-- Generate flat image
makeFlat :: Int -> Int -> Word8 -> Image
makeFlat w h val = V.replicate h (V.replicate (w * 3) val)

-- Generate checkerboard
makeCheckerboard :: Int -> Int -> Image
makeCheckerboard w h = V.fromList
  [ V.fromList
      [ let v = if (x `div` 8 + y `div` 8) `mod` 2 == 0 then 0 else 255
        in v
      | x <- [0..w-1], _ <- [0..2]
      ]
  | y <- [0..h-1]
  ]

-- NFData instances for benchmarking
instance NFData PredictorId where rnf x = x `seq` ()
instance NFData BitDepth where rnf x = x `seq` ()
instance NFData ColorSpace where rnf x = x `seq` ()
instance NFData Header where rnf (Header w h cs bd p) = rnf w `seq` rnf h `seq` rnf cs `seq` rnf bd `seq` rnf p

main :: IO ()
main = do
  let sizes = [(64, 64), (256, 256), (1024, 1024)]
      pids = [PNone, PSub, PUp, PAverage, PPaeth, PGradient, PAdaptive]

  defaultMain
    [ bgroup "predict" $
        [ bgroup (show pid) $
            [ bench (show w ++ "x" ++ show h) $
                let img = makeGradient w h
                    hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 pid
                in nf (predictImage hdr) img
            | (w, h) <- sizes
            ]
        | pid <- pids
        ]

    , bgroup "zigzag"
        [ bench "encode/10k" $ nf (V.map zigzag) (V.enumFromTo (-255) 255 :: Vector Int16)
        , bench "decode/10k" $ nf (V.map unzigzag) (V.enumFromTo 0 511 :: Vector Word16)
        ]

    , bgroup "tokenize"
        [ bench "sparse" $ nf tokenize (V.fromList $ replicate 1000 0 ++ [1..100])
        , bench "dense"  $ nf tokenize (V.fromList [1..1000])
        , bench "uniform" $ nf tokenize (V.replicate 1000 0)
        ]

    , bgroup "rice"
        [ bgroup "encode" $
            [ bench ("k=" ++ show k) $
                nf encodeBlock (replicate blockSize (100 :: Word16))
            | k <- [0..8 :: Int]
            ]
        , bench "optimal-k" $
            nf optimalK (replicate blockSize 42 :: [Word16])
        ]

    , bgroup "pipeline" $
        [ bgroup "encode" $
            [ bench (show w ++ "x" ++ show h) $
                let img = makeGradient w h
                    hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 PAdaptive
                in nf (compress hdr) img
            | (w, h) <- sizes
            ]
        , bgroup "decode" $
            [ bench (show w ++ "x" ++ show h) $
                let img = makeGradient w h
                    hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 PAdaptive
                    encoded = compress hdr img
                in nf (decompress hdr) encoded
            | (w, h) <- sizes
            ]
        ]
    ]
```

- [ ] **Step 2: Run benchmarks**

```bash
stack bench
```

Expected: criterion runs all benchmark groups and prints timing results.

- [ ] **Step 3: Generate HTML report**

```bash
stack bench --benchmark-options="--output bench-report.html"
```

Expected: `bench-report.html` with interactive charts.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: criterion benchmarks for all pipeline stages"
```

---

### Task 16: End-to-End Smoke Test

**Files:**
- No new files — just running existing commands.

- [ ] **Step 1: Generate corpus**

```bash
stack run -- generate-corpus -o tests/corpus
```

- [ ] **Step 2: Encode a corpus image**

```bash
stack run -- encode tests/corpus/gradient_256x256.png -o /tmp/gradient.sgl
```

Expected: success message.

- [ ] **Step 3: Inspect the .sgl file**

```bash
stack run -- info /tmp/gradient.sgl
```

Expected: prints dimensions (256x256), RGB, Depth8, PAdaptive.

- [ ] **Step 4: Decode back to PNG**

```bash
stack run -- decode /tmp/gradient.sgl -o /tmp/gradient_decoded.png
```

Expected: success message.

- [ ] **Step 5: Verify round-trip on all corpus images**

```bash
for f in tests/corpus/*.png; do stack run -- verify "$f"; done
```

Expected: `PASS` for all images.

- [ ] **Step 6: Run bench on a corpus image**

```bash
stack run -- bench tests/corpus/gradient_256x256.png --iterations 5
```

Expected: predictor comparison table with ratios and timing.

- [ ] **Step 7: Run full test suite**

```bash
stack test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "chore: verify end-to-end smoke test passes"
```
