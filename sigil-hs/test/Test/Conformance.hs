module Test.Conformance (spec) where

import Test.Hspec

import qualified Data.ByteString.Lazy as BL
import System.Directory (doesFileExist, createDirectoryIfMissing)
import System.FilePath ((</>), replaceExtension)

import Sigil

spec :: Spec
spec = describe "Conformance" $ do
  let corpusDir = "../tests/corpus"
      expectedDir = corpusDir </> "expected"
      testImages =
        [ "gradient_256x256.png"
        , "flat_white_100x100.png"
        , "noise_128x128.png"
        , "checkerboard_64x64.png"
        ]

  mapM_ (\imgName -> do
    let imgPath = corpusDir </> imgName
        sglName = replaceExtension imgName ".sgl"
        expectedPath = expectedDir </> sglName

    describe imgName $ do
      it "encodes deterministically (matches golden .sgl)" $ do
        exists <- doesFileExist imgPath
        if not exists
          then pendingWith $ "corpus image not found: " ++ imgPath
          else do
            result <- loadImage imgPath
            case result of
              Left err -> expectationFailure (show err)
              Right (hdr, img) -> do
                let encoded = encodeSigilFile hdr emptyMetadata img
                goldenExists <- doesFileExist expectedPath
                if goldenExists
                  then do
                    expected <- BL.readFile expectedPath
                    encoded `shouldBe` expected
                  else do
                    createDirectoryIfMissing True expectedDir
                    BL.writeFile expectedPath encoded
                    pendingWith $ "golden file created: " ++ expectedPath

      it "round-trips through .sgl format" $ do
        exists <- doesFileExist imgPath
        if not exists
          then pendingWith $ "corpus image not found: " ++ imgPath
          else do
            result <- loadImage imgPath
            case result of
              Left err -> expectationFailure (show err)
              Right (hdr, original) -> do
                let encoded = encodeSigilFile hdr emptyMetadata original
                case decodeSigilFile encoded of
                  Left err -> expectationFailure (show err)
                  Right (_, _, decoded) -> decoded `shouldBe` original
    ) testImages
