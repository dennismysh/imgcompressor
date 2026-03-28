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
    -- Cap at maxBound @Word16 so the run length fits in the TZeroRun field.
    -- Runs longer than 65535 are split into multiple TZeroRun tokens.
    countZerosFrom start =
      min (fromIntegral (maxBound :: Word16))
        $ V.length
        $ V.takeWhile (== 0)
        $ V.drop start v

untokenize :: [Token] -> Vector Word16
untokenize tokens = V.fromList $ concatMap expand tokens
  where
    expand (TZeroRun n) = replicate (fromIntegral n) 0
    expand (TValue x)   = [x]
