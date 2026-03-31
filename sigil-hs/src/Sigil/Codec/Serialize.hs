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
import Data.Word (Word32)

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
          let b    = BS.head bs
              rest = BS.tail bs
              val  = acc .|. (fromIntegral (b .&. 0x7F) `shiftL` shift)
          in if b .&. 0x80 == 0
               then (val, rest)
               else go val (shift + 7) rest
