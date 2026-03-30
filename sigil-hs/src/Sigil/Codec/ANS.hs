module Sigil.Codec.ANS
  ( ansEncode    -- :: [Word16] -> ByteString
  , ansDecode    -- :: ByteString -> Int -> [Word16]
  , FreqTable
  , NormFreqTable
  , buildFreqTable
  , normalizeFreqs
  , buildCumFreqs
  , tableLog
  , tableSize
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List (foldl', sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Word (Word8, Word16, Word32)

-- | log2 of the ANS table size
tableLog :: Int
tableLog = 12

-- | ANS table size (L = M = 2^tableLog = 4096)
tableSize :: Word32
tableSize = 4096

-- ── Frequency Tables ─────────────────────────────────────

-- | Raw frequency table: symbol -> count
type FreqTable = Map Word16 Int

-- | Normalized frequency table: symbol -> normalized count (sums to tableSize)
type NormFreqTable = Map Word16 Word32

-- | Count occurrences of each symbol.
buildFreqTable :: [Word16] -> FreqTable
buildFreqTable = foldl' (\m s -> Map.insertWith (+) s 1 m) Map.empty

-- | Normalize frequencies so they sum to exactly tableSize.
--   Every present symbol gets at least 1.
normalizeFreqs :: FreqTable -> NormFreqTable
normalizeFreqs ft
  | Map.null ft = Map.empty
  | Map.size ft == 1 =
      -- Single symbol: gets the entire table
      Map.map (const tableSize) ft
  | otherwise =
      let total = fromIntegral (sum (Map.elems ft)) :: Double
          tSize = fromIntegral tableSize :: Double
          -- Scale proportionally, giving at least 1 to each
          scaled = Map.map (\c ->
            max 1 (round (fromIntegral c / total * tSize))) ft
          curSum = sum (Map.elems scaled)
          diff = fromIntegral tableSize - fromIntegral curSum :: Int
      in applyDiff diff scaled

-- | Distribute 'diff' units across a NormFreqTable, keeping every frequency >= 1.
--   Positive diff: add to the highest-frequency symbol.
--   Negative diff: subtract from the highest-frequency symbols (each can donate
--   at most (freq - 1) units), iterating until diff is zero.
applyDiff :: Int -> NormFreqTable -> NormFreqTable
applyDiff 0 m = m
applyDiff d m
  | d > 0 =
      let maxSym = fst $ Map.foldlWithKey'
            (\(bestS, bestF) s f -> if f > bestF then (s, f) else (bestS, bestF))
            (0, 0) m
      in Map.adjust (+ fromIntegral d) maxSym m
  | otherwise =
      -- d < 0: subtract from the most-frequent symbol, up to (freq-1) units
      let (maxSym, maxFreq) = Map.foldlWithKey'
            (\(bestS, bestF) s f -> if f > bestF then (s, f) else (bestS, bestF))
            (0, 0) m
          canTake = fromIntegral maxFreq - 1  -- can donate at most (freq-1) to keep >= 1
          toTake  = min canTake (abs d)
          m'      = Map.adjust (\f -> f - fromIntegral toTake) maxSym m
          d'      = d + toTake
      in if toTake == 0
         then m  -- stuck (all freqs are 1), shouldn't happen with valid input
         else applyDiff d' m'

-- | Build cumulative frequencies from a normalized frequency table.
--   Sorted by symbol: cumFreq[s] = sum of normFreq for all symbols < s.
buildCumFreqs :: NormFreqTable -> Map Word16 Word32
buildCumFreqs nft =
  let sorted = sortBy (comparing fst) (Map.toList nft)
      (cumMap, _) = foldl' (\(m, acc) (sym, freq) ->
        (Map.insert sym acc m, acc + freq)) (Map.empty, 0) sorted
  in cumMap

-- ── Bit packing ──────────────────────────────────────────

-- | Pack a list of Bool (MSB-first) into bytes.
packBits :: [Bool] -> ByteString
packBits bits = BS.pack (go bits)
  where
    go [] = []
    go bs =
      let (chunk, rest) = splitAt 8 bs
          -- Pad last byte with zeros on the right
          padded = chunk ++ replicate (8 - length chunk) False
          byte = foldl' (\acc b -> (acc `shiftL` 1) .|. (if b then 1 else 0)) (0 :: Word8) padded
      in byte : go rest

-- | Unpack bytes into a list of Bool (MSB-first), limited to n bits.
unpackBits :: Int -> ByteString -> [Bool]
unpackBits n bs = take n $ concatMap byteToBits (BS.unpack bs)
  where
    byteToBits w = [ w .&. (1 `shiftL` (7 - i)) /= 0 | i <- [0..7] ]

-- ── Encoding ─────────────────────────────────────────────

-- | Encode a list of symbols into a ByteString.
ansEncode :: [Word16] -> ByteString
ansEncode [] = encodeEmpty
ansEncode syms =
  let -- Encode symbols in REVERSE order
      (finalState, bitsBuf) = foldl' encodeStep (tableSize, []) (reverse syms)
      -- bitsBuf has bits consed to front during encoding.
      -- LIFO: last symbol encoded (= first symbol in original order) has its
      -- bits at the front of the list. Decoder processes forward, so it reads
      -- the front first — exactly what we want. No reversal needed.
      packedBitstream = packBits bitsBuf
      bitCount = length bitsBuf
  in serializeEncoded nft finalState bitCount packedBitstream (length syms)
  where
    nft :: NormFreqTable
    nft = normalizeFreqs (buildFreqTable syms)

    cumFreqs :: Map Word16 Word32
    cumFreqs = buildCumFreqs nft

    encodeStep :: (Word32, [Bool]) -> Word16 -> (Word32, [Bool])
    encodeStep (state, bits) sym =
      let f  = nft Map.! sym
          cf = cumFreqs Map.! sym
          -- Renormalize BEFORE encode: output low bits while state >= 2 * freq
          -- This brings state into [freq, 2*freq), ensuring (state/freq) = 1
          -- after encode, state will be in [tableSize, 2*tableSize)
          (state', bits') = renormEncode state f bits
          -- Core rANS encode
          state'' = (state' `div` f) * tableSize + (state' `mod` f) + cf
      in (state'', bits')

    renormEncode :: Word32 -> Word32 -> [Bool] -> (Word32, [Bool])
    renormEncode state f bits
      | state >= 2 * f =
          let bit = state .&. 1 /= 0
          in renormEncode (state `shiftR` 1) f (bit : bits)
      | otherwise = (state, bits)

-- | Decode a ByteString back into symbols.
ansDecode :: ByteString -> Int -> [Word16]
ansDecode _ 0 = []
ansDecode bs numSyms =
  let (nft, finalState, bitCount, bitstreamBytes, _totalSamples) = deserializeEncoded bs
      cumFreqs = buildCumFreqs nft
      -- Build sorted list of (sym, freq, cumFreq) for lookup
      sortedSyms = sortBy (comparing fst) (Map.toList nft)
      symTable = [ (sym, freq, cumFreqs Map.! sym) | (sym, freq) <- sortedSyms ]
      -- Unpack bitstream
      allBits = unpackBits bitCount bitstreamBytes

      decodeStep (acc, state, bits) _ =
        let slot = state `mod` tableSize
            (sym, f, cf) = lookupSlot slot symTable
            -- Core rANS decode
            state' = f * (state `div` tableSize) + slot - cf
            -- Renormalize AFTER decode: read bits until state >= tableSize
            -- This undoes the encoder's post-encode renormalization
            (state'', bits') = renormDecode state' bits
        in (sym : acc, state'', bits')

      -- Decode forward
      (decoded, _, _) = foldl' decodeStep ([], finalState, allBits) [1..numSyms]
  in reverse decoded

-- | Renormalize during decode: read bits until state >= tableSize.
renormDecode :: Word32 -> [Bool] -> (Word32, [Bool])
renormDecode state bits
  | state < tableSize =
      case bits of
        (b:rest) ->
          let bitVal = if b then 1 else 0 :: Word32
          in renormDecode ((state `shiftL` 1) .|. bitVal) rest
        [] -> (state, [])  -- no more bits
  | otherwise = (state, bits)

-- | Binary search on cumulative frequencies to find the symbol owning a slot.
lookupSlot :: Word32 -> [(Word16, Word32, Word32)] -> (Word16, Word32, Word32)
lookupSlot slot table = go table
  where
    go [(sym, f, cf)] = (sym, f, cf)
    go ((sym, f, cf) : rest@((_, _, nextCf) : _))
      | slot < nextCf = (sym, f, cf)
      | otherwise = go rest
    go [] = error "lookupSlot: empty table"

-- ── Serialization ────────────────────────────────────────

-- Format:
--   [u32 BE: total_samples]
--   [u16 BE: num_unique_symbols]
--   [for each symbol: u16 BE symbol_value, u32 BE normalized_frequency]
--   [u32 BE: final ANS state]
--   [u32 BE: bitstream_length in bits]
--   [bitstream bytes — packed MSB-first]

encodeEmpty :: ByteString
encodeEmpty = BS.pack
  [ 0, 0, 0, 0   -- total_samples = 0
  , 0, 0          -- num_unique = 0
  , 0, 0, 0, 0   -- state = 0
  , 0, 0, 0, 0   -- bitCount = 0
  ]

serializeEncoded :: NormFreqTable -> Word32 -> Int -> ByteString -> Int -> ByteString
serializeEncoded nft finalState bitCount bitstreamBytes totalSamples =
  let sorted = sortBy (comparing fst) (Map.toList nft)
      numUnique = length sorted
      header = putU32BE (fromIntegral totalSamples)
            <> putU16BE (fromIntegral numUnique)
      freqData = mconcat [ putU16BE sym <> putU32BE freq | (sym, freq) <- sorted ]
      trailer = putU32BE finalState
             <> putU32BE (fromIntegral bitCount)
             <> bitstreamBytes
  in header <> freqData <> trailer

deserializeEncoded :: ByteString -> (NormFreqTable, Word32, Int, ByteString, Int)
deserializeEncoded bs =
  let totalSamples = getU32BE bs 0
      numUnique = getU16BE bs 4
      -- Read freq table
      (nft, off) = readFreqTable bs 6 (fromIntegral numUnique)
      finalState = getU32BE bs off
      bitCount = fromIntegral (getU32BE bs (off + 4))
      bitstreamBytes = BS.drop (off + 8) bs
  in (nft, finalState, bitCount, bitstreamBytes, fromIntegral totalSamples)

readFreqTable :: ByteString -> Int -> Int -> (NormFreqTable, Int)
readFreqTable bs startOff count = foldl' step (Map.empty, startOff) [1..count]
  where
    step (m, off) _ =
      let sym = getU16BE bs off
          freq = getU32BE bs (off + 2)
      in (Map.insert sym freq m, off + 6)

-- ── Binary helpers ───────────────────────────────────────

putU32BE :: Word32 -> ByteString
putU32BE w = BS.pack
  [ fromIntegral (w `shiftR` 24)
  , fromIntegral (w `shiftR` 16)
  , fromIntegral (w `shiftR` 8)
  , fromIntegral w
  ]

putU16BE :: Word16 -> ByteString
putU16BE w = BS.pack
  [ fromIntegral (w `shiftR` 8)
  , fromIntegral w
  ]

getU32BE :: ByteString -> Int -> Word32
getU32BE bs off =
  (fromIntegral (BS.index bs off) `shiftL` 24)
  .|. (fromIntegral (BS.index bs (off + 1)) `shiftL` 16)
  .|. (fromIntegral (BS.index bs (off + 2)) `shiftL` 8)
  .|. fromIntegral (BS.index bs (off + 3))

getU16BE :: ByteString -> Int -> Word16
getU16BE bs off =
  (fromIntegral (BS.index bs off) `shiftL` 8)
  .|. fromIntegral (BS.index bs (off + 1))
