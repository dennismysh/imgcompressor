module Sigil.Codec.WaveletMut
  ( lift53Forward1DMut
  , lift53Inverse1DMut
  , dwt2DForwardMut
  , dwt2DInverseMut
  , dwtForwardMultiMut
  , dwtInverseMultiMut
  ) where

import Control.Monad (forM_)
import Control.Monad.ST (runST)
import Data.Int (Int32)
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM

lift53Forward1DMut :: VU.Vector Int32 -> (VU.Vector Int32, VU.Vector Int32)
lift53Forward1DMut xs
  | n == 0    = (VU.empty, VU.empty)
  | n == 1    = (xs, VU.empty)
  | otherwise = runST $ do
      let nDetail = n `div` 2
          nApprox = (n + 1) `div` 2
      detail <- VUM.new nDetail
      approx <- VUM.new nApprox
      forM_ [0 .. nDetail - 1] $ \i -> do
        let left   = xs `VU.unsafeIndex` (2 * i)
            center = xs `VU.unsafeIndex` (2 * i + 1)
            right  = if 2 * i + 2 < n
                       then xs `VU.unsafeIndex` (2 * i + 2)
                       else xs `VU.unsafeIndex` (2 * i)
        VUM.unsafeWrite detail i (center - (left + right) `div` 2)
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

lift53Inverse1DMut :: VU.Vector Int32 -> VU.Vector Int32 -> VU.Vector Int32
lift53Inverse1DMut approx detail
  | nApprox == 0 = VU.empty
  | nDetail == 0 = approx
  | otherwise = runST $ do
      let n = nApprox + nDetail
      evens  <- VUM.new nApprox
      result <- VUM.new n
      forM_ [0 .. nApprox - 1] $ \i -> do
        let dLeft  = if i > 0       then detail `VU.unsafeIndex` (i - 1)
                                    else detail `VU.unsafeIndex` 0
            dRight = if i < nDetail  then detail `VU.unsafeIndex` i
                                    else detail `VU.unsafeIndex` (nDetail - 1)
        VUM.unsafeWrite evens i (approx `VU.unsafeIndex` i - (dLeft + dRight + 2) `div` 4)
      evensFrozen <- VU.unsafeFreeze evens
      forM_ [0 .. n - 1] $ \idx ->
        if even idx
          then VUM.unsafeWrite result idx (evensFrozen `VU.unsafeIndex` (idx `div` 2))
          else do
            let i     = idx `div` 2
                left  = evensFrozen `VU.unsafeIndex` i
                right = if 2 * i + 2 < n
                          then evensFrozen `VU.unsafeIndex` (i + 1)
                          else evensFrozen `VU.unsafeIndex` i
            VUM.unsafeWrite result idx (detail `VU.unsafeIndex` i + (left + right) `div` 2)
      VU.unsafeFreeze result
  where
    nApprox = VU.length approx
    nDetail = VU.length detail

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
      rowBuf <- VUM.new (h * w)
      forM_ [0 .. w - 1] $ \x -> do
        let colLo = VU.generate hLow  $ \y -> colLayout `VU.unsafeIndex` (y * w + x)
            colHi = VU.generate hHigh $ \y -> colLayout `VU.unsafeIndex` ((hLow + y) * w + x)
            col = lift53Inverse1DMut colLo colHi
        forM_ [0 .. h - 1] $ \y ->
          VUM.unsafeWrite rowBuf (y * w + x) (col `VU.unsafeIndex` y)
      rowLayout <- VU.unsafeFreeze rowBuf
      result <- VUM.new (h * w)
      forM_ [0 .. h - 1] $ \y -> do
        let rowLo = VU.generate wLow  $ \i -> rowLayout `VU.unsafeIndex` (y * w + i)
            rowHi = VU.generate wHigh $ \i -> rowLayout `VU.unsafeIndex` (y * w + wLow + i)
            row = lift53Inverse1DMut rowLo rowHi
        forM_ [0 .. w - 1] $ \x ->
          VUM.unsafeWrite result (y * w + x) (row `VU.unsafeIndex` x)
      VU.unsafeFreeze result

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
