module Sigil.IO.Convert
  ( loadImage
  , saveImage
  , imageToSigil
  , sigilToImage
  , dynamicToSigil
  ) where

import Codec.Picture
  ( DynamicImage(..)
  , Image(..)
  , PixelRGB8(..)
  , PixelRGBA8(..)
  , Pixel8
  , readImage
  , writePng
  , generateImage
  , pixelAt
  , imageWidth
  , imageHeight
  )
import qualified Codec.Picture as JP
import qualified Data.Vector as V
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Data.Char (toLower)
import System.FilePath (takeExtension)
import System.Process (createProcess, proc, StdStream(..), std_out, std_err, waitForProcess)
import System.IO (hSetBinaryMode)
import System.Exit (ExitCode(..))
import Control.Exception (try, IOException)

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))

loadImage :: FilePath -> IO (Either SigilError (Header, Sigil.Core.Types.Image))
loadImage path
  | isRawFile path = loadRawImage path
  | otherwise = do
      result <- readImage path
      case result of
        Left err -> pure $ Left (IoError err)
        Right dyn -> pure $ dynamicToSigil dyn

-- | Check if a file has a raw camera extension supported via dcraw
isRawFile :: FilePath -> Bool
isRawFile path = map toLower (takeExtension path) `elem` [".rw2"]

-- | Load a raw camera file by invoking dcraw and parsing its PPM output
loadRawImage :: FilePath -> IO (Either SigilError (Header, Sigil.Core.Types.Image))
loadRawImage path = do
  result <- try $ createProcess (proc "dcraw" ["-c", "-w", path])
    { std_out = CreatePipe, std_err = CreatePipe }
  case result of
    Left e -> pure $ Left $ IoError $
      "dcraw not found — install with: brew install dcraw\n" ++ show (e :: IOException)
    Right (_, Just hout, Just herr, ph) -> do
      hSetBinaryMode hout True
      ppmData <- BS.hGetContents hout
      exitCode <- waitForProcess ph
      case exitCode of
        ExitFailure _ -> do
          errMsg <- BS.hGetContents herr
          pure $ Left $ IoError $ "dcraw failed: " ++ C8.unpack errMsg
        ExitSuccess -> case parsePPM ppmData of
          Left err -> pure $ Left $ IoError $ "failed to parse dcraw output: " ++ err
          Right (w, h, pixels) ->
            let hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 DwtANS
                stride = w * 3
                rows = V.generate h $ \y ->
                  V.fromList $ BS.unpack $ BS.take stride $ BS.drop (y * stride) pixels
            in pure $ Right (hdr, rows)
    Right _ -> pure $ Left $ IoError "failed to create dcraw process"

-- | Parse PPM P6 binary format
parsePPM :: BS.ByteString -> Either String (Int, Int, BS.ByteString)
parsePPM bs = do
  rest0 <- maybe (Left "not a PPM P6 file") Right $ BS.stripPrefix "P6" bs
  let s1 = skipWsComments rest0
  (w, s2) <- maybe (Left "bad width") Right $ C8.readInt s1
  let s3 = skipWsComments s2
  (h, s4) <- maybe (Left "bad height") Right $ C8.readInt s3
  let s5 = skipWsComments s4
  (maxval, s6) <- maybe (Left "bad maxval") Right $ C8.readInt s5
  if maxval > 255
    then Left "16-bit PPM not supported — dcraw should output 8-bit"
    else Right (w, h, BS.drop 1 s6)

-- | Skip whitespace and '#' comment lines in PPM header
skipWsComments :: BS.ByteString -> BS.ByteString
skipWsComments s
  | BS.null s = s
  | C8.head s == '#'  = skipWsComments $ BS.drop 1 $ C8.dropWhile (/= '\n') s
  | C8.head s <= ' '  = skipWsComments $ BS.drop 1 s
  | otherwise         = s

saveImage :: FilePath -> Header -> Sigil.Core.Types.Image -> IO ()
saveImage path hdr img = case colorSpace hdr of
  RGB  -> writePng path (sigilToImage hdr img)
  RGBA -> writePng path (sigilToImageRGBA hdr img)
  _    -> writePng path (sigilToImage hdr img)  -- fallback to RGB

dynamicToSigil :: DynamicImage -> Either SigilError (Header, Sigil.Core.Types.Image)
dynamicToSigil (ImageRGB8 img)  = Right (imageToSigil img)
dynamicToSigil (ImageRGBA8 img) = Right (imageToSigilRGBA img)
dynamicToSigil (ImageY8 img)    = Right (imageToSigilGray img)
dynamicToSigil (ImageYA8 img)   = Right (imageToSigilGrayAlpha img)
dynamicToSigil other = Right (imageToSigil (JP.convertRGB8 other))

imageToSigil :: JP.Image PixelRGB8 -> (Header, Sigil.Core.Types.Image)
imageToSigil img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 DwtANS
      rows = V.fromList
        [ V.fromList
            [ comp
            | x <- [0..w-1]
            , let PixelRGB8 r g b = pixelAt img x y
            , comp <- [r, g, b]
            ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

sigilToImage :: Header -> Sigil.Core.Types.Image -> JP.Image PixelRGB8
sigilToImage hdr img =
  let w = fromIntegral (width hdr)
      h = fromIntegral (height hdr)
  in generateImage (\x y ->
    let row = img V.! y
        base = x * 3
    in PixelRGB8 (row V.! base) (row V.! (base + 1)) (row V.! (base + 2))
  ) w h

imageToSigilRGBA :: JP.Image PixelRGBA8 -> (Header, Sigil.Core.Types.Image)
imageToSigilRGBA img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) RGBA Depth8 DwtANS
      rows = V.fromList
        [ V.fromList
            [ comp
            | x <- [0..w-1]
            , let PixelRGBA8 r g b a = pixelAt img x y
            , comp <- [r, g, b, a]
            ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

sigilToImageRGBA :: Header -> Sigil.Core.Types.Image -> JP.Image PixelRGBA8
sigilToImageRGBA hdr img =
  let w = fromIntegral (width hdr)
      h = fromIntegral (height hdr)
  in generateImage (\x y ->
    let row = img V.! y
        base = x * 4
    in PixelRGBA8 (row V.! base) (row V.! (base+1)) (row V.! (base+2)) (row V.! (base+3))
  ) w h

imageToSigilGray :: JP.Image Pixel8 -> (Header, Sigil.Core.Types.Image)
imageToSigilGray img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) Grayscale Depth8 DwtANS
      rows = V.fromList
        [ V.fromList [ pixelAt img x y | x <- [0..w-1] ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

imageToSigilGrayAlpha :: JP.Image JP.PixelYA8 -> (Header, Sigil.Core.Types.Image)
imageToSigilGrayAlpha img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) GrayscaleAlpha Depth8 DwtANS
      rows = V.fromList
        [ V.fromList
            [ comp
            | x <- [0..w-1]
            , let JP.PixelYA8 y' a = pixelAt img x y
            , comp <- [y', a]
            ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)
