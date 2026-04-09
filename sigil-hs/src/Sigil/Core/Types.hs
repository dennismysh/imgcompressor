module Sigil.Core.Types
  ( ColorSpace(..)
  , BitDepth(..)
  , PredictorId(..)
  , CompressionMethod(..)
  , compressionMethodFromByte
  , compressionMethodToByte
  , Header(..)
  , Row
  , Image
  , Metadata(..)
  , channels
  , bytesPerChannel
  , rowBytes
  , emptyMetadata
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Vector.Unboxed as VU
import Data.Vector (Vector)
import Data.Word (Word8, Word32)

-- | A row of interleaved channel samples: [r,g,b, r,g,b, ...]
-- Uses unboxed vectors to avoid 24-byte-per-element GHC heap overhead.
-- This reduces a 15MP RGB image from ~1GB to ~45MB in memory.
type Row = VU.Vector Word8

-- | An image is a vector of rows (boxed vector of unboxed rows).
type Image = Vector Row

data ColorSpace
  = Grayscale       -- ^ 1 channel
  | GrayscaleAlpha  -- ^ 2 channels
  | RGB             -- ^ 3 channels
  | RGBA            -- ^ 4 channels
  deriving (Eq, Show, Enum, Bounded)

data BitDepth
  = Depth8          -- ^ 8 bits per channel
  | Depth16         -- ^ 16 bits per channel
  deriving (Eq, Show, Enum, Bounded)

data PredictorId
  = PNone           -- ^ 0: no prediction
  | PSub            -- ^ 1: left neighbor
  | PUp             -- ^ 2: above neighbor
  | PAverage        -- ^ 3: average of left and above
  | PPaeth          -- ^ 4: Paeth predictor
  | PGradient       -- ^ 5: clamped gradient
  | PAdaptive       -- ^ 6: per-row optimal
  deriving (Eq, Show, Enum, Bounded)

data CompressionMethod
  = Legacy              -- ^ 0: old predict+zigzag (not produced by v0.5+ encoder)
  | DwtLossless         -- ^ 1: integer 5/3 wavelet + raw i32 + zlib (v0.5)
  | DwtLosslessVarint   -- ^ 2: integer 5/3 wavelet + zigzag/varint + zlib (v0.6)
  | DwtANS              -- ^ 3: integer 5/3 wavelet + mag class + ANS (v0.8)
  deriving (Eq, Show, Enum, Bounded)

compressionMethodFromByte :: Word8 -> Maybe CompressionMethod
compressionMethodFromByte 0 = Just Legacy
compressionMethodFromByte 1 = Just DwtLossless
compressionMethodFromByte 2 = Just DwtLosslessVarint
compressionMethodFromByte 3 = Just DwtANS
compressionMethodFromByte _ = Nothing

compressionMethodToByte :: CompressionMethod -> Word8
compressionMethodToByte Legacy             = 0
compressionMethodToByte DwtLossless        = 1
compressionMethodToByte DwtLosslessVarint  = 2
compressionMethodToByte DwtANS             = 3

data Header = Header
  { width             :: Word32
  , height            :: Word32
  , colorSpace        :: ColorSpace
  , bitDepth          :: BitDepth
  , compressionMethod :: CompressionMethod
  } deriving (Eq, Show)

data Metadata = Metadata
  { metaEntries :: [(Text, ByteString)]
  } deriving (Eq, Show)

channels :: ColorSpace -> Int
channels Grayscale      = 1
channels GrayscaleAlpha = 2
channels RGB            = 3
channels RGBA           = 4

bytesPerChannel :: BitDepth -> Int
bytesPerChannel Depth8  = 1
bytesPerChannel Depth16 = 2

rowBytes :: Header -> Int
rowBytes hdr =
  fromIntegral (width hdr) * channels (colorSpace hdr) * bytesPerChannel (bitDepth hdr)

emptyMetadata :: Metadata
emptyMetadata = Metadata []
