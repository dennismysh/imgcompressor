# Sigil

A lossless image compression codec with prediction-based filtering and Rice-Golomb entropy coding.

This is the Haskell reference implementation (`sigil-hs`). A Rust production codec is planned.

## How it works

Sigil compresses images through a pipeline of pure stages composed with Haskell's `Category` (`>>>`):

```
pixels → predict → zigzag → tokenize → Rice-Golomb encode → .sgl file
```

1. **Predict** — Each pixel is predicted from its neighbors (left, above, above-left). The residual (prediction error) is stored instead of the raw value. Six fixed predictors plus an adaptive mode that picks the best per row.
2. **ZigZag** — Signed residuals are mapped to unsigned values (0, -1, 1, -2, 2, ... → 0, 1, 2, 3, 4, ...).
3. **Tokenize** — Consecutive zeros are collapsed into run-length tokens. Non-zero values pass through as value tokens.
4. **Rice-Golomb** — Entropy coding with an optimal `k` parameter selected per block of 64 values.

The `.sgl` file format wraps encoded data in CRC32-verified chunks (similar to PNG).

## Results

```
Image: gradient_256x256.png (256x256, RGB, 8-bit)
Raw size: 196,608 bytes

Predictor       Encoded      Ratio
--------------------------------------
None              255,779     0.77x
Sub               213,392     0.92x
Up                210,262     0.94x
Average           106,968     1.84x
Paeth             176,853     1.11x
Gradient            3,680    53.43x
Adaptive            3,936    49.95x

PNG (file)        186,695     1.05x
```

## Building

Requires [Stack](https://docs.haskellstack.org/en/stable/) (installs GHC automatically).

```bash
cd sigil-hs
stack build        # build library + CLI
stack test         # run tests (44 tests)
stack bench        # run criterion benchmarks
```

## CLI usage

```bash
# Encode a PNG/JPEG to .sgl
sigil-hs encode photo.png -o photo.sgl

# Decode back to PNG
sigil-hs decode photo.sgl -o photo.png

# Show file metadata
sigil-hs info photo.sgl

# Verify lossless round-trip
sigil-hs verify photo.png

# Benchmark all predictors on an image
sigil-hs bench photo.png --iterations 10

# Benchmark across a directory of images
sigil-hs bench photo.png --compare ./images/

# Generate synthetic test corpus
sigil-hs generate-corpus -o tests/corpus
```

## Project structure

```
sigil-hs/
├── src/Sigil/
│   ├── Core/
│   │   ├── Types.hs        -- Image, Header, ColorSpace, BitDepth, PredictorId
│   │   ├── Chunk.hs        -- CRC32, chunk serialization
│   │   └── Error.hs        -- SigilError ADT
│   ├── Codec/
│   │   ├── Predict.hs      -- 6 predictors + adaptive selection
│   │   ├── ZigZag.hs       -- signed ↔ unsigned mapping
│   │   ├── Token.hs        -- zero-run-length encoding
│   │   ├── Rice.hs         -- Rice-Golomb with bit-level I/O
│   │   └── Pipeline.hs     -- Stage composition with Category
│   ├── IO/
│   │   ├── Reader.hs       -- .sgl parser
│   │   ├── Writer.hs       -- .sgl serializer
│   │   └── Convert.hs      -- JuicyPixels PNG/JPEG ↔ Sigil
│   └── Sigil.hs            -- re-exports
├── app/Main.hs              -- CLI
├── test/                     -- hspec + QuickCheck (44 tests)
└── bench/Main.hs            -- criterion benchmarks
```

## Testing

Every codec stage has QuickCheck property tests verifying round-trip correctness:

- `zigzag/unzigzag` round-trip for all values in [-255, 255]
- `predict + residual = original` for all predictor/pixel combinations
- `unpredictRow . predictRow = identity` for arbitrary rows
- `decompress . compress = identity` for arbitrary images up to 16x16
- File I/O round-trip through the full `.sgl` format
- Conformance golden tests against a deterministic test corpus

## File format

The `.sgl` format:

```
Magic (6 bytes): 0x89 S G L \r \n
Version: 0.2
Chunks: SHDR | SMTA | SDAT | SEND
Each chunk: Tag (4B) | Length (u32) | Payload | CRC32 (u32)
```

All integers are big-endian. CRC32 uses the PNG/ISO 3309 polynomial.
