module Sigil.Codec.SubbandCoder
  ( encodeSubband
  , decodeSubband
  ) where

import Data.Bits ((.&.), (.|.), shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Data.List (foldl')
import Data.Vector (Vector)
import Data.Word (Word8, Word16, Word32)

import Sigil.Codec.MagClass (encodeCoeffs, decodeCoeffs)
import Sigil.Codec.ANS (ansEncode, ansDecode)
import Sigil.Codec.Serialize (encodeVarint, decodeVarint)

-- | Encode a vector of Int32 DWT coefficients into a self-contained ByteString blob.
--
-- Format:
--   [varint: rawBitCount]
--   [ANS blob — self-delimiting, encodes magnitude classes]
--   [raw bits — packed MSB-first, ceil(rawBitCount/8) bytes]
encodeSubband :: Vector Int32 -> ByteString
encodeSubband v =
  let (classes, rawBits) = encodeCoeffs v
      ansBlob   = ansEncode classes
      rawBlob   = packBits rawBits
      bitCount  = length rawBits
      varint    = encodeVarint (fromIntegral bitCount)
  in varint <> ansBlob <> rawBlob

-- | Decode a blob produced by 'encodeSubband', given the number of coefficients.
decodeSubband :: Int -> ByteString -> Vector Int32
decodeSubband 0 _ = mempty
decodeSubband n bs =
  let (rawBitCount, afterVarint) = decodeVarint bs
      numBits  = fromIntegral rawBitCount :: Int
      ansBlob  = afterVarint
      ansSize  = computeANSBlobSize ansBlob
      classes  = ansDecode ansBlob n
      rawBlob  = BS.drop ansSize afterVarint
      rawBits  = unpackBits numBits rawBlob
  in decodeCoeffs classes rawBits

-- | Compute the byte size of an ANS blob by reading its header.
--
-- ANS serialization format (from ANS.hs):
--   [u32 BE: total_samples]      -- offset 0
--   [u16 BE: num_unique_symbols] -- offset 4
--   [num_unique * (u16 sym + u32 freq)]  -- 6 bytes each, starting at offset 6
--   [u32 BE: final_state]
--   [u32 BE: bitstream_length_in_bits]
--   [bitstream bytes — packed MSB-first]
computeANSBlobSize :: ByteString -> Int
computeANSBlobSize bs =
  let numUnique      = fromIntegral (getU16BE bs 4) :: Int
      freqEnd        = 6 + numUnique * 6
      bitCount       = fromIntegral (getU32BE bs (freqEnd + 4)) :: Int
      bitstreamBytes = (bitCount + 7) `div` 8
  in freqEnd + 8 + bitstreamBytes

-- ── Bit packing helpers ───────────────────────────────────

-- | Pack a list of Bool (MSB-first) into bytes.
packBits :: [Bool] -> ByteString
packBits bits = BS.pack (go bits)
  where
    go [] = []
    go bs =
      let (chunk, rest) = splitAt 8 bs
          padded = chunk ++ replicate (8 - length chunk) False
          byte   = foldl' (\acc b -> (acc `shiftL` 1) .|. (if b then 1 else 0)) (0 :: Word8) padded
      in byte : go rest

-- | Unpack bytes into a list of Bool (MSB-first), limited to n bits.
unpackBits :: Int -> ByteString -> [Bool]
unpackBits n bs = take n $ concatMap byteToBits (BS.unpack bs)
  where
    byteToBits w = [ w .&. (1 `shiftL` (7 - i)) /= 0 | i <- [0..7] ]

-- ── Binary helpers ────────────────────────────────────────

getU32BE :: ByteString -> Int -> Word32
getU32BE bs off =
  (fromIntegral (BS.index bs off)       `shiftL` 24)
  .|. (fromIntegral (BS.index bs (off + 1)) `shiftL` 16)
  .|. (fromIntegral (BS.index bs (off + 2)) `shiftL` 8)
  .|.  fromIntegral (BS.index bs (off + 3))

getU16BE :: ByteString -> Int -> Word16
getU16BE bs off =
  (fromIntegral (BS.index bs off)       `shiftL` 8)
  .|.  fromIntegral (BS.index bs (off + 1))
