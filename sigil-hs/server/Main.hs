{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Network.Wai.Middleware.Cors (simpleCors)
import Network.Wai.Handler.Warp (setPort, setTimeout, defaultSettings)
import Network.HTTP.Types.Status (status400, status404)

import qualified Codec.Picture as JP
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.Map.Strict as Map
import Data.IORef

import Control.Concurrent (forkIO, threadDelay)

import Sigil.Core.Types
import Sigil.IO.Convert (dynamicToSigil)
import Sigil.IO.Writer (encodeSigilFileWithProgress)
import Sigil.Codec.Pipeline (ProgressCallback)

import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data ProgressState = ProgressState
  { psStage  :: !T.Text
  , psPct    :: !Int
  , psDetail :: !(Maybe T.Text)
  }

type SigilSessionId = T.Text
type Sessions = IORef (Map.Map SigilSessionId (IORef ProgressState))

progressToJson :: ProgressState -> BL.ByteString
progressToJson (ProgressState stage pct detail) =
  BL.fromStrict $ TE.encodeUtf8 $ T.concat
    [ "{\"stage\":\""
    , stage
    , "\",\"pct\":"
    , T.pack (show pct)
    , case detail of
        Nothing -> ""
        Just d  -> T.concat [",\"detail\":\"", d, "\""]
    , "}"
    ]

main :: IO ()
main = do
  port <- maybe 3000 id . (>>= readMaybe) <$> lookupEnv "PORT"
  putStrLn $ "sigil-server starting on port " ++ show port
  sessions <- newIORef Map.empty
  let opts = Options 0 (setPort port $ setTimeout 300 defaultSettings) False
  scottyOpts opts $ do
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

    -- Progress polling endpoint
    get "/api/progress/:sessionId" $ do
      sid <- captureParam "sessionId"
      sessionMap <- liftIO $ readIORef sessions
      case Map.lookup sid sessionMap of
        Nothing -> do
          status status404
          setHeader "Content-Type" "application/json"
          raw "{\"error\":\"session not found\"}"
        Just ref -> do
          ps <- liftIO $ readIORef ref
          setHeader "Content-Type" "application/json"
          setHeader "Access-Control-Allow-Origin" "*"
          raw (progressToJson ps)

    post "/api/encode" $ do
      body' <- body
      sidHeader <- header "X-Session-Id"
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
              -- Set up progress callback
              callback <- liftIO $ case sidHeader of
                Nothing -> pure ((\_ _ _ -> pure ()) :: ProgressCallback)
                Just sessionIdLazy -> do
                  let sessionId = TL.toStrict sessionIdLazy
                  ref <- newIORef (ProgressState "starting" 0 Nothing)
                  atomicModifyIORef' sessions (\m -> (Map.insert sessionId ref m, ()))
                  -- Clean up session after 5 minutes
                  _ <- forkIO $ do
                    threadDelay (5 * 60 * 1000000)
                    atomicModifyIORef' sessions (\m -> (Map.delete sessionId m, ()))
                  pure $ \stage pct detail ->
                    writeIORef ref (ProgressState stage pct detail)

              sglBytes <- liftIO $ encodeSigilFileWithProgress callback hdr emptyMetadata img
              let originalSize = rowBytes hdr * fromIntegral (height hdr)
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
