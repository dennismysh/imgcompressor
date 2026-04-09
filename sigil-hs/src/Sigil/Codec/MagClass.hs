module Sigil.Codec.MagClass
  ( encodeCoeff
  , decodeCoeff
  , encodeCoeffs
  , decodeCoeffs
  ) where

import Data.Bits (shiftR, shiftL, (.|.), testBit)
import Data.Int (Int32, Int64)
import Data.Word (Word16, Word32)
import qualified Data.Vector.Unboxed as VU

-- | Encode a signed Int32 DWT coefficient into a (magnitude_class, bits) pair.
--
-- magnitude_class k means the absolute value is in [2^(k-1), 2^k - 1].
-- k=0 is reserved for zero (0 bits emitted).
-- For k>=1: emit sign bit (True = negative) followed by (k-1) residual bits MSB-first.
encodeCoeff :: Int32 -> (Word16, [Bool])
encodeCoeff 0 = (0, [])
encodeCoeff v =
  let absV = fromIntegral (abs (fromIntegral v :: Int64)) :: Word32
      k    = ilog2 absV + 1
      sign = v < 0
      residual = absV - (1 `shiftL` (k - 1))
      resBits  = toBitsMSB (k - 1) residual
  in (fromIntegral k, sign : resBits)

ilog2 :: Word32 -> Int
ilog2 1 = 0
ilog2 n = 1 + ilog2 (n `shiftR` 1)

toBitsMSB :: Int -> Word32 -> [Bool]
toBitsMSB 0 _ = []
toBitsMSB w n = [testBit n (w - 1 - i) | i <- [0 .. w - 1]]

-- | Decode a (magnitude_class, bits) pair back to a signed Int32.
decodeCoeff :: Word16 -> [Bool] -> Int32
decodeCoeff 0 _ = 0
decodeCoeff cls bits =
  let k = fromIntegral cls :: Int
      sign = head bits
      resBits = tail bits
      base = 1 `shiftL` (k - 1) :: Word32
      residual = fromBitsMSB resBits
      absV = base + residual
      val = fromIntegral absV :: Int32
  in if sign then -val else val

fromBitsMSB :: [Bool] -> Word32
fromBitsMSB = foldl (\acc b -> (acc `shiftL` 1) .|. (if b then 1 else 0)) 0

-- | Encode a vector of coefficients, returning parallel lists of
-- magnitude classes and the concatenated bit stream.
encodeCoeffs :: VU.Vector Int32 -> ([Word16], [Bool])
encodeCoeffs v =
  let pairs   = map encodeCoeff (VU.toList v)
      classes = map fst pairs
      bits    = concatMap snd pairs
  in (classes, bits)

-- | Decode a vector of coefficients from the magnitude-class list and bit stream.
decodeCoeffs :: [Word16] -> [Bool] -> VU.Vector Int32
decodeCoeffs classes bits = VU.fromList (go classes bits)
  where
    go [] _ = []
    go (cls : rest) bs =
      let k = fromIntegral cls :: Int
          (myBits, remaining) = splitAt k bs
          val = decodeCoeff cls myBits
      in val : go rest remaining
