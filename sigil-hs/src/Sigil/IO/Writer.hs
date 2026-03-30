module Sigil.IO.Writer
  ( encodeSigilFile
  , writeSigilFile
  ) where

import Data.Binary.Put
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word8)
import Data.Text.Encoding (encodeUtf8)

import Sigil.Core.Types
import Sigil.Core.Chunk
import Sigil.Codec.Pipeline (compress)

-- | Magic bytes: 0x89 S G L \r \n
magic :: ByteString
magic = BS.pack [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A]

versionMajor, versionMinor :: Word8
versionMajor = 0
versionMinor = 3

encodeSigilFile :: Header -> Metadata -> Image -> BL.ByteString
encodeSigilFile hdr meta img = runPut $ do
  putByteString magic
  putWord8 versionMajor
  putWord8 versionMinor
  putChunk (makeChunk SHDR (encodeHeader hdr))
  if not (null (metaEntries meta))
    then putChunk (makeChunk SMTA (encodeMetadata meta))
    else pure ()
  let payload = compress hdr img
  putChunk (makeChunk SDAT payload)
  putChunk (makeChunk SEND BS.empty)

putChunk :: Chunk -> Put
putChunk c = do
  putByteString (tagBytes (chunkTag c))
  putWord32be (fromIntegral (BS.length (chunkPayload c)))
  putByteString (chunkPayload c)
  putWord32be (chunkCRC c)

encodeHeader :: Header -> ByteString
encodeHeader hdr = BL.toStrict $ runPut $ do
  putWord32be (width hdr)
  putWord32be (height hdr)
  putWord8 (fromIntegral $ fromEnum $ colorSpace hdr)
  putWord8 (case bitDepth hdr of Depth8 -> 8; Depth16 -> 16)
  putWord8 (fromIntegral $ fromEnum $ predictor hdr)

encodeMetadata :: Metadata -> ByteString
encodeMetadata (Metadata entries) = BL.toStrict $ runPut $
  mapM_ (\(k, v) -> do
    let kbs = encodeUtf8 k
    putWord16be (fromIntegral (BS.length kbs))
    putByteString kbs
    putWord32be (fromIntegral (BS.length v))
    putByteString v
  ) entries

writeSigilFile :: FilePath -> Header -> Metadata -> Image -> IO ()
writeSigilFile path hdr meta img =
  BL.writeFile path (encodeSigilFile hdr meta img)
