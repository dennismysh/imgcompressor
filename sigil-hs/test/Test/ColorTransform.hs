module Test.ColorTransform (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Word (Word8)
import qualified Data.Vector as V

import Sigil.Codec.ColorTransform (forwardRCT, inverseRCT)

spec :: Spec
spec = describe "ColorTransform (RCT)" $ do
  it "round-trips black (0,0,0)" $
    let pixels = V.fromList [0, 0, 0 :: Word8]
        (y, cb, cr) = forwardRCT 1 1 pixels
        result = inverseRCT 1 1 (y, cb, cr)
    in result `shouldBe` pixels

  it "round-trips white (255,255,255)" $
    let pixels = V.fromList [255, 255, 255 :: Word8]
        (y, cb, cr) = forwardRCT 1 1 pixels
        result = inverseRCT 1 1 (y, cb, cr)
    in result `shouldBe` pixels

  it "round-trips red (255,0,0)" $
    let pixels = V.fromList [255, 0, 0 :: Word8]
        (y, cb, cr) = forwardRCT 1 1 pixels
        result = inverseRCT 1 1 (y, cb, cr)
    in result `shouldBe` pixels

  it "round-trips green (0,255,0)" $
    let pixels = V.fromList [0, 255, 0 :: Word8]
        (y, cb, cr) = forwardRCT 1 1 pixels
        result = inverseRCT 1 1 (y, cb, cr)
    in result `shouldBe` pixels

  it "round-trips blue (0,0,255)" $
    let pixels = V.fromList [0, 0, 255 :: Word8]
        (y, cb, cr) = forwardRCT 1 1 pixels
        result = inverseRCT 1 1 (y, cb, cr)
    in result `shouldBe` pixels

  it "forward RCT produces correct Y, Cb, Cr for known input" $
    -- R=100, G=150, B=200
    -- Y  = (100 + 2*150 + 200) div 4 = 600 div 4 = 150
    -- Cb = 200 - 150 = 50
    -- Cr = 100 - 150 = -50
    let pixels = V.fromList [100, 150, 200 :: Word8]
        (y, cb, cr) = forwardRCT 1 1 pixels
    in do
      y  `shouldBe` V.fromList [150]
      cb `shouldBe` V.fromList [50]
      cr `shouldBe` V.fromList [-50]

  it "round-trips a 2x2 image" $
    let pixels = V.fromList [ 10, 20, 30
                            , 40, 50, 60
                            , 70, 80, 90
                            , 100, 110, 120 :: Word8 ]
        (y, cb, cr) = forwardRCT 2 2 pixels
        result = inverseRCT 2 2 (y, cb, cr)
    in result `shouldBe` pixels

  it "round-trips arbitrary RGB pixels (QuickCheck)" $ property $
    forAll (choose (1, 8 :: Int)) $ \w ->
      forAll (choose (1, 8 :: Int)) $ \h ->
        forAll (vectorOf (w * h * 3) (arbitrary :: Gen Word8)) $ \pixelList ->
          let pixels = V.fromList pixelList
              (y, cb, cr) = forwardRCT w h pixels
              result = inverseRCT w h (y, cb, cr)
          in result === pixels
