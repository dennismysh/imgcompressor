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
