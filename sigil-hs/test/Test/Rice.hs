module Test.Rice (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word16, Word8)
import qualified Data.ByteString as BS

import Sigil.Codec.Rice

spec :: Spec
spec = describe "Rice" $ do
  describe "BitWriter/BitReader" $ do
    it "round-trips 8 bits as one byte" $ do
      let bits = [True, False, True, True, False, False, True, False]
          bs = flushBits $ foldl (flip writeBit) newBitWriter bits
      BS.length bs `shouldBe` 1
      BS.index bs 0 `shouldBe` 0xB2

  describe "Rice coding" $ do
    it "round-trips any value with any k in [0,8]" $ property $
      forAll (choose (0, 8 :: Word8)) $ \k ->
        forAll (choose (0, 4095 :: Word16)) $ \val ->
          let encoded = flushBits $ riceEncode k val newBitWriter
              (decoded, _) = riceDecode k (newBitReader encoded)
          in decoded === val

  describe "optimal k" $ do
    it "selects k in range [0,8]" $ property $
      forAll (listOf1 (choose (0, 511 :: Word16))) $ \block ->
        let k = optimalK block
        in k >= 0 .&&. k <= 8

  describe "block encode/decode" $ do
    it "round-trips a block of values" $ property $
      forAll (vectorOf blockSize (choose (0, 511 :: Word16))) $ \block ->
        let encoded = encodeBlock block
            decoded = decodeBlock encoded blockSize
        in decoded === block
