module Test.SubbandCoder (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import qualified Data.Vector as V

import Sigil.Codec.SubbandCoder

spec :: Spec
spec = describe "SubbandCoder" $ do

  describe "encodeSubband / decodeSubband" $ do
    it "empty vector round-trips" $ do
      let v = V.empty :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 0 encoded
      decoded `shouldBe` v

    it "single zero round-trips" $ do
      let v = V.singleton 0 :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "single positive round-trips" $ do
      let v = V.singleton 42 :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "single negative round-trips" $ do
      let v = V.singleton (-17) :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 1 encoded
      decoded `shouldBe` v

    it "known sequence round-trips" $ do
      let v = V.fromList [0, 5, -13, 1, -1, 0, 127, -128] :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband (V.length v) encoded
      decoded `shouldBe` v

    it "all zeros (sparse detail band)" $ do
      let v = V.replicate 100 0 :: V.Vector Int32
          encoded = encodeSubband v
          decoded = decodeSubband 100 encoded
      decoded `shouldBe` v

    it "QuickCheck: round-trip for arbitrary vectors" $ property $
      forAll (listOf (choose (-1000, 1000 :: Int32))) $ \xs ->
        let v = V.fromList xs
            n = V.length v
            encoded = encodeSubband v
            decoded = decodeSubband n encoded
        in decoded === v

    it "QuickCheck: round-trip for large sparse vectors (90% zeros)" $ property $
      forAll (vectorOf 500 (frequency [(9, pure 0), (1, choose (-100, 100 :: Int32))])) $ \xs ->
        let v = V.fromList xs
            n = V.length v
            encoded = encodeSubband v
            decoded = decodeSubband n encoded
        in decoded === v
