module Sigil.Codec.Pipeline
  ( compress
  , decompress
  ) where

import Data.Bits (shiftR, shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int32)
import Data.Word (Word8)
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import qualified Codec.Compression.Zlib as Z

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.ColorTransform (forwardRCT, inverseRCT)
import Sigil.Codec.Wavelet (computeLevels)
import Sigil.Codec.WaveletMut (dwtForwardMultiMut, dwtInverseMultiMut)
import Sigil.Codec.Serialize (packSubband, unpackSubband, packLLSubband, unpackLLSubband, encodeVarint, decodeVarint)

------------------------------------------------------------------------
-- SDAT payload format (DwtLossless):
--   [u8: num_levels]
--   [u8: color_transform — 0=none, 1=RCT]
--   [u8: num_channels]
--   [zlib-compressed data:
--     For each channel:
--       finalLL (row-major Int32 big-endian), then for each level
--       deepest-first: LH, HL, HH (each row-major Int32 big-endian)]
------------------------------------------------------------------------

-- | Compress an image to raw encoded bytes (SDAT payload).
compress :: Header -> Image -> ByteString
compress hdr img =
  let w  = fromIntegral (width hdr)  :: Int
      h  = fromIntegral (height hdr) :: Int
      ch = channels (colorSpace hdr)
      -- Flatten all rows into a single byte vector
      flat = V.concat (V.toList img)
      -- Deinterleave into per-channel vectors of Word8
      chanVecs = deinterleave flat ch
      -- Determine color transform and convert to Int32 channels
      (useRCT, int32Channels) = toInt32Channels (colorSpace hdr) w h chanVecs
      -- Determine DWT levels
      numLevels = computeLevels w h
      -- Apply DWT per channel and serialize
      coeffBytes = case compressionMethod hdr of
        DwtLosslessVarint -> serializeAllChannelsVarint numLevels w h int32Channels
        _                 -> serializeAllChannels numLevels w h int32Channels
      -- Compress
      compressed = BL.toStrict $ Z.compress $ BL.fromStrict coeffBytes
      -- Color transform byte
      ctByte = if useRCT then 1 else 0 :: Word8
      numCh  = fromIntegral (length int32Channels) :: Word8
  in BS.pack [fromIntegral numLevels, ctByte, numCh] <> compressed

-- | Decompress raw encoded bytes back to an image.
decompress :: Header -> ByteString -> Either SigilError Image
decompress hdr bs
  | compressionMethod hdr == Legacy = Left (IoError "Legacy decompression not supported in Pipeline")
  | BS.length bs < 3 = Left TruncatedInput
  | otherwise =
    let w  = fromIntegral (width hdr)  :: Int
        h  = fromIntegral (height hdr) :: Int
        numLevels = fromIntegral (BS.index bs 0) :: Int
        ctByte    = BS.index bs 1
        numCh     = fromIntegral (BS.index bs 2) :: Int
        useRCT    = ctByte == 1
        compressedData = BS.drop 3 bs
        decompressed = BL.toStrict $ Z.decompress $ BL.fromStrict compressedData
        -- Deserialize all channels
        int32Channels = case compressionMethod hdr of
          DwtLosslessVarint ->
            deserializeAllChannelsVarint numLevels w h numCh decompressed
          _ ->
            deserializeAllChannels numLevels w h numCh decompressed
        -- Convert Int32 channels back to Word8 channels
        word8Channels = fromInt32Channels (colorSpace hdr) w h useRCT int32Channels
        -- Interleave channels into rows
        ch = channels (colorSpace hdr)
        interleaved = interleaveChannels word8Channels (w * ch)
        -- Split into rows
        rows = V.fromList [ V.slice (y * w * ch) (w * ch) interleaved
                          | y <- [0 .. h - 1] ]
    in Right rows

------------------------------------------------------------------------
-- Channel deinterleaving / interleaving
------------------------------------------------------------------------

-- | Deinterleave a flat vector of interleaved pixel data into per-channel vectors.
-- e.g., [R,G,B,R,G,B,...] -> [[R,R,...], [G,G,...], [B,B,...]]
deinterleave :: Vector Word8 -> Int -> [Vector Word8]
deinterleave flat ch =
  [ V.generate npx (\i -> flat V.! (i * ch + c))
  | c <- [0 .. ch - 1]
  ]
  where
    npx = V.length flat `div` ch

-- | Interleave per-channel Word8 vectors back into flat interleaved data.
interleaveChannels :: [Vector Word8] -> Int -> Vector Word8
interleaveChannels [] _ = V.empty
interleaveChannels chans _rowLen =
  let ch = length chans
      npx = V.length (head chans)
  in V.generate (npx * ch) $ \idx ->
       let i = idx `div` ch
           c = idx `mod` ch
       in (chans !! c) V.! i

------------------------------------------------------------------------
-- Color transform / Int32 conversion
------------------------------------------------------------------------

-- | Convert deinterleaved Word8 channels to Int32 channels,
-- applying RCT if appropriate. Returns (usedRCT, int32Channels).
toInt32Channels :: ColorSpace -> Int -> Int -> [Vector Word8]
                -> (Bool, [Vector Int32])
toInt32Channels cs w h chanVecs = case cs of
  RGB ->
    let interleaved = interleaveRGB (chanVecs !! 0) (chanVecs !! 1) (chanVecs !! 2)
        (y', cb, cr) = forwardRCT w h interleaved
    in (True, [y', cb, cr])
  RGBA ->
    let interleaved = interleaveRGB (chanVecs !! 0) (chanVecs !! 1) (chanVecs !! 2)
        (y', cb, cr) = forwardRCT w h interleaved
        alpha = V.map fromIntegral (chanVecs !! 3) :: Vector Int32
    in (True, [y', cb, cr, alpha])
  _ ->
    -- Grayscale, GrayscaleAlpha: just convert Word8 -> Int32
    (False, map (V.map fromIntegral) chanVecs)

-- | Convert Int32 channels back to Word8 channels, applying inverse RCT if needed.
fromInt32Channels :: ColorSpace -> Int -> Int -> Bool -> [Vector Int32]
                  -> [Vector Word8]
fromInt32Channels cs w h useRCT int32Chans
  | useRCT = case cs of
      RGB ->
        let rgb = inverseRCT w h (int32Chans !! 0, int32Chans !! 1, int32Chans !! 2)
            npx = w * h
        in [ V.generate npx (\i -> rgb V.! (i * 3 + c)) | c <- [0..2] ]
      RGBA ->
        let rgb = inverseRCT w h (int32Chans !! 0, int32Chans !! 1, int32Chans !! 2)
            npx = w * h
            rgbChans = [ V.generate npx (\i -> rgb V.! (i * 3 + c)) | c <- [0..2] ]
            alpha = V.map clampWord8 (int32Chans !! 3)
        in rgbChans ++ [alpha]
      _ ->
        -- Shouldn't happen, but fallback
        map (V.map clampWord8) int32Chans
  | otherwise =
      map (V.map clampWord8) int32Chans

-- | Interleave 3 separate channel vectors into a single RGB interleaved vector.
interleaveRGB :: Vector Word8 -> Vector Word8 -> Vector Word8 -> Vector Word8
interleaveRGB r g b =
  let npx = V.length r
  in V.generate (npx * 3) $ \idx ->
       let i = idx `div` 3
           c = idx `mod` 3
       in case c of
            0 -> r V.! i
            1 -> g V.! i
            _ -> b V.! i

clampWord8 :: Int32 -> Word8
clampWord8 x
  | x < 0    = 0
  | x > 255  = 255
  | otherwise = fromIntegral x

------------------------------------------------------------------------
-- DWT + serialization
------------------------------------------------------------------------

-- | Apply DWT and serialize all channels into a single ByteString.
serializeAllChannels :: Int -> Int -> Int -> [Vector Int32] -> ByteString
serializeAllChannels numLevels w h chans =
  BS.concat $ map (serializeChannel numLevels w h) chans

-- | Apply forward DWT to a channel and serialize the coefficients.
serializeChannel :: Int -> Int -> Int -> Vector Int32 -> ByteString
serializeChannel numLevels w h chan =
  let chanU = VU.convert chan :: VU.Vector Int32
      (finalLLU, levelsU) = dwtForwardMultiMut numLevels w h chanU
      finalLL = V.convert finalLLU :: Vector Int32
      levels = map (\(a,b,c) -> (V.convert a, V.convert b, V.convert c)) levelsU
  in serializeCoeffs finalLL levels

-- | Serialize wavelet coefficients:
-- finalLL first, then levels deepest-first (LH, HL, HH per level).
serializeCoeffs :: Vector Int32 -> [(Vector Int32, Vector Int32, Vector Int32)]
                -> ByteString
serializeCoeffs finalLL levels =
  let llBytes = packInt32Vec finalLL
      levelBytes = concatMap (\(lh, hl, hh) ->
        [packInt32Vec lh, packInt32Vec hl, packInt32Vec hh]) levels
  in BS.concat (llBytes : levelBytes)

-- | Serialize wavelet coefficients using zigzag + varint packing.
-- Per spec: writes [varint ll_width] [varint ll_height] before LL data.
serializeCoeffsVarint :: Int -> Int -> Vector Int32
                      -> [(Vector Int32, Vector Int32, Vector Int32)]
                      -> ByteString
serializeCoeffsVarint llW llH finalLL levels =
  let dimBytes = encodeVarint (fromIntegral llW) <> encodeVarint (fromIntegral llH)
      llBytes = packLLSubband llW finalLL
      levelBytes = concatMap (\(lh, hl, hh) ->
        [packSubband lh, packSubband hl, packSubband hh]) levels
  in BS.concat (dimBytes : llBytes : levelBytes)

-- | Deserialize varint-packed wavelet coefficients.
-- Per spec: reads [varint ll_width] [varint ll_height] before LL data.
deserializeCoeffsVarint :: Int -> Int -> Int -> ByteString
                        -> (Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)], ByteString)
deserializeCoeffsVarint numLevels w h bs =
  let levelSizes = computeLevelSizes numLevels w h
      -- Read explicit LL dimensions from the stream
      (llW32, rest0a) = decodeVarint bs
      (llH32, rest0b) = decodeVarint rest0a
      llW = fromIntegral llW32 :: Int
      llH = fromIntegral llH32 :: Int
      llCount = llW * llH
      (finalLL, rest1) = unpackLLSubband llW llCount rest0b
      (levels, rest2) = readLevelsVarint levelSizes rest1
  in (finalLL, levels, rest2)

-- | Read detail subbands using varint unpacking.
readLevelsVarint :: [(Int, Int, Int, Int)] -> ByteString
                 -> ([(Vector Int32, Vector Int32, Vector Int32)], ByteString)
readLevelsVarint [] bs = ([], bs)
readLevelsVarint ((wLow, hLow, wHigh, hHigh) : rest) bs =
  let lhCount = hLow * wHigh
      hlCount = hHigh * wLow
      hhCount = hHigh * wHigh
      (lh, bs1) = unpackSubband lhCount bs
      (hl, bs2) = unpackSubband hlCount bs1
      (hh, bs3) = unpackSubband hhCount bs2
      (restLevels, bsFinal) = readLevelsVarint rest bs3
  in ((lh, hl, hh) : restLevels, bsFinal)

-- | Serialize a channel using varint packing (v0.6).
serializeChannelVarint :: Int -> Int -> Int -> Vector Int32 -> ByteString
serializeChannelVarint numLevels w h chan =
  let chanU = VU.convert chan :: VU.Vector Int32
      (finalLLU, levelsU) = dwtForwardMultiMut numLevels w h chanU
      finalLL = V.convert finalLLU :: Vector Int32
      levels = map (\(a,b,c) -> (V.convert a, V.convert b, V.convert c)) levelsU
      levelSizes = computeLevelSizes numLevels w h
      (llW, llH) = case levelSizes of
                     [] -> (w, h)
                     ((lw, lh, _, _) : _) -> (lw, lh)
  in serializeCoeffsVarint llW llH finalLL levels

-- | Serialize all channels using varint packing (v0.6).
serializeAllChannelsVarint :: Int -> Int -> Int -> [Vector Int32] -> ByteString
serializeAllChannelsVarint numLevels w h chans =
  BS.concat $ map (serializeChannelVarint numLevels w h) chans

-- | Deserialize a single channel from varint-packed bytes, apply inverse DWT.
deserializeChannelVarint :: Int -> Int -> Int -> ByteString -> (Vector Int32, ByteString)
deserializeChannelVarint numLevels w h bs =
  let (finalLL, levels, remaining) = deserializeCoeffsVarint numLevels w h bs
      finalLLU = VU.convert finalLL :: VU.Vector Int32
      levelsU = map (\(a,b,c) -> (VU.convert a, VU.convert b, VU.convert c)) levels
      reconstructedU = dwtInverseMultiMut numLevels w h finalLLU levelsU
      reconstructed = V.convert reconstructedU :: Vector Int32
  in (reconstructed, remaining)

-- | Deserialize all channels from varint-packed bytes.
deserializeAllChannelsVarint :: Int -> Int -> Int -> Int -> ByteString -> [Vector Int32]
deserializeAllChannelsVarint numLevels w h numCh bs = go numCh bs
  where
    go 0 _ = []
    go n remaining =
      let (chan, rest) = deserializeChannelVarint numLevels w h remaining
      in chan : go (n - 1) rest

-- | Deserialize all channels from a ByteString.
deserializeAllChannels :: Int -> Int -> Int -> Int -> ByteString -> [Vector Int32]
deserializeAllChannels numLevels w h numCh bs = go numCh bs
  where
    go 0 _ = []
    go n remaining =
      let (chan, rest) = deserializeChannel numLevels w h remaining
      in chan : go (n - 1) rest

-- | Deserialize a single channel: read coefficients, apply inverse DWT.
deserializeChannel :: Int -> Int -> Int -> ByteString -> (Vector Int32, ByteString)
deserializeChannel numLevels w h bs =
  let (finalLL, levels, remaining) = deserializeCoeffs numLevels w h bs
      finalLLU = VU.convert finalLL :: VU.Vector Int32
      levelsU = map (\(a,b,c) -> (VU.convert a, VU.convert b, VU.convert c)) levels
      reconstructedU = dwtInverseMultiMut numLevels w h finalLLU levelsU
      reconstructed = V.convert reconstructedU :: Vector Int32
  in (reconstructed, remaining)

-- | Deserialize wavelet coefficients from a ByteString.
-- Returns (finalLL, levels deepest-first, remaining bytes).
deserializeCoeffs :: Int -> Int -> Int -> ByteString
                  -> (Vector Int32, [(Vector Int32, Vector Int32, Vector Int32)], ByteString)
deserializeCoeffs numLevels w h bs =
  let -- Compute the sizes at each level (deepest first)
      -- Each entry: (wLow, hLow, wHigh, hHigh) for that DWT level
      levelSizes = computeLevelSizes numLevels w h
      -- Final LL size is the deepest LL approximation
      (llW, llH) = case levelSizes of
                     []    -> (w, h)
                     ((lw, lh, _, _) : _) -> (lw, lh)
      llCount = llW * llH
      (finalLL, rest1) = unpackInt32N llCount bs
      -- Read levels deepest-first
      (levels, rest2) = readLevels levelSizes rest1
  in (finalLL, levels, rest2)

-- | Compute level sizes from deepest to shallowest.
-- Each entry: (wLow, hLow, wHigh, hHigh) for the DWT at that level.
-- The LH subband has size hLow * wHigh.
-- The HL subband has size hHigh * wLow.
-- The HH subband has size hHigh * wHigh.
-- The LL subband has size wLow * hLow (only stored for deepest level as finalLL).
computeLevelSizes :: Int -> Int -> Int
                  -> [(Int, Int, Int, Int)]  -- (wLow, hLow, wHigh, hHigh) per level
computeLevelSizes 0 _ _ = []
computeLevelSizes numLevels w0 h0 = reverse $ go numLevels w0 h0
  where
    go 0 _ _ = []
    go n cw ch =
      let wLow  = (cw + 1) `div` 2
          wHigh = cw `div` 2
          hLow  = (ch + 1) `div` 2
          hHigh = ch `div` 2
      in (wLow, hLow, wHigh, hHigh) : go (n - 1) wLow hLow

-- | Read detail subbands for each level.
readLevels :: [(Int, Int, Int, Int)] -> ByteString
           -> ([(Vector Int32, Vector Int32, Vector Int32)], ByteString)
readLevels [] bs = ([], bs)
readLevels ((wLow, hLow, wHigh, hHigh) : rest) bs =
  let lhCount = hLow * wHigh
      hlCount = hHigh * wLow
      hhCount = hHigh * wHigh
      (lh, bs1) = unpackInt32N lhCount bs
      (hl, bs2) = unpackInt32N hlCount bs1
      (hh, bs3) = unpackInt32N hhCount bs2
      (restLevels, bsFinal) = readLevels rest bs3
  in ((lh, hl, hh) : restLevels, bsFinal)

------------------------------------------------------------------------
-- Int32 packing / unpacking (big-endian)
------------------------------------------------------------------------

-- | Pack a vector of Int32 values as big-endian bytes.
packInt32Vec :: Vector Int32 -> ByteString
packInt32Vec v = BS.pack $ concatMap packInt32 (V.toList v)

packInt32 :: Int32 -> [Word8]
packInt32 x =
  [ fromIntegral (x `shiftR` 24)
  , fromIntegral (x `shiftR` 16)
  , fromIntegral (x `shiftR` 8)
  , fromIntegral x
  ]

-- | Unpack N Int32 values from a ByteString (big-endian).
-- Returns (vector of Int32s, remaining bytes).
unpackInt32N :: Int -> ByteString -> (Vector Int32, ByteString)
unpackInt32N n bs =
  let byteCount = n * 4
      (taken, rest) = BS.splitAt byteCount bs
      vals = V.generate n $ \i ->
        let off = i * 4
            b0 = fromIntegral (BS.index taken off)       :: Int32
            b1 = fromIntegral (BS.index taken (off + 1)) :: Int32
            b2 = fromIntegral (BS.index taken (off + 2)) :: Int32
            b3 = fromIntegral (BS.index taken (off + 3)) :: Int32
        in (b0 `shiftL` 24) .|. (b1 `shiftL` 16) .|. (b2 `shiftL` 8) .|. b3
  in (vals, rest)
