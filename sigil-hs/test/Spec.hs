module Main where

import Test.Hspec
import Test.QuickCheck
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import Data.Word (Word32)
import Sigil.Core.Chunk (Tag(..), Chunk(..), crc32, makeChunk, verifyChunk)
import Sigil.IO.Writer (encodeSigilFile)
import Sigil.IO.Reader (decodeSigilFile)
import Sigil.Core.Types (Header(..), ColorSpace(..), BitDepth(..), PredictorId(..), emptyMetadata)
import Gen (arbitraryImage)

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

  describe "File I/O" $ do
    it "round-trips a small image through .sgl format" $ property $
      forAll (choose (1, 8 :: Word32)) $ \w ->
        forAll (choose (1, 8 :: Word32)) $ \h ->
          forAll (arbitraryImage w h 3) $ \img ->
            let hdr = Header w h RGB Depth8 PAdaptive
                encoded = encodeSigilFile hdr emptyMetadata img
                decoded = decodeSigilFile encoded
            in case decoded of
                 Left err -> counterexample (show err) False
                 Right (hdr', _, img') -> hdr' === hdr .&&. img' === img
