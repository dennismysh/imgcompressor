module Main where

import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import qualified Data.ByteString.Lazy as BL

import Sigil.Core.Types
  ( Header(..), width, height, colorSpace, bitDepth, predictor, rowBytes
  , emptyMetadata
  )
import Sigil.IO.Convert (loadImage, saveImage)
import Sigil.IO.Reader (readSigilFile, decodeSigilFile)
import Sigil.IO.Writer (writeSigilFile, encodeSigilFile)

data Command
  = Encode FilePath FilePath (Maybe String)
  | Decode FilePath FilePath
  | Info FilePath
  | Verify FilePath
  | Bench FilePath Int (Maybe FilePath)
  | GenerateCorpus FilePath

commandParser :: Parser Command
commandParser = subparser
  ( command "encode" (info encodeCmd (progDesc "Encode an image to .sgl"))
  <> command "decode" (info decodeCmd (progDesc "Decode .sgl to image"))
  <> command "info" (info infoCmd (progDesc "Show .sgl file metadata"))
  <> command "verify" (info verifyCmd (progDesc "Verify round-trip integrity"))
  <> command "bench" (info benchCmd (progDesc "Benchmark compression"))
  <> command "generate-corpus" (info corpusCmd (progDesc "Generate synthetic test corpus"))
  )

encodeCmd :: Parser Command
encodeCmd = Encode
  <$> argument str (metavar "INPUT")
  <*> strOption (short 'o' <> long "output" <> metavar "OUTPUT")
  <*> optional (strOption (long "predictor" <> metavar "PREDICTOR"))

decodeCmd :: Parser Command
decodeCmd = Decode
  <$> argument str (metavar "INPUT")
  <*> strOption (short 'o' <> long "output" <> metavar "OUTPUT")

infoCmd :: Parser Command
infoCmd = Info <$> argument str (metavar "INPUT")

verifyCmd :: Parser Command
verifyCmd = Verify <$> argument str (metavar "INPUT")

benchCmd :: Parser Command
benchCmd = Bench
  <$> argument str (metavar "INPUT")
  <*> option auto (long "iterations" <> value 10 <> metavar "N")
  <*> optional (strOption (long "compare" <> metavar "DIR"))

corpusCmd :: Parser Command
corpusCmd = GenerateCorpus
  <$> strOption (short 'o' <> long "output-dir" <> value "tests/corpus" <> metavar "DIR")

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper)
    (fullDesc <> progDesc "Sigil image codec — Haskell reference" <> header "sigil-hs"))
  case cmd of
    Encode input output mPred -> runEncode input output mPred
    Decode input output       -> runDecode input output
    Info input                -> runInfo input
    Verify input              -> runVerify input
    Bench input iters mDir    -> runBench input iters mDir
    GenerateCorpus dir        -> runGenerateCorpus dir

runEncode :: FilePath -> FilePath -> Maybe String -> IO ()
runEncode input output _mPred = do
  result <- loadImage input
  case result of
    Left err -> die (show err)
    Right (hdr, img) -> do
      writeSigilFile output hdr emptyMetadata img
      putStrLn $ "Encoded " ++ input ++ " -> " ++ output

runDecode :: FilePath -> FilePath -> IO ()
runDecode input output = do
  result <- readSigilFile input
  case result of
    Left err -> die (show err)
    Right (hdr, _, img) -> do
      saveImage output hdr img
      putStrLn $ "Decoded " ++ input ++ " -> " ++ output

runInfo :: FilePath -> IO ()
runInfo input = do
  bs <- BL.readFile input
  case decodeSigilFile bs of
    Left err -> die (show err)
    Right (hdr, meta, _) -> do
      putStrLn $ "File: " ++ input
      putStrLn $ "Dimensions: " ++ show (width hdr) ++ "x" ++ show (height hdr)
      putStrLn $ "Color space: " ++ show (colorSpace hdr)
      putStrLn $ "Bit depth: " ++ show (bitDepth hdr)
      putStrLn $ "Predictor: " ++ show (predictor hdr)
      putStrLn $ "Raw size: " ++ show (rowBytes hdr * fromIntegral (height hdr)) ++ " bytes"
      _ <- pure meta  -- suppress unused warning
      pure ()

runVerify :: FilePath -> IO ()
runVerify input = do
  result <- loadImage input
  case result of
    Left err -> die (show err)
    Right (hdr, original) -> do
      let encoded = encodeSigilFile hdr emptyMetadata original
      case decodeSigilFile encoded of
        Left err -> die ("Decode failed: " ++ show err)
        Right (_, _, decoded) ->
          if decoded == original
          then putStrLn $ "PASS: " ++ input ++ " round-trip verified"
          else do
            putStrLn $ "FAIL: " ++ input ++ " round-trip mismatch"
            exitFailure

runBench :: FilePath -> Int -> Maybe FilePath -> IO ()
runBench _ _ _ = putStrLn "bench: not yet implemented (Task 12)"

runGenerateCorpus :: FilePath -> IO ()
runGenerateCorpus _ = putStrLn "generate-corpus: not yet implemented (Task 13)"

die :: String -> IO ()
die msg = hPutStrLn stderr msg >> exitFailure
