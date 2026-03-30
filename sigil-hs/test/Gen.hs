module Gen
  ( arbitraryPixel
  , arbitraryRow
  , arbitraryImage
  , arbitraryFixedPredictor
  ) where

import Test.QuickCheck

import Data.Word (Word8, Word32)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Sigil.Core.Types (PredictorId(..), Image, Row)

arbitraryPixel :: Gen Word8
arbitraryPixel = arbitrary

arbitraryRow :: Int -> Gen Row
arbitraryRow len = V.fromList <$> vectorOf len arbitraryPixel

arbitraryImage :: Word32 -> Word32 -> Int -> Gen Image
arbitraryImage w h ch =
  let rowLen = fromIntegral w * ch
  in V.fromList <$> vectorOf (fromIntegral h) (arbitraryRow rowLen)

-- | Only fixed predictors (not PAdaptive)
arbitraryFixedPredictor :: Gen PredictorId
arbitraryFixedPredictor = elements [PNone, PSub, PUp, PAverage, PPaeth, PGradient]
