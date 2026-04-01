module Test.Pipeline (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word32)
import qualified Data.Vector as V

import Sigil.Core.Types
import Sigil.Codec.Pipeline (compress, decompress)
import Gen (arbitraryImage)

spec :: Spec
spec = describe "Pipeline" $ do
  it "round-trips small RGB images" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 3) $ \img ->
          let hdr = Header w h RGB Depth8 DwtLosslessVarint
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips grayscale" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 1) $ \img ->
          let hdr = Header w h Grayscale Depth8 DwtLosslessVarint
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips RGBA" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 4) $ \img ->
          let hdr = Header w h RGBA Depth8 DwtLosslessVarint
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img

  it "round-trips GrayscaleAlpha" $ property $
    forAll (choose (1, 16 :: Word32)) $ \w ->
      forAll (choose (1, 16 :: Word32)) $ \h ->
        forAll (arbitraryImage w h 2) $ \img ->
          let hdr = Header w h GrayscaleAlpha Depth8 DwtLosslessVarint
              encoded = compress hdr img
              decoded = decompress hdr encoded
          in decoded === Right img
