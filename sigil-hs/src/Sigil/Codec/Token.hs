module Sigil.Codec.Token
  ( Token(..)
  , tokenize
  , untokenize
  ) where

import Data.Word (Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V

data Token
  = TZeroRun Word16
  | TValue Word16
  deriving (Eq, Show)

tokenize :: Vector Word16 -> [Token]
tokenize v = go 0
  where
    len = V.length v
    go i
      | i >= len = []
      | v V.! i == 0 =
          let n = countZerosFrom i
          in TZeroRun (fromIntegral n) : go (i + n)
      | otherwise =
          TValue (v V.! i) : go (i + 1)
    countZerosFrom start = length $ takeWhile id
      [ j < len && v V.! j == 0 && j - start < fromIntegral (maxBound :: Word16)
      | j <- [start..len - 1]
      ]

untokenize :: [Token] -> Vector Word16
untokenize tokens = V.fromList $ concatMap expand tokens
  where
    expand (TZeroRun n) = replicate (fromIntegral n) 0
    expand (TValue x)   = [x]
