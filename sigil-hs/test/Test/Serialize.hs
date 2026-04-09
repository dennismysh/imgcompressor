{-# LANGUAGE ScopedTypeVariables #-}
module Test.Serialize (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import Data.Word (Word32)
import qualified Data.ByteString as BS

import qualified Data.Vector.Unboxed as VU
import Sigil.Codec.Serialize (zigzag32, unzigzag32, encodeVarint, decodeVarint,
                               dpcmEncode, dpcmDecode, packSubband, unpackSubband,
                               packLLSubband, unpackLLSubband)

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

  describe "dpcm" $ do
    it "encodes a constant row as first value then zeros" $ do
      let input = VU.fromList [100, 100, 100, 100]
          result = dpcmEncode 4 input
      result `shouldBe` VU.fromList [100, 0, 0, 0]

    it "round-trips with width 1 (single-column)" $ property $
      forAll (choose (1, 50)) $ \len ->
        forAll (VU.replicateM len (choose (-1000, 1000 :: Int32))) $ \v ->
          dpcmDecode 1 (dpcmEncode 1 v) === v

    it "round-trips with arbitrary width" $ property $
      forAll (choose (1, 10)) $ \w ->
        let len = w * w  -- square for simplicity
        in forAll (VU.replicateM len (choose (-1000, 1000 :: Int32))) $ \v ->
             dpcmDecode w (dpcmEncode w v) === v

    it "resets delta at each row boundary" $ do
      -- 2x2 grid: row0=[10,20], row1=[50,60]
      let input = VU.fromList [10, 20, 50, 60]
          result = dpcmEncode 2 input
      -- row0: 10, 20-10=10; row1: 50, 60-50=10
      result `shouldBe` VU.fromList [10, 10, 50, 10]

  describe "packSubband" $ do
    it "round-trips detail subband" $ property $
      forAll (choose (1, 100)) $ \len ->
        forAll (VU.replicateM len (choose (-5000, 5000 :: Int32))) $ \v ->
          let packed = packSubband v
              (unpacked, rest) = unpackSubband (VU.length v) packed
          in unpacked === v .&&. rest === BS.empty

  describe "packLLSubband" $ do
    it "round-trips LL subband with DPCM" $ property $
      forAll (choose (1, 10)) $ \w ->
        forAll (choose (1, 10)) $ \h ->
          forAll (VU.replicateM (w * h) (choose (-5000, 5000 :: Int32))) $ \v ->
            let packed = packLLSubband w v
                (unpacked, rest) = unpackLLSubband w (VU.length v) packed
            in unpacked === v .&&. rest === BS.empty
