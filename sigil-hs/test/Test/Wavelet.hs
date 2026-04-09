module Test.Wavelet (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int32)
import qualified Data.Vector.Unboxed as VU

import Sigil.Codec.Wavelet
  ( lift53Forward1D
  , lift53Inverse1D
  , dwt2DForward
  , dwt2DInverse
  , dwtForwardMulti
  , dwtInverseMulti
  , computeLevels
  )

spec :: Spec
spec = describe "Wavelet" $ do
  describe "1D lift 5/3" $ do
    it "round-trips length 1" $
      let v = VU.fromList [42 :: Int32]
          (s, d) = lift53Forward1D v
      in lift53Inverse1D s d `shouldBe` v

    it "round-trips length 2" $
      let v = VU.fromList [10, 20 :: Int32]
          (s, d) = lift53Forward1D v
      in lift53Inverse1D s d `shouldBe` v

    it "round-trips length 3" $
      let v = VU.fromList [10, 20, 30 :: Int32]
          (s, d) = lift53Forward1D v
      in lift53Inverse1D s d `shouldBe` v

    it "round-trips length 4" $
      let v = VU.fromList [1, 2, 3, 4 :: Int32]
          (s, d) = lift53Forward1D v
      in lift53Inverse1D s d `shouldBe` v

    it "round-trips length 8" $
      let v = VU.fromList [10, 20, 30, 40, 50, 60, 70, 80 :: Int32]
          (s, d) = lift53Forward1D v
      in lift53Inverse1D s d `shouldBe` v

    it "round-trips odd length 7" $
      let v = VU.fromList [5, 15, 25, 35, 45, 55, 65 :: Int32]
          (s, d) = lift53Forward1D v
      in lift53Inverse1D s d `shouldBe` v

    it "round-trips constant signal" $
      let v = VU.fromList [100, 100, 100, 100 :: Int32]
          (s, d) = lift53Forward1D v
      in do
        -- Detail should be zero for constant signal
        d `shouldBe` VU.fromList [0, 0]
        lift53Inverse1D s d `shouldBe` v

    it "round-trips arbitrary vectors (QuickCheck)" $ property $
      forAll (choose (2, 64 :: Int)) $ \n ->
        forAll (vectorOf n (choose (-500, 500) :: Gen Int32)) $ \xs ->
          let v = VU.fromList xs
              (s, d) = lift53Forward1D v
          in lift53Inverse1D s d === v

  describe "2D DWT" $ do
    it "round-trips a 4x4 array" $
      let arr = VU.fromList [ 1, 2, 3, 4
                           , 5, 6, 7, 8
                           , 9, 10, 11, 12
                           , 13, 14, 15, 16 :: Int32 ]
          (ll, lh, hl, hh) = dwt2DForward 4 4 arr
          result = dwt2DInverse 4 4 (ll, lh, hl, hh)
      in result `shouldBe` arr

    it "round-trips an 8x8 array" $
      let arr = VU.generate 64 $ \i -> fromIntegral i :: Int32
          (ll, lh, hl, hh) = dwt2DForward 8 8 arr
          result = dwt2DInverse 8 8 (ll, lh, hl, hh)
      in result `shouldBe` arr

    it "round-trips odd dimensions 5x7" $
      let arr = VU.generate 35 $ \i -> fromIntegral (i * 3 + 7) :: Int32
          (ll, lh, hl, hh) = dwt2DForward 5 7 arr
          result = dwt2DInverse 5 7 (ll, lh, hl, hh)
      in result `shouldBe` arr

    it "round-trips odd dimensions 3x3" $
      let arr = VU.fromList [10, 20, 30, 40, 50, 60, 70, 80, 90 :: Int32]
          (ll, lh, hl, hh) = dwt2DForward 3 3 arr
          result = dwt2DInverse 3 3 (ll, lh, hl, hh)
      in result `shouldBe` arr

    it "round-trips 1x1 array" $
      let arr = VU.fromList [42 :: Int32]
          (ll, lh, hl, hh) = dwt2DForward 1 1 arr
          result = dwt2DInverse 1 1 (ll, lh, hl, hh)
      in result `shouldBe` arr

    it "round-trips arbitrary 2D arrays (QuickCheck)" $ property $
      forAll (choose (1, 16 :: Int)) $ \w ->
        forAll (choose (1, 16 :: Int)) $ \h ->
          forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
            let arr = VU.fromList xs
                (ll, lh, hl, hh) = dwt2DForward w h arr
                result = dwt2DInverse w h (ll, lh, hl, hh)
            in result === arr

  describe "Multi-level DWT" $ do
    it "round-trips 8x8 with 1 level" $
      let arr = VU.generate 64 $ \i -> fromIntegral i :: Int32
          (ll, bands) = dwtForwardMulti 1 8 8 arr
          result = dwtInverseMulti 1 8 8 ll bands
      in result `shouldBe` arr

    it "round-trips 8x8 with 2 levels" $
      let arr = VU.generate 64 $ \i -> fromIntegral i :: Int32
          (ll, bands) = dwtForwardMulti 2 8 8 arr
          result = dwtInverseMulti 2 8 8 ll bands
      in result `shouldBe` arr

    it "round-trips 16x16 with 3 levels" $
      let arr = VU.generate 256 $ \i -> fromIntegral (i `mod` 200 - 100) :: Int32
          (ll, bands) = dwtForwardMulti 3 16 16 arr
          result = dwtInverseMulti 3 16 16 ll bands
      in result `shouldBe` arr

    it "round-trips odd dimensions 7x5 with 1 level" $
      let arr = VU.generate 35 $ \i -> fromIntegral (i * 7 - 20) :: Int32
          (ll, bands) = dwtForwardMulti 1 7 5 arr
          result = dwtInverseMulti 1 7 5 ll bands
      in result `shouldBe` arr

    it "round-trips arbitrary multi-level (QuickCheck)" $ property $
      forAll (choose (4, 16 :: Int)) $ \w ->
        forAll (choose (4, 16 :: Int)) $ \h ->
          let lvls = computeLevels w h
          in forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
               let arr = VU.fromList xs
                   (ll, bands) = dwtForwardMulti lvls w h arr
                   result = dwtInverseMulti lvls w h ll bands
               in result === arr

  describe "computeLevels" $ do
    it "returns 1 for 8x8" $
      computeLevels 8 8 `shouldBe` 1

    it "returns 1 for 16x16" $
      computeLevels 16 16 `shouldBe` 1

    it "returns 2 for 32x32" $
      computeLevels 32 32 `shouldBe` 2

    it "returns 5 for 256x256" $
      computeLevels 256 256 `shouldBe` 5

    it "returns 5 for 1024x1024" $
      computeLevels 1024 1024 `shouldBe` 5

    it "uses the smaller dimension" $
      computeLevels 1024 8 `shouldBe` computeLevels 8 1024
