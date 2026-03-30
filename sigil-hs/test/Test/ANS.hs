module Test.ANS (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word16)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map

import Sigil.Codec.ANS

spec :: Spec
spec = describe "ANS" $ do

  describe "Frequency tables" $ do
    it "buildFreqTable counts correctly" $ do
      let ft = buildFreqTable [0, 1, 0, 2, 0]
      Map.lookup 0 ft `shouldBe` Just 3
      Map.lookup 1 ft `shouldBe` Just 1
      Map.lookup 2 ft `shouldBe` Just 1

    it "normalizeFreqs sums to tableSize" $ property $
      forAll (listOf1 (choose (0, 510 :: Word16))) $ \syms ->
        let nft = normalizeFreqs (buildFreqTable syms)
        in sum (Map.elems nft) === fromIntegral tableSize

    it "every symbol gets at least frequency 1" $ property $
      forAll (listOf1 (choose (0, 510 :: Word16))) $ \syms ->
        let nft = normalizeFreqs (buildFreqTable syms)
        in all (>= 1) (Map.elems nft) === True

    it "single-symbol input normalized to tableSize" $ do
      let nft = normalizeFreqs (buildFreqTable (replicate 100 (42 :: Word16)))
      Map.lookup 42 nft `shouldBe` Just (fromIntegral tableSize)

  describe "Cumulative frequencies" $ do
    it "cumFreqs starts at 0" $ do
      let nft = normalizeFreqs (buildFreqTable [0, 1, 2 :: Word16])
          cum = buildCumFreqs nft
          minSym = minimum (Map.keys nft)
      Map.lookup minSym cum `shouldBe` Just 0

    it "cumFreqs + normFreqs of last symbol = tableSize" $ property $
      forAll (listOf1 (choose (0, 510 :: Word16))) $ \syms ->
        let nft = normalizeFreqs (buildFreqTable syms)
            cum = buildCumFreqs nft
            maxSym = maximum (Map.keys nft)
            lastCum = cum Map.! maxSym
            lastFreq = nft Map.! maxSym
        in lastCum + lastFreq === fromIntegral tableSize

  describe "Encode" $ do
    it "non-empty output for non-empty input" $ do
      let encoded = ansEncode [0, 1, 2, 3 :: Word16]
      BS.length encoded > 0 `shouldBe` True

    it "single-symbol stream compresses well (<= 20 bytes for 100 identical)" $ do
      let encoded = ansEncode (replicate 100 (5 :: Word16))
      -- Header: 6 bytes, 1 symbol entry: 6 bytes, state+bitcount: 8 bytes = 20 total
      BS.length encoded <= 20 `shouldBe` True

    it "all-same values compress extremely well" $ do
      let encoded = ansEncode (replicate 1000 (42 :: Word16))
      -- Header is ~12 bytes + 6 bytes for 1 symbol + 8 bytes state/bitcount = ~26 bytes
      -- No bits needed since single symbol never renormalizes
      BS.length encoded < 30 `shouldBe` True

  describe "Round-trip" $ do
    it "known sequence [0,1,2,3,0,0,0,1]" $ do
      let syms = [0, 1, 2, 3, 0, 0, 0, 1 :: Word16]
          encoded = ansEncode syms
          decoded = ansDecode encoded (length syms)
      decoded `shouldBe` syms

    it "single symbol" $ do
      let syms = [42 :: Word16]
          encoded = ansEncode syms
          decoded = ansDecode encoded (length syms)
      decoded `shouldBe` syms

    it "two symbols" $ do
      let syms = [0, 1 :: Word16]
          encoded = ansEncode syms
          decoded = ansDecode encoded (length syms)
      decoded `shouldBe` syms

    it "all 511 possible symbols [0..510]" $ do
      let syms = [0..510 :: Word16]
          encoded = ansEncode syms
          decoded = ansDecode encoded (length syms)
      decoded `shouldBe` syms

    it "QuickCheck: round-trip for arbitrary [Word16] in [0,510]" $ property $
      forAll (listOf1 (choose (0, 510 :: Word16))) $ \syms ->
        let encoded = ansEncode syms
            decoded = ansDecode encoded (length syms)
        in decoded === syms

    it "skewed distribution (99% zeros)" $ do
      let syms = replicate 990 (0 :: Word16) ++ replicate 10 (1 :: Word16)
          encoded = ansEncode syms
          decoded = ansDecode encoded (length syms)
      decoded `shouldBe` syms

    it "large stream (1000+ symbols)" $ property $
      forAll (vectorOf 1000 (choose (0, 510 :: Word16))) $ \syms ->
        let encoded = ansEncode syms
            decoded = ansDecode encoded (length syms)
        in decoded === syms

    it "repeated pattern" $ do
      let syms = concat (replicate 100 [0, 1, 2 :: Word16])
          encoded = ansEncode syms
          decoded = ansDecode encoded (length syms)
      decoded `shouldBe` syms

    it "empty input" $ do
      let encoded = ansEncode ([] :: [Word16])
          decoded = ansDecode encoded 0
      decoded `shouldBe` []
