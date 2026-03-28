module Test.Pipeline (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word32)
import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Codec.Pipeline (compress, decompress)
import Gen (arbitraryImage, arbitraryFixedPredictor)

spec :: Spec
spec = describe "Pipeline" $ do
  it "round-trips small images with fixed predictors" $ property $
    forAll arbitraryFixedPredictor $ \pid ->
      forAll (choose (1, 16 :: Word32)) $ \w ->
        forAll (choose (1, 16 :: Word32)) $ \h ->
          forAll (arbitraryImage w h 3) $ \img ->
            let hdr = Header w h RGB Depth8 pid
                encoded = compress hdr img
                decoded = decompress hdr encoded
            in decoded === Right img

  it "round-trips with adaptive predictor" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 3) $ \img ->
          let hdr = Header w h RGB Depth8 PAdaptive
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips grayscale" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 1) $ \img ->
          let hdr = Header w h Grayscale Depth8 PAdaptive
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips RGBA" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 4) $ \img ->
          let hdr = Header w h RGBA Depth8 PAdaptive
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img
