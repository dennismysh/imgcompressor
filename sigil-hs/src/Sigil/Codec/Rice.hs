{-# OPTIONS_GHC -Wno-unused-top-binds #-}
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
