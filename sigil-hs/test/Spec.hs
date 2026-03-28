module Main where

import Test.Hspec

import qualified Test.ZigZag
import qualified Test.Predict
import qualified Test.Token
import qualified Test.Rice

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
  Test.Predict.spec
  Test.Token.spec
  Test.Rice.spec
