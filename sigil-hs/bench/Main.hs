{-# OPTIONS_GHC -Wno-orphans #-}
module Main where

import Criterion.Main
import Control.DeepSeq (NFData(..), force)

import Data.Int (Int16)
import Data.Word (Word8, Word16)
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))
import Sigil.Codec.Predict (predictImage, unpredictImage, predictRow)
import Sigil.Codec.ZigZag (zigzag, unzigzag)
import Sigil.Codec.Token (Token(..), tokenize, untokenize)
import Sigil.Codec.Rice (optimalK, encodeBlock, blockSize)
import Sigil.Codec.Pipeline (compress, decompress)

-- Generate a synthetic gradient image
makeGradient :: Int -> Int -> Image
makeGradient w h = V.fromList
  [ VU.fromList
      [ fromIntegral ((x * 3 + c + y) `mod` 256)
      | x <- [0..w-1], c <- [0..2]  -- RGB
      ]
  | y <- [0..h-1]
  ]

-- Generate a noise image (deterministic LCG)
makeNoise :: Int -> Int -> Image
makeNoise w h = V.fromList
  [ VU.fromList
      [ fromIntegral (((y * w + x) * 3 + c) * 1103515245 + 12345 :: Int) `mod` 256
      | x <- [0..w-1], c <- [0..2]
      ]
  | y <- [0..h-1]
  ]

-- Generate flat image
makeFlat :: Int -> Int -> Word8 -> Image
makeFlat w h val = V.replicate h (VU.replicate (w * 3) val)

-- Generate checkerboard
makeCheckerboard :: Int -> Int -> Image
makeCheckerboard w h = V.fromList
  [ VU.fromList
      [ let v = if (x `div` 8 + y `div` 8) `mod` 2 == 0 then 0 else 255
        in v
      | x <- [0..w-1], _ <- [0..2]
      ]
  | y <- [0..h-1]
  ]

-- NFData instances for benchmarking
instance NFData PredictorId where rnf x = x `seq` ()
instance NFData CompressionMethod where rnf x = x `seq` ()
instance NFData BitDepth where rnf x = x `seq` ()
instance NFData ColorSpace where rnf x = x `seq` ()
instance NFData Header where rnf (Header w h cs bd cm) = rnf w `seq` rnf h `seq` rnf cs `seq` rnf bd `seq` rnf cm
instance NFData SigilError where rnf x = x `seq` ()
instance NFData Token where rnf x = x `seq` ()

main :: IO ()
main = do
  let sizes = [(64, 64), (256, 256), (1024, 1024)]
      pids = [PNone, PSub, PUp, PAverage, PPaeth, PGradient, PAdaptive]

  defaultMain
    [ bgroup "predict" $
        [ bgroup (show pid) $
            [ bench (show w ++ "x" ++ show h) $
                let img = makeGradient w h
                    hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 DwtLossless
                in nf (predictImage pid hdr) img
            | (w, h) <- sizes
            ]
        | pid <- pids
        ]

    , bgroup "zigzag"
        [ bench "encode/10k" $ nf (V.map zigzag) (V.enumFromTo (-255) 255 :: Vector Int16)
        , bench "decode/10k" $ nf (V.map unzigzag) (V.enumFromTo 0 511 :: Vector Word16)
        ]

    , bgroup "tokenize"
        [ bench "sparse" $ nf tokenize (V.fromList $ replicate 1000 0 ++ [1..100])
        , bench "dense"  $ nf tokenize (V.fromList [1..1000])
        , bench "uniform" $ nf tokenize (V.replicate 1000 0)
        ]

    , bgroup "rice"
        [ bgroup "encode" $
            [ bench ("k=" ++ show k) $
                nf encodeBlock (replicate blockSize (100 :: Word16))
            | k <- [0..8 :: Int]
            ]
        , bench "optimal-k" $
            nf optimalK (replicate blockSize 42 :: [Word16])
        ]

    , bgroup "pipeline" $
        [ bgroup "encode" $
            [ bench (show w ++ "x" ++ show h) $
                let img = makeGradient w h
                    hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 DwtLossless
                in nf (compress hdr) img
            | (w, h) <- sizes
            ]
        , bgroup "decode" $
            [ bench (show w ++ "x" ++ show h) $
                let img = makeGradient w h
                    hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 DwtLossless
                    encoded = compress hdr img
                in nf (decompress hdr) encoded
            | (w, h) <- sizes
            ]
        ]
    ]
