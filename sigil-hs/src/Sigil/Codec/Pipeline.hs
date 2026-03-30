{-# LANGUAGE NoImplicitPrelude #-}
module Sigil.Codec.Pipeline
  ( Stage(..)
  , compress
  , decompress
  ) where

import Prelude hiding (id, (.))
import Control.Category (Category(..), (>>>))
import qualified Data.Function as F

import Data.Bits ((.&.), (.|.), shiftR, shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int16)
import Data.Word (Word8, Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

import qualified Codec.Compression.Zlib as Z

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.Predict (predictImage, unpredictImage)
import Sigil.Codec.ZigZag (zigzag, unzigzag)

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
      flat = V.toList $ V.concatMap F.id rows
      -- Pack Word16 values into bytes (big-endian)
      packed = BS.pack $ concatMap (\w -> [fromIntegral (w `shiftR` 8), fromIntegral (w .&. 0xFF)]) flat
      -- Compress with zlib
      compressed = BL.toStrict $ Z.compress $ BL.fromStrict packed
  in pidBytes <> compressed

decodeData :: Header -> ByteString -> (Vector PredictorId, Vector (Vector Word16))
decodeData hdr bs =
  let numRows = fromIntegral (height hdr)
      ch = channels (colorSpace hdr)
      rowLen = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
      (pids, rest) = if predictor hdr == PAdaptive
                     then (V.fromList $ Prelude.map (toEnum . fromIntegral) $ BS.unpack $ BS.take numRows bs,
                           BS.drop numRows bs)
                     else (V.replicate numRows (predictor hdr), bs)
      -- Decompress with zlib
      decompressed = BL.toStrict $ Z.decompress $ BL.fromStrict rest
      -- Unpack bytes to Word16 values (big-endian)
      flat = V.fromList $ unpackWord16s (BS.unpack decompressed)
      rows = V.fromList [ V.slice (i * rowLen) rowLen flat | i <- [0..numRows-1] ]
  in (pids, rows)

unpackWord16s :: [Word8] -> [Word16]
unpackWord16s [] = []
unpackWord16s [_] = []  -- odd byte, ignore
unpackWord16s (hi:lo:rest) = (fromIntegral hi `shiftL` 8 .|. fromIntegral lo) : unpackWord16s rest
