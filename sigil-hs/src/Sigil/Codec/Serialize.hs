module Sigil.Codec.Serialize
  ( zigzag32
  , unzigzag32
  , encodeVarint
  , decodeVarint
  , dpcmEncode
  , dpcmDecode
  , packSubband
  , unpackSubband
  , packLLSubband
  , unpackLLSubband
  ) where

import Data.Bits ((.&.), xor, shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Data.Word (Word32)
import qualified Data.Vector.Unboxed as VU

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

-- | DPCM encode: per-row delta prediction.
-- First value of each row is sent raw; subsequent values are (current - previous).
dpcmEncode :: Int -> VU.Vector Int32 -> VU.Vector Int32
dpcmEncode w v = VU.generate (VU.length v) $ \i ->
  if i `mod` w == 0
    then v VU.! i
    else (v VU.! i) - (v VU.! (i - 1))

-- | Inverse DPCM: prefix-sum per row.
dpcmDecode :: Int -> VU.Vector Int32 -> VU.Vector Int32
dpcmDecode w v = VU.generate (VU.length v) $ \i ->
  if i `mod` w == 0
    then v VU.! i
    else go v w i
  where
    go vec width idx =
      let rowStart = (idx `div` width) * width
      in VU.foldl' (+) 0 (VU.slice rowStart (idx - rowStart + 1) vec)

-- | Pack a detail subband: zigzag each value, then varint-encode.
packSubband :: VU.Vector Int32 -> ByteString
packSubband v = BS.concat $ map (encodeVarint . zigzag32) (VU.toList v)

-- | Unpack a detail subband: read `count` varint values, un-zigzag each.
unpackSubband :: Int -> ByteString -> (VU.Vector Int32, ByteString)
unpackSubband count bs = go count bs []
  where
    go 0 remaining acc = (VU.fromList (reverse acc), remaining)
    go n remaining acc =
      let (val, rest) = decodeVarint remaining
      in go (n - 1) rest (unzigzag32 val : acc)

-- | Pack the LL subband: DPCM with given row width, then zigzag + varint.
packLLSubband :: Int -> VU.Vector Int32 -> ByteString
packLLSubband w v = packSubband (dpcmEncode w v)

-- | Unpack the LL subband: read varints, un-zigzag, inverse DPCM.
unpackLLSubband :: Int -> Int -> ByteString -> (VU.Vector Int32, ByteString)
unpackLLSubband w count bs =
  let (dpcmed, rest) = unpackSubband count bs
  in (dpcmDecode w dpcmed, rest)
