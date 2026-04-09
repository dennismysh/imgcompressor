module Sigil.Codec.Predict
  ( predict
  , residual
  , paeth
  , predictRow
  , unpredictRow
  , predictImage
  , unpredictImage
  , adaptiveRow
  ) where

import Data.Int (Int16)
import Data.List (minimumBy)
import Data.Ord (comparing)
import Data.Word (Word8)
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Sigil.Core.Types

predict :: PredictorId -> Word8 -> Word8 -> Word8 -> Word8
predict PNone     _ _ _ = 0
predict PSub      a _ _ = a
predict PUp       _ b _ = b
predict PAverage  a b _ = fromIntegral ((fromIntegral a + fromIntegral b :: Int) `div` 2)
predict PPaeth    a b c = paeth a b c
predict PGradient a b c = fromIntegral $ max 0 $ min 255
                            (fromIntegral a + fromIntegral b - fromIntegral c :: Int)
predict PAdaptive _ _ _ = error "adaptive is resolved per-row"

paeth :: Word8 -> Word8 -> Word8 -> Word8
paeth a b c =
  let p  = fromIntegral a + fromIntegral b - fromIntegral c :: Int
      pa = abs (p - fromIntegral a)
      pb = abs (p - fromIntegral b)
      pc = abs (p - fromIntegral c)
  in if pa <= pb && pa <= pc then a
     else if pb <= pc then b
     else c

residual :: PredictorId -> Word8 -> Word8 -> Word8 -> Word8 -> Int16
residual pid a b c x = fromIntegral x - fromIntegral (predict pid a b c)

predictRow :: PredictorId -> Row -> Row -> Int -> VU.Vector Int16
predictRow pid prevRow curRow ch = VU.imap go curRow
  where
    go i x =
      let a = if i >= ch then curRow VU.! (i - ch) else 0
          b = prevRow VU.! i
          c = if i >= ch then prevRow VU.! (i - ch) else 0
      in residual pid a b c x

unpredictRow :: PredictorId -> Row -> VU.Vector Int16 -> Int -> Row
unpredictRow pid prevRow residuals ch =
  VU.unfoldrExactN (VU.length residuals) step (0, VU.empty)
  where
    step (i, built) =
      let a = if i >= ch then built VU.! (i - ch) else 0
          b = prevRow VU.! i
          c = if i >= ch then prevRow VU.! (i - ch) else 0
          predicted = predict pid a b c
          x = fromIntegral (fromIntegral predicted + (residuals VU.! i) :: Int16) :: Word8
      in (x, (i + 1, VU.snoc built x))

predictImage :: PredictorId -> Header -> Image -> (Vector PredictorId, Vector (VU.Vector Int16))
predictImage pid hdr img
  | pid == PAdaptive =
      let results = V.imap (\i row ->
            let prev = if i == 0 then zeroRow else img V.! (i - 1)
            in adaptiveRow prev row ch) img
      in (V.map fst results, V.map snd results)
  | otherwise =
      let residuals = V.imap (\i row ->
            let prev = if i == 0 then zeroRow else img V.! (i - 1)
            in predictRow pid prev row ch) img
      in (V.replicate (V.length img) pid, residuals)
  where
    ch = channels (colorSpace hdr)
    rl = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
    zeroRow = VU.replicate rl 0

unpredictImage :: Header -> (Vector PredictorId, Vector (VU.Vector Int16)) -> Image
unpredictImage hdr (pids, residuals) =
  V.unfoldrExactN (V.length residuals) step (0, V.empty)
  where
    ch = channels (colorSpace hdr)
    rl = fromIntegral (width hdr) * ch * bytesPerChannel (bitDepth hdr)
    zeroRow = VU.replicate rl 0
    step (i, prevRows) =
      let prevRow = if i == 0 then zeroRow else prevRows V.! (i - 1)
          row = unpredictRow (pids V.! i) prevRow (residuals V.! i) ch
      in (row, (i + 1, V.snoc prevRows row))

adaptiveRow :: Row -> Row -> Int -> (PredictorId, VU.Vector Int16)
adaptiveRow prevRow curRow ch =
  minimumBy (comparing cost) candidates
  where
    candidates =
      [ (pid, predictRow pid prevRow curRow ch)
      | pid <- [PNone .. PGradient]
      ]
    cost (_, rs) = VU.sum (VU.map (fromIntegral . abs) rs :: VU.Vector Int)
