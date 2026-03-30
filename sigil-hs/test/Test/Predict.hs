module Test.Predict (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Int (Int16)
import Data.Word (Word8)
import qualified Data.Vector as V

import Sigil.Codec.Predict
  ( predict, residual, paeth
  , predictRow, unpredictRow
  , predictImage, unpredictImage
  , adaptiveRow
  )
import Sigil.Core.Types (Header(..), ColorSpace(..), BitDepth(..), CompressionMethod(..), PredictorId(..))
import Gen (arbitraryFixedPredictor, arbitraryImage)

spec :: Spec
spec = describe "Predict" $ do
  describe "individual predictors" $ do
    it "PNone always predicts 0" $ property $
      \a b c -> predict PNone a b (c :: Word8) == (0 :: Word8)

    it "PSub predicts left neighbor" $ property $
      \a b c -> predict PSub a b (c :: Word8) == a

    it "PUp predicts above neighbor" $ property $
      \a b c -> predict PUp a b (c :: Word8) == b

    it "PAverage predicts average of left and above" $ property $
      \a b c -> predict PAverage a b (c :: Word8) ==
        fromIntegral ((fromIntegral a + fromIntegral b :: Int) `div` 2)

  describe "residual law" $ do
    it "predict + residual == original for all fixed predictors" $ property $
      forAll arbitraryFixedPredictor $ \pid ->
        \a b c x ->
          let r = residual pid a b (c :: Word8) (x :: Word8)
          in fromIntegral (predict pid a b c) + r == fromIntegral x

  describe "row round-trip" $ do
    it "unpredictRow . predictRow == identity" $ property $
      forAll arbitraryFixedPredictor $ \pid ->
        forAll (choose (1 :: Int, 20)) $ \rowLen ->
          forAll (V.fromList <$> vectorOf rowLen (arbitrary :: Gen Word8)) $ \row ->
            let prevRow = V.replicate rowLen 0
                ch = 1
                residuals = predictRow pid prevRow row ch
                recovered = unpredictRow pid prevRow residuals ch
            in recovered == row

  describe "image round-trip" $ do
    it "unpredictImage . predictImage == identity for fixed predictors" $ property $
      forAll arbitraryFixedPredictor $ \pid ->
        forAll (choose (1, 8)) $ \w ->
          forAll (choose (1, 8)) $ \h ->
            forAll (arbitraryImage w h 3) $ \img ->
              let hdr = Header w h RGB Depth8 DwtLossless
                  (pids, residuals) = predictImage pid hdr img
                  recovered = unpredictImage hdr (pids, residuals)
              in recovered == img

  describe "adaptive" $ do
    it "adaptive picks the predictor with lowest cost" $ property $
      forAll (choose (3, 30)) $ \rowLen ->
        forAll (V.fromList <$> vectorOf rowLen (arbitrary :: Gen Word8)) $ \row ->
          forAll (V.fromList <$> vectorOf rowLen (arbitrary :: Gen Word8)) $ \prevRow ->
            let ch = 1
                (_, adaptiveResiduals) = adaptiveRow prevRow row ch
                fixedCost pid =
                  let rs = predictRow pid prevRow row ch
                  in sum (fmap (fromIntegral . abs) rs :: V.Vector Int)
                adaptiveCost = sum (fmap (fromIntegral . abs) adaptiveResiduals :: V.Vector Int)
                bestFixedCost = minimum [fixedCost pid | pid <- [PNone .. PGradient]]
            in adaptiveCost <= bestFixedCost
