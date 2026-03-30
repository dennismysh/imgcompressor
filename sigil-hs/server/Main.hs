{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Network.Wai.Middleware.Cors (simpleCors)
import Network.HTTP.Types.Status (status400)

import qualified Codec.Picture as JP
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL

import Sigil.Core.Types
import Sigil.IO.Convert (dynamicToSigil)
import Sigil.IO.Writer (encodeSigilFile)

import System.Environment (lookupEnv)
import Text.Read (readMaybe)

main :: IO ()
main = do
  port <- maybe 3000 id . (>>= readMaybe) <$> lookupEnv "PORT"
  putStrLn $ "sigil-server starting on port " ++ show port
  scotty port $ do
    middleware simpleCors

    get "/" $ do
      setHeader "Content-Type" "text/html"
      file "static/index.html"

    get "/index.html" $ do
      setHeader "Content-Type" "text/html"
      file "static/index.html"

    get "/sigil_wasm.js" $ do
      setHeader "Content-Type" "application/javascript"
      file "static/sigil_wasm.js"

    get "/sigil_wasm_bg.wasm" $ do
      setHeader "Content-Type" "application/wasm"
      file "static/sigil_wasm_bg.wasm"

    get "/health" $ do
      text "ok"

    post "/api/encode" $ do
      body' <- body
      case JP.decodeImage (BL.toStrict body') of
        Left err -> do
          status status400
          text (TL.pack $ "Failed to decode image: " ++ err)
        Right dynImg ->
          case dynamicToSigil dynImg of
            Left err -> do
              status status400
              text (TL.pack $ "Failed to convert image: " ++ show err)
            Right (hdr, img) -> do
              let sglBytes = encodeSigilFile hdr emptyMetadata img
                  originalSize = rowBytes hdr * fromIntegral (height hdr)
                  compressedSize = fromIntegral (BL.length sglBytes) :: Int
                  ratio = fromIntegral originalSize / fromIntegral compressedSize :: Double
              setHeader "Content-Type" "application/octet-stream"
              setHeader "X-Sigil-Width" (TL.pack $ show $ width hdr)
              setHeader "X-Sigil-Height" (TL.pack $ show $ height hdr)
              setHeader "X-Sigil-Color-Space" (TL.pack $ show $ colorSpace hdr)
              setHeader "X-Sigil-Original-Size" (TL.pack $ show originalSize)
              setHeader "X-Sigil-Compressed-Size" (TL.pack $ show compressedSize)
              setHeader "X-Sigil-Ratio" (TL.pack $ show ratio)
              raw sglBytes
