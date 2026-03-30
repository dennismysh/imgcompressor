# Sigil tANS Entropy Coder — Design Spec

**Date**: 2026-03-30
**Scope**: Replace Rice-Golomb with tANS (table-based Asymmetric Numeral Systems) in the Sigil codec
**Version**: Sigil v0.3 (format-breaking change)

---

## 1. Purpose

Replace the Rice-Golomb entropy coder with tANS to dramatically improve compression on high-entropy photographic content where Sigil currently loses badly to PNG. The prediction pipeline (predict → zigzag → tokenize) stays unchanged. Only the final entropy coding stage changes.

**Current state (Rice-Golomb):**
- Noise 128x128: Sigil 53KB vs PNG 1.2KB (44x worse)
- Checkerboard 64x64: Sigil 502B vs PNG 207B (2.4x worse)
- Gradient 256x256: Sigil 3.9KB vs PNG 186KB (47x better)

**Target:** Match or beat PNG on all image types.

---

## 2. How tANS Works

tANS encodes a stream of symbols using a finite-state automaton. The key idea: the encoder's state encodes fractional bits of information, allowing near-optimal compression (approaching Shannon entropy) without the complexity of arithmetic coding.

### Encoding (high level)
1. **Build frequency table** — count occurrences of each symbol in the data
2. **Build tANS table** — a lookup table of size L (power of 2, typically 2048-4096) that maps (state, symbol) → (new_state, bits_to_output)
3. **Encode symbols** — process symbols in reverse order (!), using the table to transition states and emit bits
4. **Output** — the final state + the accumulated bit stream (read in reverse during decode)

### Decoding (high level)
1. **Read frequency table** from bitstream
2. **Rebuild tANS table** — same construction as encoder
3. **Read initial state** from bitstream
4. **Decode symbols** — for each step: table[state] gives (symbol, num_bits); read num_bits from stream to get next state

### Why tANS beats Rice-Golomb
- Rice assumes a geometric distribution (good for residuals near zero, bad for varied distributions)
- tANS adapts to the actual symbol frequency distribution — whatever it is
- Decode is a single table lookup per symbol — very fast

---

## 3. What Changes in the Pipeline

### Before (v0.2)
```
predict → zigzag → tokenize → [Rice block encode] → bitstream
```
The token stream was encoded with per-block Rice parameters. The SDAT payload format was: predictor IDs + numBlocks + k values + Rice-coded tokens.

### After (v0.3)
```
predict → zigzag → [tANS encode zigzag values directly] → bitstream
```

**Key change:** We skip tokenization entirely. tANS encodes the zigzag-encoded residual values directly — it doesn't need the zero-run-length preprocessing because it naturally handles frequent zeros efficiently through its frequency table. A symbol that appears 50% of the time gets encoded in ~1 bit regardless of whether it's zero or not.

### New SDAT payload format
```
[predictor IDs — 1 byte each, only if adaptive]
[u32 BE: total sample count]
[u16 BE: frequency table size (number of unique symbols)]
[frequency table: (u16 symbol, u32 frequency) pairs]
[u32 BE: tANS final state]
[u32 BE: bitstream length in bits]
[bitstream bytes — tANS encoded, read in reverse during decode]
```

---

## 4. tANS Implementation Details

### Symbol space

Zigzag-encoded residuals are `u16` values in range [0, 510] (since residuals are in [-255, 255]). That's 511 possible symbols. The frequency table only stores symbols that actually appear.

### Table size L

L = 4096 (2^12). This is the number of states in the automaton. Larger L = better compression (closer to entropy) but more memory. 4096 is the standard choice for image codecs.

### Table construction (spread function)

The "precise" spread used by Zstandard:
1. Allocate L slots in the table
2. For each symbol, assign `frequency[symbol]` slots using a step of `(L >> 1) + (L >> 3) + 3` with position wrapping
3. Each slot maps a state to (symbol, number_of_output_bits, next_state_base)

### Encoding (reverse order)

tANS encodes **backwards** — the last symbol is encoded first. This is because the decoder reads forward. The encoder:
1. Starts with initial state = L (or any valid state)
2. For each symbol (in reverse): look up (state, symbol) in the encoding table → outputs some bits, transitions to new state
3. After all symbols: output the final state

### Decoding (forward order)

1. Read the initial state from the bitstream
2. For each step: `entry = decode_table[state]`; symbol = entry.symbol; read entry.nb_bits from stream; new_state = entry.base + read_bits
3. Repeat until all symbols decoded

### Bit output

During encoding, bits are pushed to a buffer. The buffer is written MSB-first for compatibility with our existing BitWriter. During decoding, bits are consumed from the same buffer.

---

## 5. File Changes

### Haskell (encoder + reference decoder)

**New file:**
- `sigil-hs/src/Sigil/Codec/ANS.hs` — tANS encoder and decoder: frequency table, table construction, encode, decode

**Modified files:**
- `sigil-hs/src/Sigil/Codec/Pipeline.hs` — replace Rice imports with ANS imports; `encodeData` uses ANS instead of Rice tokens; `decodeData` uses ANS decode
- `sigil-hs/src/Sigil.hs` — export ANS module
- `sigil-hs/package.yaml` — add ANS to exposed-modules

**Removed dependency:**
- `Sigil.Codec.Token` — no longer used in the pipeline (tokenization is unnecessary with tANS). Keep the module for backward compatibility but the pipeline bypasses it.
- `Sigil.Codec.Rice` — the Rice module stays (existing code) but the pipeline no longer calls it.

### Rust (decoder)

**New file:**
- `sigil-rs/src/ans.rs` — tANS decoder only (no encoder needed)

**Modified files:**
- `sigil-rs/src/pipeline.rs` — use ANS decode instead of Rice token stream decode
- `sigil-rs/src/lib.rs` — add `mod ans;`

**No longer used by pipeline:**
- `rice.rs` — kept but not called from pipeline
- `token.rs` — kept but not called from pipeline

---

## 6. Backward Compatibility

This is a **format-breaking change** (v0.2 → v0.3). The version bytes in the file header change from (0, 2) to (0, 3). Old `.sgl` v0.2 files cannot be decoded by a v0.3 decoder and vice versa.

The decoder should check the version and return `UnsupportedVersion` for v0.2 files. A future version could support both, but for now, clean break.

---

## 7. Testing

### Unit tests for ANS module
- **Frequency table construction:** known input → expected frequencies
- **tANS table construction:** verify table size = L, all symbols reachable
- **Round-trip:** encode then decode random symbol streams, verify exact match
- **Edge cases:** single-symbol stream (all zeros), two-symbol stream, max-entropy (uniform distribution)

### Pipeline round-trip
- Existing QuickCheck property: `decompress(compress(img)) == img` — unchanged, just exercises new code path

### Conformance
- Regenerate golden `.sgl` files (they'll be v0.3 format now)
- Verify all corpus images round-trip

### Comparison benchmarks
- Same 4 corpus images, report Sigil v0.3 size vs PNG size
- Target: Sigil ≤ PNG on all four images

---

## 8. Expected Compression Improvement

tANS approaches Shannon entropy — the theoretical minimum for lossless coding given the symbol frequencies. For the noise image where Rice produces 53KB and PNG produces 1.2KB, tANS should produce something close to PNG's result because both will be near the entropy limit. The prediction filters give Sigil a small edge on smooth content.

Conservative estimates:
- **Noise:** 53KB → ~1-2KB (massive improvement, close to PNG's 1.2KB)
- **Checkerboard:** 502B → ~100-200B (should beat PNG's 207B)
- **Gradient:** 3.9KB → ~2-3KB (slightly better, already good)
- **Flat white:** 166B → ~100-150B (already good)
