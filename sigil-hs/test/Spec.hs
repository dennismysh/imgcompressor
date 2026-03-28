module Main where

import Test.Hspec
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import Sigil.Core.Chunk (Tag(..), Chunk(..), crc32, makeChunk, verifyChunk)

import qualified Test.ZigZag
import qualified Test.Predict
import qualified Test.Token
import qualified Test.Rice
import qualified Test.Pipeline

main :: IO ()
main = hspec $ do
  Test.ZigZag.spec
  Test.Predict.spec
  Test.Token.spec
  Test.Rice.spec
  Test.Pipeline.spec
  describe "Chunk" $ do
    it "CRC32 of empty is 0x00000000" $
      crc32 BS.empty `shouldBe` 0x00000000

    it "CRC32 of 'IEND' matches PNG reference" $
      crc32 (BS.pack [0x49, 0x45, 0x4E, 0x44]) `shouldBe` 0xAE426082

    it "makeChunk computes CRC and verifyChunk accepts it" $ do
      let chunk = makeChunk SHDR (BS.pack [1, 2, 3])
      verifyChunk chunk `shouldBe` Right ()

    it "verifyChunk rejects corrupted payload" $ do
      let chunk = makeChunk SHDR (BS.pack [1, 2, 3])
          bad = chunk { chunkPayload = BS.pack [9, 9, 9] }
      verifyChunk bad `shouldSatisfy` isLeft
