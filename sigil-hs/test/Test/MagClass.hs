{-# LANGUAGE ScopedTypeVariables #-}
module Test.MagClass (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import Data.Word (Word16)
import qualified Data.Vector.Unboxed as VU

import Sigil.Codec.MagClass

spec :: Spec
spec = describe "MagClass" $ do

  describe "encodeCoeff / decodeCoeff" $ do
    it "zero → class 0, no bits" $ do
      let (cls, bits) = encodeCoeff 0
      cls `shouldBe` 0
      bits `shouldBe` []

    it "1 → class 1, sign +, no residual" $ do
      let (cls, bits) = encodeCoeff 1
      cls `shouldBe` 1
      bits `shouldBe` [False]

    it "-1 → class 1, sign -, no residual" $ do
      let (cls, bits) = encodeCoeff (-1)
      cls `shouldBe` 1
      bits `shouldBe` [True]

    it "5 → class 3, sign +, residual 01" $ do
      let (cls, bits) = encodeCoeff 5
      cls `shouldBe` 3
      bits `shouldBe` [False, False, True]

    it "-13 → class 4, sign -, residual 101" $ do
      let (cls, bits) = encodeCoeff (-13)
      cls `shouldBe` 4
      bits `shouldBe` [True, True, False, True]

    it "round-trip for known values" $ do
      let vals = [0, 1, -1, 2, -2, 5, -5, 13, -13, 127, -128, 255, -256]
      mapM_ (\v -> do
        let (cls, bits) = encodeCoeff v
            decoded = decodeCoeff cls bits
        decoded `shouldBe` v
        ) vals

    it "QuickCheck: round-trip for arbitrary Int32" $ property $
      \(v :: Int32) ->
        let (cls, bits) = encodeCoeff v
            decoded = decodeCoeff cls bits
        in decoded === v

    it "class 0 produces exactly 0 bits" $ do
      let (_, bits) = encodeCoeff 0
      length bits `shouldBe` 0

    it "class k produces exactly k bits (1 sign + k-1 residual)" $ property $
      forAll (choose (1, 10000 :: Int32)) $ \v ->
        let (cls, bits) = encodeCoeff v
        in length bits === fromIntegral cls

  describe "encodeCoeffs / decodeCoeffs" $ do
    it "empty vector" $ do
      let (classes, bits) = encodeCoeffs VU.empty
      classes `shouldBe` []
      bits `shouldBe` []
      decodeCoeffs [] [] `shouldBe` VU.empty

    it "round-trip for known vector" $ do
      let v = VU.fromList [0, 5, -13, 1, -1, 0]
          (classes, bits) = encodeCoeffs v
          decoded = decodeCoeffs classes bits
      decoded `shouldBe` v

    it "QuickCheck: round-trip for arbitrary vectors" $ property $
      forAll (listOf (choose (-1000, 1000 :: Int32))) $ \xs ->
        let v = VU.fromList xs
            (classes, bits) = encodeCoeffs v
            decoded = decodeCoeffs classes bits
        in decoded === v
