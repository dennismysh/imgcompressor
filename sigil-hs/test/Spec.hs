module Main where

import Test.Hspec

import qualified Test.ZigZag
import qualified Test.Predict
import qualified Test.Token

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
  Test.Predict.spec
  Test.Token.spec
