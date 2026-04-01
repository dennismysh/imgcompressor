module Sigil.Codec.WaveletMut
  ( lift53Forward1DMut
  , lift53Inverse1DMut
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
