module Sigil.IO.Reader
  ( decodeSigilFile
  , readSigilFile
  ) where

import Data.Binary.Get
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text.Encoding (decodeUtf8')
import Data.Word (Word8)

import Sigil.Core.Types
import Sigil.Core.Error
import Sigil.Core.Chunk
import Sigil.Codec.Pipeline (decompress)

magic :: ByteString
magic = BS.pack [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A]

decodeSigilFile :: BL.ByteString -> Either SigilError (Header, Metadata, Image)
decodeSigilFile input = case runGetOrFail parser input of
  Left (_, _, err) -> Left (IoError err)
  Right (_, _, result) -> result
  where
    parser = do
      m <- getByteString 6
      if m /= magic
        then pure $ Left (InvalidMagic m)
        else do
          major <- getWord8
          minor <- getWord8
          if major /= 0 || minor /= 2
            then pure $ Left (UnsupportedVersion major minor)
            else do
              chunks <- readChunks
              parseChunks chunks

readChunks :: Get [Chunk]
readChunks = do
  tag <- getByteString 4
  len <- getWord32be
  payload <- getByteString (fromIntegral len)
  crcVal <- getWord32be
  case tagFromBytes tag of
    Left _err -> pure []
    Right t -> do
      let chunk = Chunk t payload crcVal
      if t == SEND
        then pure [chunk]
        else do
          rest <- readChunks
          pure (chunk : rest)

parseChunks :: [Chunk] -> Get (Either SigilError (Header, Metadata, Image))
parseChunks chunks = pure $ do
  -- Verify all CRCs
  mapM_ verifyChunk chunks
  -- Find SHDR
  shdr <- case filter (\c -> chunkTag c == SHDR) chunks of
    (c:_) -> Right c
    []    -> Left (MissingChunk "SHDR")
  hdr <- decodeHeader (chunkPayload shdr)
  -- Optional SMTA
  let meta = case filter (\c -> chunkTag c == SMTA) chunks of
        (c:_) -> case decodeMetadata (chunkPayload c) of
                   Right m -> m
                   Left _  -> emptyMetadata
        []    -> emptyMetadata
  -- Concatenate SDAT payloads
  let sdatPayload = BS.concat
        [ chunkPayload c | c <- chunks, chunkTag c == SDAT ]
  img <- decompress hdr sdatPayload
  Right (hdr, meta, img)

decodeHeader :: ByteString -> Either SigilError Header
decodeHeader bs = case runGetOrFail parser (BL.fromStrict bs) of
  Left (_, _, _err) -> Left TruncatedInput
  Right (_, _, hdr) -> hdr
  where
    parser = do
      w <- getWord32be
      h <- getWord32be
      cs <- getWord8
      bd <- getWord8
      p  <- getWord8
      pure $ do
        colorSp <- toColorSpace cs
        bitD    <- toBitDepth bd
        pred'   <- toPredictorId p
        when' (w == 0 || h == 0) $ Left (InvalidDimensions w h)
        Right (Header w h colorSp bitD pred')

    toColorSpace :: Word8 -> Either SigilError ColorSpace
    toColorSpace 0 = Right Grayscale
    toColorSpace 1 = Right GrayscaleAlpha
    toColorSpace 2 = Right RGB
    toColorSpace 3 = Right RGBA
    toColorSpace n = Left (InvalidColorSpace n)

    toBitDepth :: Word8 -> Either SigilError BitDepth
    toBitDepth 8  = Right Depth8
    toBitDepth 16 = Right Depth16
    toBitDepth n  = Left (InvalidBitDepth n)

    toPredictorId :: Word8 -> Either SigilError PredictorId
    toPredictorId n
      | n <= fromIntegral (fromEnum (maxBound :: PredictorId)) = Right (toEnum (fromIntegral n))
      | otherwise = Left (InvalidPredictor n)

    when' False _ = Right ()
    when' True e  = e

decodeMetadata :: ByteString -> Either SigilError Metadata
decodeMetadata bs = case runGetOrFail parser (BL.fromStrict bs) of
  Left _ -> Right emptyMetadata
  Right (_, _, entries) -> Right (Metadata entries)
  where
    parser = do
      empty <- isEmpty
      if empty then pure []
      else do
        kLen <- getWord16be
        kBs <- getByteString (fromIntegral kLen)
        vLen <- getWord32be
        vBs <- getByteString (fromIntegral vLen)
        case decodeUtf8' kBs of
          Left _  -> pure []
          Right k -> do
            rest <- parser
            pure ((k, vBs) : rest)

readSigilFile :: FilePath -> IO (Either SigilError (Header, Metadata, Image))
readSigilFile path = do
  bs <- BL.readFile path
  pure (decodeSigilFile bs)
