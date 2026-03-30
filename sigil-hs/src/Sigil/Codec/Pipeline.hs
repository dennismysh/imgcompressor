{-# LANGUAGE NoImplicitPrelude #-}
module Sigil.Codec.Pipeline
  ( Stage(..)
  , compress
  , decompress
  ) where

import Prelude hiding (id, (.))
import Control.Category (Category(..), (>>>))
import qualified Data.Function as F

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int16)
import Data.Word (Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.Predict (predictImage, unpredictImage)
import Sigil.Codec.ZigZag (zigzag, unzigzag)
import Sigil.Codec.ANS (ansEncode, ansDecode)

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
  in pidBytes <> ansEncode flat

decodeData :: Header -> ByteString -> (Vector PredictorId, Vector (Vector Word16))
decodeData hdr bs =
  let numRows = fromIntegral (height hdr)
      ch = channels (colorSpace hdr)
      rowLen = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
      totalSamples = numRows * rowLen
      (pids, rest) = if predictor hdr == PAdaptive
                     then (V.fromList $ map (toEnum . fromIntegral) $ BS.unpack $ BS.take numRows bs,
                           BS.drop numRows bs)
                     else (V.replicate numRows (predictor hdr), bs)
      flat = V.fromList $ ansDecode rest totalSamples
      rows = V.fromList [ V.slice (i * rowLen) rowLen flat | i <- [0..numRows-1] ]
  in (pids, rows)
