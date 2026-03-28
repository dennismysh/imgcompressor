module Main where

import Test.Hspec

import qualified Test.ZigZag

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
