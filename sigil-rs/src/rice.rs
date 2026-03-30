use crate::token::Token;

pub const BLOCK_SIZE: usize = 64;

pub struct BitReader<'a> {
    data: &'a [u8],
    byte_ix: usize,
    bit_pos: u8, // 0..7, next bit to read. MSB-first: bit 0 = bit 7 of byte
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BitReader { data, byte_ix: 0, bit_pos: 0 }
    }

    pub fn read_bit(&mut self) -> bool {
        let byte = self.data[self.byte_ix];
        let bit = (byte >> (7 - self.bit_pos)) & 1 != 0;
        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.byte_ix += 1;
            self.bit_pos = 0;
        }
        bit
    }

    pub fn read_bits(&mut self, n: u8) -> u16 {
        let mut val: u16 = 0;
        for _ in 0..n {
            val = (val << 1) | (self.read_bit() as u16);
        }
        val
    }
}

/// Decode one Rice-Golomb coded value.
/// Unary quotient (count ones until zero) + k-bit binary remainder.
pub fn rice_decode(k: u8, reader: &mut BitReader) -> u16 {
    // Read unary: count ones until we hit a zero
    let mut q: u16 = 0;
    while reader.read_bit() {
        q += 1;
    }
    // Read k-bit remainder
    let r = reader.read_bits(k);
    (q << k) | r
}

/// Decode the full token stream from an SDAT bitstream.
///
/// Format: [32-bit numBlocks (two 16-bit halves)] [4-bit k per block] [token bitstream]
/// Token bitstream: 1-bit flag per token.
///   Flag 1 = TValue (Rice-decoded with current block's k)
///   Flag 0 = TZeroRun (16-bit run length)
///
/// Block k tracking: advance to next k after every BLOCK_SIZE (64) TValues.
/// TZeroRun tokens don't affect block position.
/// Decoder uses total_samples to know when to stop.
pub fn decode_token_stream(data: &[u8], total_samples: usize) -> Vec<Token> {
    let mut reader = BitReader::new(data);

    // Read number of blocks (32 bits as two 16-bit halves, MSB first)
    let hi = reader.read_bits(16) as usize;
    let lo = reader.read_bits(16) as usize;
    let num_blocks = (hi << 16) | lo;

    // Read k values (4 bits each)
    let mut ks: Vec<u8> = Vec::with_capacity(num_blocks);
    for _ in 0..num_blocks {
        ks.push(reader.read_bits(4) as u8);
    }

    // Decode tokens
    let mut tokens = Vec::new();
    let mut remaining = total_samples as isize;
    let mut k_index = 0usize;
    let mut tval_pos = 0usize;

    while remaining > 0 {
        let k = if k_index < ks.len() { ks[k_index] } else { 0 };
        let flag = reader.read_bit();

        if flag {
            // TValue: consumes 1 sample, advances block position
            let val = rice_decode(k, &mut reader);
            tokens.push(Token::Value(val));
            remaining -= 1;
            tval_pos += 1;
            if tval_pos >= BLOCK_SIZE {
                k_index += 1;
                tval_pos = 0;
            }
        } else {
            // TZeroRun: consumes run_len samples, doesn't affect block position
            let run_len = reader.read_bits(16);
            tokens.push(Token::ZeroRun(run_len));
            remaining -= run_len as isize;
        }
    }

    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_bits_byte() {
        // 0xB2 = 10110010
        let data = [0xB2];
        let mut reader = BitReader::new(&data);
        assert_eq!(reader.read_bit(), true);   // 1
        assert_eq!(reader.read_bit(), false);  // 0
        assert_eq!(reader.read_bit(), true);   // 1
        assert_eq!(reader.read_bit(), true);   // 1
        assert_eq!(reader.read_bit(), false);  // 0
        assert_eq!(reader.read_bit(), false);  // 0
        assert_eq!(reader.read_bit(), true);   // 1
        assert_eq!(reader.read_bit(), false);  // 0
    }

    #[test]
    fn test_read_bits_16() {
        // 0x1234 = 0001_0010_0011_0100
        let data = [0x12, 0x34];
        let mut reader = BitReader::new(&data);
        assert_eq!(reader.read_bits(16), 0x1234);
    }

    #[test]
    fn test_rice_decode_k0_val0() {
        // k=0, val=0: unary 0 (just a zero bit), no remainder
        // Bits: 0 (zero bit = q=0, k=0 so no remainder bits)
        let data = [0x00]; // 00000000
        let mut reader = BitReader::new(&data);
        assert_eq!(rice_decode(0, &mut reader), 0);
    }

    #[test]
    fn test_rice_decode_k2_val5() {
        // k=2, val=5: q=5>>2=1, r=5&3=1
        // Unary: 1 one then a zero = bits: 1,0
        // Remainder: 2 bits of 1 = bits: 0,1
        // Total bits: 1,0,0,1 = 0x90 (1001_0000)
        let data = [0x90];
        let mut reader = BitReader::new(&data);
        assert_eq!(rice_decode(2, &mut reader), 5);
    }

    #[test]
    fn test_rice_round_trip() {
        // Test helper: rice encode (not in crate, test only)
        fn rice_encode(k: u8, val: u16) -> Vec<u8> {
            let q = val >> k;
            let r = val & ((1u16 << k) - 1);
            let mut bits = Vec::new();
            for _ in 0..q { bits.push(true); }
            bits.push(false);
            for i in (0..k).rev() { bits.push((r >> i) & 1 != 0); }
            // Pack bits MSB-first
            let mut bytes = Vec::new();
            let mut current: u8 = 0;
            let mut pos = 0u8;
            for b in bits {
                if b { current |= 1 << (7 - pos); }
                pos += 1;
                if pos == 8 { bytes.push(current); current = 0; pos = 0; }
            }
            if pos > 0 { bytes.push(current); }
            bytes
        }

        for k in 0..=8u8 {
            for val in [0u16, 1, 2, 5, 10, 63, 100, 255, 511] {
                let encoded = rice_encode(k, val);
                let mut reader = BitReader::new(&encoded);
                let decoded = rice_decode(k, &mut reader);
                assert_eq!(decoded, val, "k={k}, val={val}");
            }
        }
    }
}
