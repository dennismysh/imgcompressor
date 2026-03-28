module Test.Token (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word16)
import qualified Data.Vector as V

import Sigil.Codec.Token (Token(..), tokenize, untokenize)

spec :: Spec
spec = describe "Token" $ do
  it "tokenizes all-zero vector as single ZeroRun" $ do
    tokenize (V.replicate 10 0) `shouldBe` [TZeroRun 10]

  it "tokenizes non-zero values as TValue" $ do
    tokenize (V.fromList [3, 5]) `shouldBe` [TValue 3, TValue 5]

  it "tokenizes mixed: zeros then value" $ do
    tokenize (V.fromList [0, 0, 0, 7]) `shouldBe` [TZeroRun 3, TValue 7]

  it "tokenizes value then zeros" $ do
    tokenize (V.fromList [4, 0, 0]) `shouldBe` [TValue 4, TZeroRun 2]

  it "handles empty input" $ do
    tokenize V.empty `shouldBe` []

  it "round-trips any Word16 vector" $ property $
    \xs -> let v = V.fromList (xs :: [Word16])
           in untokenize (tokenize v) == v
