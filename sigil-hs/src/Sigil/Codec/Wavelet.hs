module Sigil.Codec.Wavelet
  ( lift53Forward1D
  , lift53Inverse1D
  , dwt2DForward
  , dwt2DInverse
  , dwtForwardMulti
  , dwtInverseMulti
  , computeLevels
  ) where

import Data.Int (Int32)
import Data.Vector (Vector)
import qualified Data.Vector as V

------------------------------------------------------------------------
-- 1D Le Gall 5/3 lifting
------------------------------------------------------------------------

-- | Forward 1D integer 5/3 wavelet transform.
-- Returns (approximation, detail) coefficients.
lift53Forward1D :: Vector Int32 -> (Vector Int32, Vector Int32)
lift53Forward1D xs
  | n == 0    = (V.empty, V.empty)
  | n == 1    = (xs, V.empty)
  | otherwise = (approx, detail)
  where
    n = V.length xs
    nDetail = n `div` 2
    nApprox = (n + 1) `div` 2

    -- Step 1: Predict (compute detail coefficients)
    detail = V.generate nDetail $ \i ->
      let left  = xs V.! (2 * i)
          right = if 2 * i + 2 < n
                    then xs V.! (2 * i + 2)
                    else xs V.! (2 * i)  -- mirror at right boundary
      in xs V.! (2 * i + 1) - (left + right) `div` 2

    -- Step 2: Update (compute approximation coefficients)
    approx = V.generate nApprox $ \i ->
      let dLeft  = if i > 0       then detail V.! (i - 1)       else detail V.! 0
          dRight = if i < nDetail  then detail V.! i             else detail V.! (nDetail - 1)
      in xs V.! (2 * i) + (dLeft + dRight + 2) `div` 4

-- | Inverse 1D integer 5/3 wavelet transform.
-- Takes approximation and detail coefficients, returns reconstructed signal.
lift53Inverse1D :: Vector Int32 -> Vector Int32 -> Vector Int32
lift53Inverse1D approx detail
  | nApprox == 0 = V.empty
  | nDetail == 0 = approx  -- length 1: just the single sample
  | otherwise    = result
  where
    nApprox = V.length approx
    nDetail = V.length detail
    n       = nApprox + nDetail

    -- Step 1: Undo update (recover even samples)
    evens = V.generate nApprox $ \i ->
      let dLeft  = if i > 0       then detail V.! (i - 1)       else detail V.! 0
          dRight = if i < nDetail  then detail V.! i             else detail V.! (nDetail - 1)
      in approx V.! i - (dLeft + dRight + 2) `div` 4

    -- Step 2: Undo predict (recover odd samples)
    result = V.generate n $ \idx ->
      if even idx
        then evens V.! (idx `div` 2)
        else
          let i     = idx `div` 2
              left  = evens V.! i
              right = if 2 * i + 2 < n
                        then evens V.! (i + 1)
                        else evens V.! i  -- mirror at right boundary
          in detail V.! i + (left + right) `div` 2

------------------------------------------------------------------------
-- 2D separable DWT
------------------------------------------------------------------------

-- | Forward 2D DWT.
-- Takes width, height, and a flat row-major Vector Int32.
-- Returns (LL, LH, HL, HH) subbands.
dwt2DForward :: Int -> Int -> Vector Int32
             -> (Vector Int32, Vector Int32, Vector Int32, Vector Int32)
dwt2DForward w h arr = (ll, lh, hl, hh)
  where
    -- Step 1: Transform rows
    wLow  = (w + 1) `div` 2
    wHigh = w `div` 2

    -- After row transform: width is wLow + wHigh = w, stored as [low|high] per row
    rowTransformed = V.generate (h * w) $ \idx ->
      let y   = idx `div` w
          x   = idx `mod` w
          row = extractRow arr w y
          (lo, hi) = lift53Forward1D row
      in if x < wLow
           then lo V.! x
           else hi V.! (x - wLow)

    -- Step 2: Transform columns of the row-transformed result
    hLow  = (h + 1) `div` 2
    hHigh = h `div` 2

    -- Extract a column from rowTransformed
    getCol x = V.generate h $ \y -> rowTransformed V.! (y * w + x)

    -- Transform each column and store results
    colResults = V.generate w $ \x ->
      let col = getCol x
          (lo, hi) = lift53Forward1D col
      in (lo, hi)

    -- Reassemble into LL, LH, HL, HH
    ll = V.generate (hLow * wLow) $ \idx ->
      let y = idx `div` wLow
          x = idx `mod` wLow
          (lo, _) = colResults V.! x
      in lo V.! y

    lh = V.generate (hLow * wHigh) $ \idx ->
      let y = idx `div` wHigh
          x = idx `mod` wHigh
          (lo, _) = colResults V.! (x + wLow)
      in lo V.! y

    hl = V.generate (hHigh * wLow) $ \idx ->
      let y = idx `div` wLow
          x = idx `mod` wLow
          (_, hi) = colResults V.! x
      in hi V.! y

    hh = V.generate (hHigh * wHigh) $ \idx ->
      let y = idx `div` wHigh
          x = idx `mod` wHigh
          (_, hi) = colResults V.! (x + wLow)
      in hi V.! y

-- | Inverse 2D DWT.
-- Takes width, height, and (LL, LH, HL, HH) subbands.
-- Returns the reconstructed flat row-major Vector Int32.
dwt2DInverse :: Int -> Int -> (Vector Int32, Vector Int32, Vector Int32, Vector Int32)
             -> Vector Int32
dwt2DInverse w h (ll, lh, hl, hh) = result
  where
    wLow  = (w + 1) `div` 2
    wHigh = w `div` 2
    hLow  = (h + 1) `div` 2
    hHigh = h `div` 2

    -- Step 1: Inverse column transform
    -- Reconstruct each column from its low and high parts
    colReconstructed = V.generate w $ \x ->
      let (colLo, colHi) =
            if x < wLow
              then
                -- Left half: low-pass columns — lows from LL, highs from HL
                ( V.generate hLow  $ \y -> ll V.! (y * wLow + x)
                , V.generate hHigh $ \y -> hl V.! (y * wLow + x)
                )
              else
                -- Right half: high-pass columns — lows from LH, highs from HH
                let x' = x - wLow
                in ( V.generate hLow  $ \y -> lh V.! (y * wHigh + x')
                   , V.generate hHigh $ \y -> hh V.! (y * wHigh + x')
                   )
      in lift53Inverse1D colLo colHi

    -- After inverse column transform: h rows, each w wide,
    -- but stored as columns. Rearrange into row-major.
    rowTransformed = V.generate (h * w) $ \idx ->
      let y = idx `div` w
          x = idx `mod` w
      in (colReconstructed V.! x) V.! y

    -- Step 2: Inverse row transform
    result = V.generate (h * w) $ \idx ->
      let y = idx `div` w
          x = idx `mod` w
          rowLo = V.generate wLow  $ \i -> rowTransformed V.! (y * w + i)
          rowHi = V.generate wHigh $ \i -> rowTransformed V.! (y * w + wLow + i)
          row   = lift53Inverse1D rowLo rowHi
      in row V.! x

------------------------------------------------------------------------
-- Multi-level DWT
------------------------------------------------------------------------

-- | Forward multi-level DWT.
-- Returns (final_LL, [(LH, HL, HH) from deepest to shallowest]).
dwtForwardMulti :: Int -> Int -> Int -> Vector Int32
                -> (Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)])
dwtForwardMulti levels w h arr = go levels w h arr []
  where
    go 0 _ _ ll bands = (ll, bands)
    go n cw ch img bands =
      let (ll, lh, hl, hh) = dwt2DForward cw ch img
          cw' = (cw + 1) `div` 2
          ch' = (ch + 1) `div` 2
      in go (n - 1) cw' ch' ll ((lh, hl, hh) : bands)

-- | Inverse multi-level DWT.
-- Takes the number of levels, original width, original height,
-- the final LL subband, and the list of (LH, HL, HH) from deepest to shallowest.
dwtInverseMulti :: Int -> Int -> Int -> Vector Int32
                -> [(Vector Int32, Vector Int32, Vector Int32)]
                -> Vector Int32
dwtInverseMulti levels w h ll bands = go levels sizes ll bands
  where
    -- Compute the sizes at each level (from deepest to shallowest)
    sizes = reverse $ take levels $ iterate shrink (w, h)
    shrink (cw, ch) = ((cw + 1) `div` 2, (ch + 1) `div` 2)

    go _ [] currentLL [] = currentLL
    go _ ((cw, ch) : rest) currentLL ((lh, hl, hh) : restBands) =
      let reconstructed = dwt2DInverse cw ch (currentLL, lh, hl, hh)
      in go (levels - 1) rest reconstructed restBands
    go _ _ currentLL _ = currentLL  -- fallback: no more bands

-- | Compute the number of decomposition levels for a given image size.
-- Formula: max 1 (min 5 (floor(log2(min(w,h))) - 3))
computeLevels :: Int -> Int -> Int
computeLevels w h
  | minDim <= 0 = 1
  | otherwise   = max 1 (min 5 (floorLog2 minDim - 3))
  where
    minDim = min w h
    floorLog2 :: Int -> Int
    floorLog2 n = go' n 0
      where
        go' 1 acc = acc
        go' x acc = go' (x `div` 2) (acc + 1)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

extractRow :: Vector Int32 -> Int -> Int -> Vector Int32
extractRow arr w y = V.generate w $ \x -> arr V.! (y * w + x)
