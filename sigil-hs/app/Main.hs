module Main where

import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import System.Directory (listDirectory, createDirectoryIfMissing)
import System.FilePath ((</>), takeExtension)
import Data.List (sortBy)
import Data.Ord (comparing, Down(..))
import Text.Printf (printf)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Vector as V
import Codec.Picture (generateImage, PixelRGB8(..), writePng)

import Sigil.Core.Types
  ( Header(..), width, height, colorSpace, bitDepth, compressionMethod, rowBytes
  , emptyMetadata, CompressionMethod(..)
  )
import Sigil.IO.Convert (loadImage, saveImage)
import Sigil.IO.Reader (readSigilFile, decodeSigilFile)
import Sigil.IO.Writer (writeSigilFile, encodeSigilFile)
import Sigil.Codec.Pipeline (compress, decompress)

data Command
  = Encode FilePath FilePath
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
    Encode input output       -> runEncode input output
    Decode input output       -> runDecode input output
    Info input                -> runInfo input
    Verify input              -> runVerify input
    Bench input iters mDir    -> runBench input iters mDir
    GenerateCorpus dir        -> runGenerateCorpus dir

runEncode :: FilePath -> FilePath -> IO ()
runEncode input output = do
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
      putStrLn $ "Compression: " ++ show (compressionMethod hdr)
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
runBench input iters Nothing = benchSingleImage input iters
runBench _input iters (Just dir) = benchCorpus dir iters

benchSingleImage :: FilePath -> Int -> IO ()
benchSingleImage input iters = do
  result <- loadImage input
  case result of
    Left err -> die (show err)
    Right (hdr, img) -> do
      let rawSize = rowBytes hdr * fromIntegral (height hdr)
      putStrLn $ "Image: " ++ input ++ " ("
        ++ show (width hdr) ++ "x" ++ show (height hdr)
        ++ ", " ++ show (colorSpace hdr) ++ ", " ++ show (bitDepth hdr) ++ ")"
      putStrLn $ "Raw size: " ++ show rawSize ++ " bytes"
      putStrLn ""
      putStrLn "Method          Encoded      Ratio    Encode ms    Decode ms"
      putStrLn "--------------------------------------------------------------"

      (encTime, encoded) <- benchmark iters (compress hdr img)
      let encSize = BS.length encoded
      (decTime, _decoded) <- benchmark iters (decompress hdr encoded)
      let ratio = fromIntegral rawSize / fromIntegral encSize :: Double
      printf "%-14s %9d %8.2fx %10.1f %12.1f\n"
        ("DWT+RCT" :: String) encSize ratio
        (encTime * 1000) (decTime * 1000)

      -- PNG comparison
      fileSize <- BS.length <$> BS.readFile input
      printf "\n%-14s %9d %8.2fx\n" ("PNG (file)" :: String) fileSize
        (fromIntegral rawSize / fromIntegral fileSize :: Double)

benchmark :: Int -> a -> IO (Double, a)
benchmark iters x = do
  start <- getCurrentTime
  let go 0 = pure x
      go n = x `seq` go (n - 1)
  result <- go iters
  end <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime end start) / fromIntegral iters :: Double
  pure (elapsed, result)

benchCorpus :: FilePath -> Int -> IO ()
benchCorpus dir iters = do
  files <- listDirectory dir
  let imageFiles = filter (\f -> takeExtension f `elem` [".png", ".jpg", ".jpeg", ".bmp"]) files
  if null imageFiles
    then die $ "No image files found in " ++ dir
    else do
      putStrLn $ "Corpus: " ++ dir ++ " (" ++ show (length imageFiles) ++ " images)"
      mapM_ (\f -> do
        putStrLn $ "\n" ++ replicate 60 '='
        benchSingleImage (dir </> f) iters
        ) imageFiles

runGenerateCorpus :: FilePath -> IO ()
runGenerateCorpus dir = do
  createDirectoryIfMissing True dir

  -- Gradient 256x256
  let gradient = generateImage
        (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y)
                           (fromIntegral ((x + y) `mod` 256))) 256 256
  writePng (dir </> "gradient_256x256.png") gradient
  putStrLn "Generated gradient_256x256.png"

  -- Flat white 100x100
  let flat = generateImage (\_ _ -> PixelRGB8 255 255 255) 100 100
  writePng (dir </> "flat_white_100x100.png") flat
  putStrLn "Generated flat_white_100x100.png"

  -- Noise 128x128 (deterministic via simple LCG)
  let noise = generateImage
        (\x y -> let seed = x * 128 + y
                     v = fromIntegral ((seed * 1103515245 + 12345) `mod` 256)
                 in PixelRGB8 v v v) 128 128
  writePng (dir </> "noise_128x128.png") noise
  putStrLn "Generated noise_128x128.png"

  -- Checkerboard 64x64
  let checker = generateImage
        (\x y -> if (x `div` 8 + y `div` 8) `mod` 2 == 0
                 then PixelRGB8 0 0 0
                 else PixelRGB8 255 255 255) 64 64
  writePng (dir </> "checkerboard_64x64.png") checker
  putStrLn "Generated checkerboard_64x64.png"

  putStrLn $ "\nCorpus written to " ++ dir
  putStrLn "Supply photo images manually: 640x480, 1920x1080, 3840x2160, 7680x4320"

die :: String -> IO ()
die msg = hPutStrLn stderr msg >> exitFailure
