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

import Sigil.Core.Types
import Sigil.Core.Error (SigilError(..))

loadImage :: FilePath -> IO (Either SigilError (Header, Sigil.Core.Types.Image))
loadImage path = do
  result <- readImage path
  case result of
    Left err -> pure $ Left (IoError err)
    Right dyn -> pure $ dynamicToSigil dyn

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
dynamicToSigil _ = Left (IoError "unsupported pixel format (try 8-bit RGB/RGBA)")

imageToSigil :: JP.Image PixelRGB8 -> (Header, Sigil.Core.Types.Image)
imageToSigil img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) RGB Depth8 DwtLossless
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
      hdr = Header (fromIntegral w) (fromIntegral h) RGBA Depth8 DwtLossless
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
      hdr = Header (fromIntegral w) (fromIntegral h) Grayscale Depth8 DwtLossless
      rows = V.fromList
        [ V.fromList [ pixelAt img x y | x <- [0..w-1] ]
        | y <- [0..h-1]
        ]
  in (hdr, rows)

imageToSigilGrayAlpha :: JP.Image JP.PixelYA8 -> (Header, Sigil.Core.Types.Image)
imageToSigilGrayAlpha img =
  let w = imageWidth img
      h = imageHeight img
      hdr = Header (fromIntegral w) (fromIntegral h) GrayscaleAlpha Depth8 DwtLossless
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
