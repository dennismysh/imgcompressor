module Test.SubbandCoder (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import qualified Data.Vector.Unboxed as VU

import Sigil.Codec.SubbandCoder

spec :: Spec
spec = describe "SubbandCoder" $ do

  describe "encodeSubband / decodeSubband" $ do
    it "empty vector round-trips" $ do
      let v = VU.empty :: VU.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 0 encoded
      decoded `shouldBe` v

    it "single zero round-trips" $ do
      let v = VU.singleton 0 :: VU.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "single positive round-trips" $ do
      let v = VU.singleton 42 :: VU.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "single negative round-trips" $ do
      let v = VU.singleton (-17) :: VU.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "known sequence round-trips" $ do
      let v = VU.fromList [0, 5, -13, 1, -1, 0, 127, -128] :: VU.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband (VU.length v) encoded
      decoded `shouldBe` v

    it "all zeros (sparse detail band)" $ do
      let v = VU.replicate 100 0 :: VU.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 100 encoded
      decoded `shouldBe` v

    it "QuickCheck: round-trip for arbitrary vectors" $ property $
      forAll (listOf (choose (-1000, 1000 :: Int32))) $ \xs ->
        let v = VU.fromList xs
            n = VU.length v
            encoded = encodeSubband v
            decoded = decodeSubband n encoded
        in decoded === v

    it "QuickCheck: round-trip for large sparse vectors (90% zeros)" $ property $
      forAll (vectorOf 500 (frequency [(9, pure 0), (1, choose (-100, 100 :: Int32))])) $ \xs ->
        let v = VU.fromList xs
            n = VU.length v
            encoded = encodeSubband v
            decoded = decodeSubband n encoded
        in decoded === v
