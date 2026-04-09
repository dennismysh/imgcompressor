use crate::ans::ans_decode;
use crate::mag_class::decode_coeffs;
use crate::serialize::decode_varint;

/// Decode one sub-band from its encoded blob.
///
/// Format: [varint: rawBitCount] [ANS blob] [packed raw bits]
///
/// The ANS blob is self-delimiting (contains total_samples, freq table, state, bitCount).
pub fn decode_subband(data: &[u8], count: usize) -> Vec<i32> {
    if count == 0 {
        return Vec::new();
    }

    let mut offset = 0;

    // Read rawBitCount
    let raw_bit_count = decode_varint(data, &mut offset) as usize;

    // ANS decode: parse the self-delimiting ANS blob starting at offset
    let ans_data = &data[offset..];
    let classes = ans_decode(ans_data, count);

    // Compute ANS blob size to find raw bits
    let ans_blob_size = compute_ans_blob_size(ans_data);
    let raw_bytes = &data[offset + ans_blob_size..];

    // Unpack raw bits
    let raw_bits = unpack_bits(raw_bit_count, raw_bytes);

    // Reconstruct coefficients
    decode_coeffs(&classes, &raw_bits)
}

/// Compute byte size of an ANS blob by parsing its header.
/// Format: [u32 total_samples] [u16 num_unique] [N*6 freq] [u32 state] [u32 bitCount] [bits]
fn compute_ans_blob_size(data: &[u8]) -> usize {
    let num_unique = u16::from_be_bytes([data[4], data[5]]) as usize;
    let freq_end = 6 + num_unique * 6;
    // state is at freq_end (4 bytes), bitCount is at freq_end + 4 (4 bytes)
    let bit_count = u32::from_be_bytes([
        data[freq_end + 4],
        data[freq_end + 5],
        data[freq_end + 6],
        data[freq_end + 7],
    ]) as usize;
    let bitstream_bytes = (bit_count + 7) / 8;
    freq_end + 8 + bitstream_bytes
}

/// Unpack N bits from packed bytes (MSB-first).
fn unpack_bits(n: usize, data: &[u8]) -> Vec<bool> {
    let mut bits = Vec::with_capacity(n);
    for byte in data {
        for i in 0..8u8 {
            if bits.len() >= n {
                return bits;
            }
            bits.push((byte >> (7 - i)) & 1 == 1);
        }
    }
    bits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unpack_bits() {
        let data = [0b10110010u8];
        let bits = unpack_bits(8, &data);
        assert_eq!(
            bits,
            vec![true, false, true, true, false, false, true, false]
        );
    }

    #[test]
    fn test_unpack_bits_partial() {
        let data = [0b10110010u8];
        let bits = unpack_bits(3, &data);
        assert_eq!(bits, vec![true, false, true]);
    }
}
