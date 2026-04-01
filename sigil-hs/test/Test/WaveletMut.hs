module Test.WaveletMut (spec) where

import Test.Hspec
import Test.QuickCheck
import Data.Int (Int32)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU

import Sigil.Codec.Wavelet (lift53Forward1D, lift53Inverse1D)
import Sigil.Codec.WaveletMut (lift53Forward1DMut, lift53Inverse1DMut)

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
