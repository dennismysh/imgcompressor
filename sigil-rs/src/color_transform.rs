/// Inverse Reversible Color Transform (RCT).
///
/// Converts (Y, Cb, Cr) channel arrays back to interleaved RGB bytes.
/// Matches the Haskell `inverseRCT` in ColorTransform.hs:
///   g = Y  - (Cb + Cr) `div` 4
///   r = Cr + g
///   b = Cb + g
pub fn inverse_rct(width: usize, height: usize, y: &[i32], cb: &[i32], cr: &[i32]) -> Vec<u8> {
    let n = width * height;
    let mut pixels = Vec::with_capacity(n * 3);
    for i in 0..n {
        let g = y[i] - (cb[i] + cr[i]).div_euclid(4);
        let r = cr[i] + g;
        let b = cb[i] + g;
        pixels.push(r.clamp(0, 255) as u8);
        pixels.push(g.clamp(0, 255) as u8);
        pixels.push(b.clamp(0, 255) as u8);
    }
    pixels
}

/// Clamp an i32 to [0, 255] and cast to u8.
pub fn clamp_u8(v: i32) -> u8 {
    v.clamp(0, 255) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inverse_rct_white() {
        // White pixel: R=255, G=255, B=255
        // Forward RCT: Y = (255+2*255+255)/4 = 255, Cb = 255-255 = 0, Cr = 255-255 = 0
        let y  = vec![255i32];
        let cb = vec![0i32];
        let cr = vec![0i32];
        let pixels = inverse_rct(1, 1, &y, &cb, &cr);
        assert_eq!(pixels, vec![255, 255, 255]);
    }

    #[test]
    fn test_inverse_rct_red() {
        // Red pixel: R=255, G=0, B=0
        // Forward RCT: Y = (255+0+0)/4 = 63, Cb = 0-0 = 0, Cr = 255-0 = 255
        // Inverse: g = 63 - (0+255)/4 = 63 - 63 = 0, r = 255+0 = 255, b = 0+0 = 0
        let y  = vec![63i32];
        let cb = vec![0i32];
        let cr = vec![255i32];
        let pixels = inverse_rct(1, 1, &y, &cb, &cr);
        assert_eq!(pixels, vec![255, 0, 0]);
    }

    #[test]
    fn test_inverse_rct_clamp() {
        // Values that would overflow — should be clamped to [0, 255]
        let y  = vec![300i32];
        let cb = vec![0i32];
        let cr = vec![0i32];
        let pixels = inverse_rct(1, 1, &y, &cb, &cr);
        assert_eq!(pixels, vec![255, 255, 255]);
    }
}
