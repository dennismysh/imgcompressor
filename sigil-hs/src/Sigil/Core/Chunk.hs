module Sigil.Core.Chunk
  ( Tag(..)
  , Chunk(..)
  , crc32
  , makeChunk
  , verifyChunk
  , tagBytes
  , tagFromBytes
  ) where

import Data.Bits (xor, shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word8, Word32)

import Sigil.Core.Error (SigilError(..))

data Tag = SHDR | SMTA | SPAL | SDAT | SEND
  deriving (Eq, Show, Enum, Bounded)

data Chunk = Chunk
  { chunkTag     :: Tag
  , chunkPayload :: ByteString
  , chunkCRC     :: Word32
  } deriving (Eq, Show)

makeChunk :: Tag -> ByteString -> Chunk
makeChunk tag payload = Chunk tag payload (crc32 payload)

verifyChunk :: Chunk -> Either SigilError ()
verifyChunk c =
  let computed = crc32 (chunkPayload c)
  in if computed == chunkCRC c
     then Right ()
     else Left (CrcMismatch { expected = chunkCRC c, actual = computed })

tagBytes :: Tag -> ByteString
tagBytes SHDR = "SHDR"
tagBytes SMTA = "SMTA"
tagBytes SPAL = "SPAL"
tagBytes SDAT = "SDAT"
tagBytes SEND = "SEND"

tagFromBytes :: ByteString -> Either SigilError Tag
tagFromBytes "SHDR" = Right SHDR
tagFromBytes "SMTA" = Right SMTA
tagFromBytes "SPAL" = Right SPAL
tagFromBytes "SDAT" = Right SDAT
tagFromBytes "SEND" = Right SEND
tagFromBytes bs     = Left (InvalidTag bs)

-- ── CRC32 (ISO 3309 / ITU-T V.42, same as PNG) ───────────

crc32 :: ByteString -> Word32
crc32 = xor 0xFFFFFFFF . BS.foldl' step 0xFFFFFFFF
  where
    step crc byte =
      let idx = fromIntegral ((crc `xor` fromIntegral byte) .&. 0xFF)
      in (crc `shiftR` 8) `xor` (crcTable !! idx)

crcTable :: [Word32]
crcTable = [ go n 8 | n <- [0..255] ]
  where
    go :: Word32 -> Int -> Word32
    go c 0 = c
    go c k = go (if c .&. 1 == 1
                  then 0xEDB88320 `xor` (c `shiftR` 1)
                  else c `shiftR` 1) (k - 1)
