/// Magnitude class decoding for DWT coefficients.
///
/// Encoding: coefficient v ->
///   class 0: value = 0, no bits
///   class k > 0: k bits = [sign] + [residual as (k-1) MSB-first bits]
///   sign: false = positive, true = negative
///   value = 2^(k-1) + residual, negated if sign is true

/// Decode a single coefficient from its magnitude class and sign+residual bits.
/// Returns (decoded_value, number_of_bits_consumed).
pub fn decode_coeff(class: u16, bits: &[bool]) -> (i32, usize) {
    if class == 0 {
        return (0, 0);
    }
    let k = class as usize;
    let sign = bits[0];
    let base: u32 = 1 << (k - 1);
    let mut residual: u32 = 0;
    for i in 0..(k - 1) {
        residual = (residual << 1) | (bits[1 + i] as u32);
    }
    let abs_val = base + residual;
    let val = abs_val as i32;
    if sign { (-val, k) } else { (val, k) }
}

/// Decode a batch of coefficients from class stream + raw bits.
pub fn decode_coeffs(classes: &[u16], bits: &[bool]) -> Vec<i32> {
    let mut result = Vec::with_capacity(classes.len());
    let mut bit_offset = 0;
    for &cls in classes {
        let (val, consumed) = decode_coeff(cls, &bits[bit_offset..]);
        result.push(val);
        bit_offset += consumed;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_coeff(v: i32) -> (u16, Vec<bool>) {
        if v == 0 {
            return (0, vec![]);
        }
        let abs_v = v.unsigned_abs();
        let k = 32 - abs_v.leading_zeros() as usize;
        let sign = v < 0;
        let base: u32 = 1 << (k - 1);
        let residual = abs_v - base;
        let mut bits = vec![sign];
        for i in (0..(k - 1)).rev() {
            bits.push((residual >> i) & 1 == 1);
        }
        (k as u16, bits)
    }

    #[test]
    fn test_zero() {
        let (val, consumed) = decode_coeff(0, &[]);
        assert_eq!(val, 0);
        assert_eq!(consumed, 0);
    }

    #[test]
    fn test_positive_values() {
        for v in [1, 2, 5, 42, 127, 255, 1000] {
            let (cls, bits) = encode_coeff(v);
            let (decoded, _) = decode_coeff(cls, &bits);
            assert_eq!(decoded, v, "failed for {}", v);
        }
    }

    #[test]
    fn test_negative_values() {
        for v in [-1, -2, -5, -13, -128, -256] {
            let (cls, bits) = encode_coeff(v);
            let (decoded, _) = decode_coeff(cls, &bits);
            assert_eq!(decoded, v, "failed for {}", v);
        }
    }

    #[test]
    fn test_batch_round_trip() {
        let values = vec![0, 5, -13, 1, -1, 0, 127, -128];
        let mut classes = Vec::new();
        let mut all_bits = Vec::new();
        for &v in &values {
            let (cls, bits) = encode_coeff(v);
            classes.push(cls);
            all_bits.extend(bits);
        }
        let decoded = decode_coeffs(&classes, &all_bits);
        assert_eq!(decoded, values);
    }
}
