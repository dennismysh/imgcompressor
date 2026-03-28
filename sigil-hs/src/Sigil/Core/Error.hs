module Sigil.Core.Error
  ( SigilError(..)
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word8, Word32)

data SigilError
  = InvalidMagic ByteString
  | UnsupportedVersion Word8 Word8
  | CrcMismatch { expected :: Word32, actual :: Word32 }
  | InvalidPredictor Word8
  | TruncatedInput
  | InvalidDimensions Word32 Word32
  | InvalidColorSpace Word8
  | InvalidBitDepth Word8
  | InvalidTag ByteString
  | MissingChunk String
  | IoError String
  deriving (Show, Eq)
