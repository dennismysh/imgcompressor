module Sigil.Codec.ColorTransform
  ( forwardRCT
  , inverseRCT
  ) where

import Data.Int  (Int32)
import Data.Word (Word8)
import qualified Data.Vector.Unboxed as VU

-- | Forward Reversible Color Transform.
--
-- Takes width, height, and interleaved RGB pixel data (width * height * 3 bytes).
-- Returns three separate channel arrays of Int32: (Y, Cb, Cr).
--
-- For grayscale (1 channel): just converts Word8 -> Int32.
-- For RGBA (4 channels): applies RCT to RGB, passes alpha separately.
forwardRCT :: Int -> Int -> VU.Vector Word8 -> (VU.Vector Int32, VU.Vector Int32, VU.Vector Int32)
forwardRCT w h pixels
  | npx == 0  = (VU.empty, VU.empty, VU.empty)
  | otherwise = (yChannel, cbChannel, crChannel)
  where
    npx = w * h
    yChannel  = VU.generate npx $ \i ->
      let r = fromIntegral (pixels VU.! (i * 3))     :: Int32
          g = fromIntegral (pixels VU.! (i * 3 + 1)) :: Int32
          b = fromIntegral (pixels VU.! (i * 3 + 2)) :: Int32
      in (r + 2 * g + b) `div` 4
    cbChannel = VU.generate npx $ \i ->
      let g = fromIntegral (pixels VU.! (i * 3 + 1)) :: Int32
          b = fromIntegral (pixels VU.! (i * 3 + 2)) :: Int32
      in b - g
    crChannel = VU.generate npx $ \i ->
      let r = fromIntegral (pixels VU.! (i * 3))     :: Int32
          g = fromIntegral (pixels VU.! (i * 3 + 1)) :: Int32
      in r - g

-- | Inverse Reversible Color Transform.
--
-- Takes width, height, and three channel arrays (Y, Cb, Cr).
-- Returns interleaved RGB pixel data as Word8.
inverseRCT :: Int -> Int -> (VU.Vector Int32, VU.Vector Int32, VU.Vector Int32) -> VU.Vector Word8
inverseRCT w h (yChannel, cbChannel, crChannel)
  | npx == 0  = VU.empty
  | otherwise = VU.generate (npx * 3) $ \idx ->
      let i = idx `div` 3
          c = idx `mod` 3
          yr = yChannel  VU.! i
          cb = cbChannel VU.! i
          cr = crChannel VU.! i
          g  = yr - (cb + cr) `div` 4
          r  = cr + g
          b  = cb + g
      in case c of
           0 -> clampWord8 r
           1 -> clampWord8 g
           _ -> clampWord8 b
  where
    npx = w * h

clampWord8 :: Int32 -> Word8
clampWord8 x
  | x < 0    = 0
  | x > 255  = 255
  | otherwise = fromIntegral x
