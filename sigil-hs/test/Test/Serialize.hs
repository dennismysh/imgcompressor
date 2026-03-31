{-# LANGUAGE ScopedTypeVariables #-}
module Test.Serialize (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import Data.Word (Word32)
import qualified Data.ByteString as BS

import Sigil.Codec.Serialize (zigzag32, unzigzag32, encodeVarint, decodeVarint)

spec :: Spec
spec = describe "Serialize" $ do
  describe "zigzag32" $ do
    it "maps known values" $ do
      zigzag32 0    `shouldBe` 0
      zigzag32 (-1) `shouldBe` 1
      zigzag32 1    `shouldBe` 2
      zigzag32 (-2) `shouldBe` 3
      zigzag32 2    `shouldBe` 4

    it "round-trips all Int32" $ property $
      \(n :: Int32) -> unzigzag32 (zigzag32 n) === n

  describe "varint" $ do
    it "encodes 0 as single byte 0x00" $
      encodeVarint 0 `shouldBe` BS.pack [0x00]

    it "encodes 127 as single byte 0x7F" $
      encodeVarint 127 `shouldBe` BS.pack [0x7F]

    it "encodes 128 as two bytes" $
      encodeVarint 128 `shouldBe` BS.pack [0x80, 0x01]

    it "encodes 300 as two bytes" $
      encodeVarint 300 `shouldBe` BS.pack [0xAC, 0x02]

    it "round-trips all Word32" $ property $
      \(n :: Word32) ->
        let bs = encodeVarint n
            (val, rest) = decodeVarint bs
        in val === n .&&. rest === BS.empty

    it "values 0-127 encode to exactly 1 byte" $ property $
      forAll (choose (0, 127 :: Word32)) $ \n ->
        BS.length (encodeVarint n) === 1

    it "values 128-16383 encode to exactly 2 bytes" $ property $
      forAll (choose (128, 16383 :: Word32)) $ \n ->
        BS.length (encodeVarint n) === 2
