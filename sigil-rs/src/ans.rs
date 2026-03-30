/// Decode-only rANS implementation for Sigil v0.3.
///
/// Binary format:
///   [u32 BE: total_samples]
///   [u16 BE: num_unique_symbols]
///   [for each symbol: u16 BE symbol_value, u32 BE normalized_frequency]
///   [u32 BE: final_state]
///   [u32 BE: bitstream_length_in_bits]
///   [bitstream bytes — packed MSB-first]
pub fn ans_decode(data: &[u8], _expected_total: usize) -> Vec<u16> {
    if data.len() < 4 {
        return Vec::new();
    }

    let table_size: u32 = 4096;

    let total_samples = read_u32(data, 0) as usize;
    if total_samples == 0 {
        return Vec::new();
    }

    let num_symbols = read_u16(data, 4) as usize;

    // Parse and sort frequency table by symbol
    let mut entries: Vec<(u16, u32)> = Vec::with_capacity(num_symbols);
    for i in 0..num_symbols {
        let off = 6 + i * 6;
        let sym = read_u16(data, off);
        let freq = read_u32(data, off + 2);
        entries.push((sym, freq));
    }
    entries.sort_by_key(|&(sym, _)| sym);

    // Build cumulative frequencies
    let mut cum_freq: Vec<(u16, u32)> = Vec::with_capacity(num_symbols);
    let mut acc: u32 = 0;
    for &(sym, freq) in &entries {
        cum_freq.push((sym, acc));
        acc += freq;
    }

    // Read state and bitstream
    let freq_end = 6 + num_symbols * 6;
    let final_state = read_u32(data, freq_end);
    let _num_bits = read_u32(data, freq_end + 4);
    let bitstream = &data[freq_end + 8..];

    let mut reader = AnsBitReader::new(bitstream);
    let mut state = final_state;
    let mut result = Vec::with_capacity(total_samples);

    for _ in 0..total_samples {
        let slot = state % table_size;
        let idx = lookup_symbol(&cum_freq, slot);
        let (sym, cf) = cum_freq[idx];
        let freq = entries[idx].1;

        state = freq * (state / table_size) + (slot - cf);

        // Renormalize: read bits until state >= table_size
        while state < table_size {
            let bit = reader.read_bit();
            state = (state << 1) | (bit as u32);
        }

        result.push(sym);
    }

    result
}

fn lookup_symbol(cum_freq: &[(u16, u32)], slot: u32) -> usize {
    let mut lo = 0usize;
    let mut hi = cum_freq.len();
    while lo + 1 < hi {
        let mid = (lo + hi) / 2;
        if cum_freq[mid].1 <= slot {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    lo
}

struct AnsBitReader<'a> {
    data: &'a [u8],
    byte_ix: usize,
    bit_pos: u8,
}

impl<'a> AnsBitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        AnsBitReader { data, byte_ix: 0, bit_pos: 0 }
    }

    fn read_bit(&mut self) -> u32 {
        if self.byte_ix >= self.data.len() {
            return 0;
        }
        let bit = (self.data[self.byte_ix] >> (7 - self.bit_pos)) & 1;
        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.byte_ix += 1;
            self.bit_pos = 0;
        }
        bit as u32
    }
}

fn read_u32(data: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
}

fn read_u16(data: &[u8], off: usize) -> u16 {
    u16::from_be_bytes([data[off], data[off + 1]])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lookup_symbol() {
        let cum = vec![(0u16, 0u32), (1u16, 3072u32)];
        assert_eq!(lookup_symbol(&cum, 0), 0);
        assert_eq!(lookup_symbol(&cum, 3071), 0);
        assert_eq!(lookup_symbol(&cum, 3072), 1);
    }

    #[test]
    fn test_bit_reader() {
        let data = [0b10110010u8];
        let mut r = AnsBitReader::new(&data);
        assert_eq!(r.read_bit(), 1);
        assert_eq!(r.read_bit(), 0);
        assert_eq!(r.read_bit(), 1);
        assert_eq!(r.read_bit(), 1);
    }
}
