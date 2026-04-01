/// Decode one unsigned LEB128 varint from `data` starting at `*offset`.
pub fn decode_varint(data: &[u8], offset: &mut usize) -> u32 {
    let mut result: u32 = 0;
    let mut shift: u32 = 0;
    loop {
        let b = data[*offset];
        *offset += 1;
        result |= ((b & 0x7F) as u32) << shift;
        if b & 0x80 == 0 {
            return result;
        }
        shift += 7;
    }
}

/// Zigzag-decode: unsigned -> signed.
pub fn zigzag_decode(n: u32) -> i32 {
    ((n >> 1) as i32) ^ -((n & 1) as i32)
}

/// Inverse DPCM: prefix-sum per row.
pub fn dpcm_decode(v: &mut [i32], width: usize) {
    for i in 0..v.len() {
        if i % width != 0 {
            v[i] += v[i - 1];
        }
    }
}

/// Unpack `count` varint-encoded, zigzag-encoded i32 values from `data`.
pub fn unpack_subband(data: &[u8], offset: &mut usize, count: usize) -> Vec<i32> {
    let mut result = Vec::with_capacity(count);
    for _ in 0..count {
        let val = decode_varint(data, offset);
        result.push(zigzag_decode(val));
    }
    result
}

/// Unpack an LL subband: varint decode, zigzag decode, then inverse DPCM.
pub fn unpack_ll_subband(data: &[u8], offset: &mut usize, count: usize, width: usize) -> Vec<i32> {
    let mut result = unpack_subband(data, offset, count);
    dpcm_decode(&mut result, width);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_zigzag_decode_known_values() {
        assert_eq!(zigzag_decode(0), 0);
        assert_eq!(zigzag_decode(1), -1);
        assert_eq!(zigzag_decode(2), 1);
        assert_eq!(zigzag_decode(3), -2);
        assert_eq!(zigzag_decode(4), 2);
    }

    #[test]
    fn test_decode_varint_single_byte() {
        let data = [0x00];
        let mut offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 0);
        assert_eq!(offset, 1);

        let data = [0x7F];
        offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 127);
        assert_eq!(offset, 1);
    }

    #[test]
    fn test_decode_varint_multi_byte() {
        let data = [0x80, 0x01];
        let mut offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 128);
        assert_eq!(offset, 2);

        let data = [0xAC, 0x02];
        offset = 0;
        assert_eq!(decode_varint(&data, &mut offset), 300);
        assert_eq!(offset, 2);
    }

    #[test]
    fn test_dpcm_decode_constant() {
        let mut v = vec![100, 0, 0, 0];
        dpcm_decode(&mut v, 4);
        assert_eq!(v, vec![100, 100, 100, 100]);
    }

    #[test]
    fn test_dpcm_decode_row_reset() {
        let mut v = vec![10, 10, 50, 10];
        dpcm_decode(&mut v, 2);
        assert_eq!(v, vec![10, 20, 50, 60]);
    }

    #[test]
    fn test_unpack_subband() {
        // Zigzag(0)=0 → varint [0x00]; Zigzag(-1)=1 → [0x01]; Zigzag(1)=2 → [0x02]
        let data = [0x00, 0x01, 0x02];
        let mut offset = 0;
        let result = unpack_subband(&data, &mut offset, 3);
        assert_eq!(result, vec![0, -1, 1]);
        assert_eq!(offset, 3);
    }
}
