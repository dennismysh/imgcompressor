{-# LANGUAGE NoImplicitPrelude #-}
module Sigil.Codec.Pipeline
  ( Stage(..)
  , compress
  , decompress
  ) where

import Prelude hiding (id, (.))
import Control.Category (Category(..), (>>>))
import qualified Data.Function as F

import Data.Bits ((.&.), shiftR, shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int16)
import Data.Word (Word8, Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.Predict (predictImage, unpredictImage)
import Sigil.Codec.ZigZag (zigzag, unzigzag)
import Sigil.Codec.Token (Token(..), tokenize, untokenize)
import Sigil.Codec.Rice

newtype Stage a b = Stage { runStage :: a -> b }

instance Category Stage where
  id = Stage F.id
  (Stage f) . (Stage g) = Stage (f F.. g)

-- | Compress an image to raw encoded bytes (SDAT payload).
compress :: Header -> Image -> ByteString
compress hdr img = runStage (compressPipeline hdr) img

-- | Decompress raw encoded bytes back to an image.
decompress :: Header -> ByteString -> Either SigilError Image
decompress hdr bs = Right $ runStage (decompressPipeline hdr) bs

compressPipeline :: Header -> Stage Image ByteString
compressPipeline hdr =
      Stage (predictImage hdr)
  >>> Stage applyZigZag
  >>> Stage (encodeData hdr)

decompressPipeline :: Header -> Stage ByteString Image
decompressPipeline hdr =
      Stage (decodeData hdr)
  >>> Stage unapplyZigZag
  >>> Stage (unpredictImage hdr)

applyZigZag :: (Vector PredictorId, Vector (Vector Int16))
            -> (Vector PredictorId, Vector (Vector Word16))
applyZigZag (pids, residuals) = (pids, V.map (V.map zigzag) residuals)

unapplyZigZag :: (Vector PredictorId, Vector (Vector Word16))
              -> (Vector PredictorId, Vector (Vector Int16))
unapplyZigZag (pids, encoded) = (pids, V.map (V.map unzigzag) encoded)

encodeData :: Header -> (Vector PredictorId, Vector (Vector Word16)) -> ByteString
encodeData hdr (pids, rows) =
  let pidBytes = if predictor hdr == PAdaptive
                 then BS.pack $ V.toList $ V.map (fromIntegral . fromEnum) pids
                 else BS.empty
      flat   = V.toList $ V.concatMap F.id rows
      tokens = tokenize (V.fromList flat)
  in pidBytes <> encodeTokenStream tokens

decodeData :: Header -> ByteString -> (Vector PredictorId, Vector (Vector Word16))
decodeData hdr bs =
  let numRows      = fromIntegral (height hdr)
      ch           = channels (colorSpace hdr)
      rowLen       = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
      totalSamples = numRows * rowLen
      (pids, rest) =
        if predictor hdr == PAdaptive
        then let pidBs = BS.take numRows bs
                 ps    = V.fromList $ Prelude.map (toEnum . fromIntegral) $ BS.unpack pidBs
             in (ps, BS.drop numRows bs)
        else (V.replicate numRows (predictor hdr), bs)
      tokens = decodeTokenStream rest totalSamples
      flat   = untokenize tokens
      rows   = V.fromList [ V.slice (i * rowLen) rowLen flat | i <- [0 .. numRows - 1] ]
  in (pids, rows)

-- ---------------------------------------------------------------------------
-- Token stream encoding
--
-- Format (bit-packed):
--   [16-bit numBlocks] [4-bit k per block] [token bits]
--
-- Token bits per token:
--   1-bit flag:
--     1 → TValue:   Rice-coded value (using k for the block owning this TValue)
--     0 → TZeroRun: 16-bit run length
--
-- "Block" = a window of up to blockSize consecutive TValues.
-- TZeroRuns are pass-through and do not consume a block's TValue budget.
-- The decoder uses totalSamples (from the header) to know when to stop.
-- ---------------------------------------------------------------------------

encodeTokenStream :: [Token] -> ByteString
encodeTokenStream tokens =
  let values    = [ v | TValue v <- tokens ]
      blocks    = chunksOf blockSize values
      ks        = Prelude.map optimalK blocks
      numBlocks = Prelude.length ks
      w0 = newBitWriter
      -- numBlocks as 32 bits (two 16-bit halves, MSB first)
      w1a = writeBits 16 (fromIntegral (numBlocks `shiftR` 16) :: Word16) w0
      w1 = writeBits 16 (fromIntegral (numBlocks .&. 0xFFFF) :: Word16) w1a
      -- k values (4 bits each)
      w2 = Prelude.foldl (\w k -> writeBits 4 (fromIntegral k) w) w1 ks
      -- token bitstream: each TValue encoded with its block's k
      annotated = annotateWithKs tokens ks
      w3 = Prelude.foldl encodeAnnotatedToken w2 annotated
  in flushBits w3

-- | Tag each token with the k value of its owning block.
-- TZeroRuns are tagged with the current block's k (irrelevant for encoding).
annotateWithKs :: [Token] -> [Word8] -> [(Word8, Token)]
annotateWithKs []     _      = []
annotateWithKs tokens []     = Prelude.map (\t -> (0, t)) tokens
annotateWithKs tokens (k:ks) =
  let (blockToks, rest) = takeBlock blockSize tokens
  in Prelude.map (\t -> (k, t)) blockToks
     Prelude.++ annotateWithKs rest ks

encodeAnnotatedToken :: BitWriter -> (Word8, Token) -> BitWriter
encodeAnnotatedToken w (_, TZeroRun n) = writeBits 16 n $ writeBit False w
encodeAnnotatedToken w (k, TValue v)   = riceEncode k v $ writeBit True w

-- | Collect tokens for one block: consume up to 'budget' TValues.
takeBlock :: Int -> [Token] -> ([Token], [Token])
takeBlock _ []                           = ([], [])
takeBlock 0 rest                         = ([], rest)
takeBlock budget (t@(TZeroRun _) : rest) =
  let (taken, remaining) = takeBlock budget rest
  in (t : taken, remaining)
takeBlock budget (t@(TValue _) : rest) =
  let (taken, remaining) = takeBlock (budget - 1) rest
  in (t : taken, remaining)

-- ---------------------------------------------------------------------------
-- Decoding
-- ---------------------------------------------------------------------------

-- | Decode a token stream. Uses totalSamples (from the header) to know
-- when to stop reading tokens.
decodeTokenStream :: ByteString -> Int -> [Token]
decodeTokenStream bs totalSamples =
  let r0 = newBitReader bs
      -- numBlocks as 32 bits (two 16-bit halves, MSB first)
      (hi, r0a)        = readBits 16 r0
      (lo, r1)         = readBits 16 r0a
      numBlocks        = (fromIntegral hi `shiftL` 16) .|. fromIntegral lo :: Int
      (ks, r2)         = readKs numBlocks r1
  in decodeSamples totalSamples ks 0 r2

readKs :: Int -> BitReader -> ([Word8], BitReader)
readKs 0 r = ([], r)
readKs n r =
  let (kVal, r')  = readBits 4 r
      (rest, r'') = readKs (n - 1) r'
  in (fromIntegral kVal : rest, r'')

-- | Decode tokens until remainingSamples reaches 0.
-- TValue consumes 1 sample, TZeroRun n consumes n samples.
-- k values advance per blockSize TValues (not samples).
decodeSamples :: Int -> [Word8] -> Int -> BitReader -> [Token]
decodeSamples remaining _ _ _ | remaining <= 0 = []
decodeSamples remaining ks tvalPos r =
  let k = case ks of { (x:_) -> x; [] -> 0 }
      (flag, r1) = readBit r
  in if flag
     then -- TValue: consumes 1 sample, advances block position
       let (val, r2) = riceDecode k r1
           tvalPos'  = tvalPos + 1
           (ks', tvalPos'') = if tvalPos' >= blockSize
                              then (Prelude.drop 1 ks, 0)
                              else (ks, tvalPos')
       in TValue val : decodeSamples (remaining - 1) ks' tvalPos'' r2
     else -- TZeroRun: consumes runLen samples, doesn't affect block position
       let (runLen, r2) = readBits 16 r1
       in TZeroRun runLen : decodeSamples (remaining - fromIntegral runLen) ks tvalPos r2

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (a, b) = Prelude.splitAt n xs in a : chunksOf n b
