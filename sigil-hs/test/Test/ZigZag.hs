module Test.ZigZag (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int16)
import Data.Word (Word16)

import Sigil.Codec.ZigZag (zigzag, unzigzag)

spec :: Spec
spec = describe "ZigZag" $ do
  it "maps 0 -> 0" $
    zigzag 0 `shouldBe` (0 :: Word16)

  it "maps -1 -> 1" $
    zigzag (-1) `shouldBe` 1

  it "maps 1 -> 2" $
    zigzag 1 `shouldBe` 2

  it "maps -2 -> 3" $
    zigzag (-2) `shouldBe` 3

  it "maps 2 -> 4" $
    zigzag 2 `shouldBe` 4

  it "round-trips all values in [-255, 255]" $ property $
    forAll (choose (-255, 255)) $
      \n -> unzigzag (zigzag (n :: Int16)) == n

  it "produces non-negative output" $ property $
    forAll (choose (-255, 255)) $
      \n -> zigzag (n :: Int16) >= (0 :: Word16)

  it "is monotonic on absolute value" $ property $
    forAll (choose (0, 255)) $ \a ->
    forAll (choose (0, 255)) $ \b ->
      let a' = (a :: Int16)
          b' = (b :: Int16)
      in a' < b' ==> zigzag a' < zigzag b'
