module Test.WaveletMut (spec) where

import Test.Hspec
import Test.QuickCheck
import Data.Int (Int32)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Sigil.Codec.Wavelet (lift53Forward1D, lift53Inverse1D, dwt2DForward, dwt2DInverse,
                             dwtForwardMulti, dwtInverseMulti, computeLevels)
import Sigil.Codec.WaveletMut (lift53Forward1DMut, lift53Inverse1DMut,
                                dwt2DForwardMut, dwt2DInverseMut,
                                dwtForwardMultiMut, dwtInverseMultiMut)

toBoxed :: VU.Vector Int32 -> V.Vector Int32
toBoxed = V.convert

spec :: Spec
spec = describe "WaveletMut" $ do
  describe "1D lift53 equivalence" $ do
    it "forward matches immutable for arbitrary vectors" $ property $
      forAll (choose (2, 64 :: Int)) $ \n ->
        forAll (vectorOf n (choose (-500, 500) :: Gen Int32)) $ \xs ->
          let v = V.fromList xs
              vu = VU.fromList xs
              (sRef, dRef) = lift53Forward1D v
              (sMut, dMut) = lift53Forward1DMut vu
          in toBoxed sMut === sRef .&&. toBoxed dMut === dRef

    it "inverse matches immutable for arbitrary vectors" $ property $
      forAll (choose (2, 64 :: Int)) $ \n ->
        forAll (vectorOf n (choose (-500, 500) :: Gen Int32)) $ \xs ->
          let v = V.fromList xs
              vu = VU.fromList xs
              (sRef, dRef) = lift53Forward1D v
              (sMut, dMut) = lift53Forward1DMut vu
              resultRef = lift53Inverse1D sRef dRef
              resultMut = lift53Inverse1DMut sMut dMut
          in toBoxed resultMut === resultRef

    it "round-trips length 1" $
      let v = VU.fromList [42 :: Int32]
          (s, d) = lift53Forward1DMut v
      in lift53Inverse1DMut s d `shouldBe` v

    it "round-trips length 2" $
      let v = VU.fromList [10, 20 :: Int32]
          (s, d) = lift53Forward1DMut v
      in lift53Inverse1DMut s d `shouldBe` v

  describe "2D DWT equivalence" $ do
    it "forward matches immutable for arbitrary 2D arrays" $ property $
      forAll (choose (1, 16 :: Int)) $ \w ->
        forAll (choose (1, 16 :: Int)) $ \h ->
          forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
            let vRef = V.fromList xs
                vMut = VU.fromList xs
                (llRef, lhRef, hlRef, hhRef) = dwt2DForward w h vRef
                (llMut, lhMut, hlMut, hhMut) = dwt2DForwardMut w h vMut
            in conjoin
                 [ toBoxed llMut === llRef
                 , toBoxed lhMut === lhRef
                 , toBoxed hlMut === hlRef
                 , toBoxed hhMut === hhRef
                 ]

    it "round-trips arbitrary 2D arrays" $ property $
      forAll (choose (1, 16 :: Int)) $ \w ->
        forAll (choose (1, 16 :: Int)) $ \h ->
          forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
            let vu = VU.fromList xs
                (ll, lh, hl, hh) = dwt2DForwardMut w h vu
                result = dwt2DInverseMut w h (ll, lh, hl, hh)
            in result === vu

  describe "Multi-level DWT equivalence" $ do
    it "forward matches immutable for arbitrary multi-level" $ property $
      forAll (choose (4, 16 :: Int)) $ \w ->
        forAll (choose (4, 16 :: Int)) $ \h ->
          let lvls = computeLevels w h
          in forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
               let vRef = V.fromList xs
                   vMut = VU.fromList xs
                   (llRef, bandsRef) = dwtForwardMulti lvls w h vRef
                   (llMut, bandsMut) = dwtForwardMultiMut lvls w h vMut
               in conjoin $
                    (toBoxed llMut === llRef) :
                    [ conjoin [ toBoxed lhM === lhR
                              , toBoxed hlM === hlR
                              , toBoxed hhM === hhR ]
                    | ((lhR, hlR, hhR), (lhM, hlM, hhM)) <- zip bandsRef bandsMut
                    ]

    it "round-trips arbitrary multi-level" $ property $
      forAll (choose (4, 16 :: Int)) $ \w ->
        forAll (choose (4, 16 :: Int)) $ \h ->
          let lvls = computeLevels w h
          in forAll (vectorOf (w * h) (choose (-500, 500) :: Gen Int32)) $ \xs ->
               let vu = VU.fromList xs
                   (ll, bands) = dwtForwardMultiMut lvls w h vu
                   result = dwtInverseMultiMut lvls w h ll bands
               in result === vu
