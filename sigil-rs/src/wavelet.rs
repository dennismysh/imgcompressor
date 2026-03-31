/// 1D inverse 5/3 lifting scheme (Le Gall).
/// `approx` = low-pass (even-indexed) coefficients
/// `detail` = high-pass (odd-indexed) coefficients
/// Returns the reconstructed signal of length approx.len() + detail.len().
pub fn lift53_inverse_1d(approx: &[i32], detail: &[i32]) -> Vec<i32> {
    let n_approx = approx.len();
    let n_detail = detail.len();

    // Degenerate cases
    if n_approx == 0 {
        return Vec::new();
    }
    if n_detail == 0 {
        // Single sample: just the approximation
        return approx.to_vec();
    }

    let n = n_approx + n_detail;
    let mut evens = vec![0i32; n_approx];

    // Step 1: undo update — recover even samples
    for i in 0..n_approx {
        let d_left  = if i > 0      { detail[i - 1] } else { detail[0] };
        let d_right = if i < n_detail { detail[i]   } else { detail[n_detail - 1] };
        evens[i] = approx[i] - (d_left + d_right + 2).div_euclid(4);
    }

    // Step 2: undo predict — recover odd samples and interleave
    let mut result = vec![0i32; n];
    for idx in 0..n {
        if idx % 2 == 0 {
            result[idx] = evens[idx / 2];
        } else {
            let i     = idx / 2;
            let left  = evens[i];
            let right = if 2 * i + 2 < n { evens[i + 1] } else { evens[i] };
            result[idx] = detail[i] + (left + right).div_euclid(2);
        }
    }

    result
}

/// 2D inverse DWT (one level).
/// Takes the four subbands (LL, LH, HL, HH) and reconstructs the full image
/// of size `full_w` × `full_h`.
///
/// Subband layout follows the Haskell Wavelet.hs convention:
///   wLow  = (full_w + 1) / 2,  wHigh = full_w / 2
///   hLow  = (full_h + 1) / 2,  hHigh = full_h / 2
///   ll  : hLow  × wLow   (row-major)
///   lh  : hLow  × wHigh
///   hl  : hHigh × wLow
///   hh  : hHigh × wHigh
pub fn dwt2d_inverse(
    ll: &[i32],
    lh: &[i32],
    hl: &[i32],
    hh: &[i32],
    full_w: usize,
    full_h: usize,
) -> Vec<i32> {
    let w_low  = (full_w + 1) / 2;
    let w_high = full_w / 2;
    let h_low  = (full_h + 1) / 2;
    let h_high = full_h / 2;

    // Step 1: inverse column transform — reconstruct each column.
    // For x < w_low:  col_lo comes from ll, col_hi from hl
    // For x >= w_low: col_lo comes from lh, col_hi from hh
    let mut col_reconstructed: Vec<Vec<i32>> = Vec::with_capacity(full_w);
    for x in 0..full_w {
        let (col_lo, col_hi): (Vec<i32>, Vec<i32>) = if x < w_low {
            let lo: Vec<i32> = (0..h_low ).map(|y| ll[y * w_low  + x    ]).collect();
            let hi: Vec<i32> = (0..h_high).map(|y| hl[y * w_low  + x    ]).collect();
            (lo, hi)
        } else {
            let x2 = x - w_low;
            let lo: Vec<i32> = (0..h_low ).map(|y| lh[y * w_high + x2]).collect();
            let hi: Vec<i32> = (0..h_high).map(|y| hh[y * w_high + x2]).collect();
            (lo, hi)
        };
        col_reconstructed.push(lift53_inverse_1d(&col_lo, &col_hi));
    }

    // Rearrange column-major result into row-major intermediate buffer.
    // row_transformed[y * full_w + x] = col_reconstructed[x][y]
    let mut row_transformed = vec![0i32; full_h * full_w];
    for x in 0..full_w {
        for y in 0..full_h {
            row_transformed[y * full_w + x] = col_reconstructed[x][y];
        }
    }

    // Step 2: inverse row transform — reconstruct each row.
    let mut result = vec![0i32; full_h * full_w];
    for y in 0..full_h {
        let row_lo: Vec<i32> = (0..w_low ).map(|i| row_transformed[y * full_w + i        ]).collect();
        let row_hi: Vec<i32> = (0..w_high).map(|i| row_transformed[y * full_w + w_low + i]).collect();
        let row = lift53_inverse_1d(&row_lo, &row_hi);
        for x in 0..full_w {
            result[y * full_w + x] = row[x];
        }
    }

    result
}

/// Multi-level inverse DWT.
///
/// `final_ll`   — the deepest LL subband (flat, row-major)
/// `levels`     — detail subbands ordered deepest-first: each entry is (LH, HL, HH)
/// `width`      — original image width
/// `height`     — original image height
/// `num_levels` — number of decomposition levels (must equal levels.len())
pub fn dwt_inverse_multi(
    final_ll: &[i32],
    levels: &[(Vec<i32>, Vec<i32>, Vec<i32>)],
    width: usize,
    height: usize,
    num_levels: usize,
) -> Vec<i32> {
    if num_levels == 0 || levels.is_empty() {
        return final_ll.to_vec();
    }

    // Build the reconstruction sizes from deepest to shallowest.
    // The Haskell code does:
    //   sizes = reverse $ take levels $ iterate shrink (w, h)
    //   shrink (cw, ch) = ((cw+1)/2, (ch+1)/2)
    // So sizes[0] is the size of level `num_levels` (deepest),
    // and sizes[num_levels-1] is the size of level 1 (shallowest = original).
    let sizes: Vec<(usize, usize)> = {
        let mut s = Vec::with_capacity(num_levels);
        let mut cw = width;
        let mut ch = height;
        for _ in 0..num_levels {
            s.push((cw, ch));
            cw = (cw + 1) / 2;
            ch = (ch + 1) / 2;
        }
        s.reverse();
        s
    };
    // sizes[0] = size for deepest level reconstruction, sizes[n-1] = original size

    let mut current_ll = final_ll.to_vec();

    for (i, (lh, hl, hh)) in levels.iter().enumerate() {
        let (cw, ch) = sizes[i];
        current_ll = dwt2d_inverse(&current_ll, lh, hl, hh, cw, ch);
    }

    current_ll
}

/// Compute the number of DWT decomposition levels for image dimensions.
/// Matches Haskell: max 1 (min 5 (floor(log2(min(w,h))) - 3))
pub fn compute_levels(w: usize, h: usize) -> usize {
    let min_dim = w.min(h);
    if min_dim == 0 {
        return 1;
    }
    let floor_log2 = usize::BITS as usize - min_dim.leading_zeros() as usize - 1;
    let levels = floor_log2.saturating_sub(3);
    levels.max(1).min(5)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inverse_1d_length_4() {
        // Simple round-trip: manually compute forward then inverse
        // Forward 5/3 on [10, 20, 30, 40]:
        //   n=4, nDetail=2, nApprox=2
        //   detail[0] = x[1] - (x[0]+x[2])/2 = 20 - (10+30)/2 = 20-20 = 0
        //   detail[1] = x[3] - (x[2]+x[2])/2 = 40 - (30+30)/2 = 40-30 = 10  (mirror)
        //   approx[0] = x[0] + (detail[0]+detail[0]+2)/4 = 10 + (0+0+2)/4 = 10+0 = 10
        //   approx[1] = x[2] + (detail[0]+detail[1]+2)/4 = 30 + (0+10+2)/4 = 30+3 = 33
        //                                                                  ^^ Haskell: div 4 = 3
        let approx = vec![10i32, 33];
        let detail = vec![0i32, 10];
        let result = lift53_inverse_1d(&approx, &detail);
        assert_eq!(result, vec![10, 20, 30, 40]);
    }

    #[test]
    fn test_inverse_1d_single() {
        let approx = vec![42i32];
        let detail: Vec<i32> = vec![];
        let result = lift53_inverse_1d(&approx, &detail);
        assert_eq!(result, vec![42]);
    }

    #[test]
    fn test_compute_levels() {
        // min_dim=8: log2=3, levels = 3-3=0 -> max(1,0)=1
        assert_eq!(compute_levels(8, 8), 1);
        // min_dim=16: log2=4, levels = 4-3=1
        assert_eq!(compute_levels(16, 16), 1);
        // min_dim=32: log2=5, levels = 5-3=2
        assert_eq!(compute_levels(32, 32), 2);
        // min_dim=64: log2=6, levels = 6-3=3
        assert_eq!(compute_levels(64, 64), 3);
        // min_dim=128: log2=7, levels = 7-3=4
        assert_eq!(compute_levels(128, 128), 4);
        // min_dim=256: log2=8, levels = 8-3=5
        assert_eq!(compute_levels(256, 256), 5);
        // min_dim=512: log2=9, levels = 9-3=6 -> min(5,6)=5
        assert_eq!(compute_levels(512, 512), 5);
    }
}
