module Main where

import Test.Hspec

import qualified Test.ZigZag
import qualified Test.Predict

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
  Test.Predict.spec
