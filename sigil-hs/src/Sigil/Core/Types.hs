module Sigil.Core.Types
  ( ColorSpace(..)
  , BitDepth(..)
  , PredictorId(..)
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
import Data.Vector (Vector)
import Data.Word (Word8, Word32)

-- | A row of interleaved channel samples: [r,g,b, r,g,b, ...]
type Row = Vector Word8

-- | An image is a vector of rows.
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

data Header = Header
  { width      :: Word32
  , height     :: Word32
  , colorSpace :: ColorSpace
  , bitDepth   :: BitDepth
  , predictor  :: PredictorId
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
