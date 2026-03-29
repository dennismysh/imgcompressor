use crate::types::{Header, PredictorId};

/// Predict a single sample given left (a), above (b), and above-left (c) neighbors.
pub fn predict(pid: PredictorId, a: u8, b: u8, c: u8) -> u8 {
    match pid {
        PredictorId::None => 0,
        PredictorId::Sub => a,
        PredictorId::Up => b,
        PredictorId::Average => {
            ((a as u16 + b as u16) / 2) as u8
        }
        PredictorId::Paeth => paeth(a, b, c),
        PredictorId::Gradient => {
            let v = a as i16 + b as i16 - c as i16;
            v.clamp(0, 255) as u8
        }
        PredictorId::Adaptive => panic!("adaptive is resolved per-row, not per-sample"),
    }
}

fn paeth(a: u8, b: u8, c: u8) -> u8 {
    let p = a as i32 + b as i32 - c as i32;
    let pa = (p - a as i32).abs();
    let pb = (p - b as i32).abs();
    let pc = (p - c as i32).abs();
    if pa <= pb && pa <= pc {
        a
    } else if pb <= pc {
        b
    } else {
        c
    }
}

/// Reconstruct a single row of pixels from signed residuals.
/// Builds left-to-right since each pixel depends on its left neighbor.
pub fn unpredict_row(pid: PredictorId, prev_row: &[u8], residuals: &[i16], ch: usize) -> Vec<u8> {
    let len = residuals.len();
    let mut out = vec![0u8; len];

    for i in 0..len {
        let a = if i >= ch { out[i - ch] } else { 0 };
        let b = prev_row[i];
        let c = if i >= ch { prev_row[i - ch] } else { 0 };
        let predicted = predict(pid, a, b, c);
        out[i] = (predicted as i16).wrapping_add(residuals[i]) as u8;
    }

    out
}

/// Reconstruct all rows of an image from predictor IDs and residuals.
/// Returns a flat Vec<u8> of row-major interleaved pixel data.
pub fn unpredict_image(
    header: &Header,
    pids: &[PredictorId],
    residuals: &[Vec<i16>],
) -> Vec<u8> {
    let row_len = header.row_bytes();
    let ch = header.channels();
    let num_rows = header.height as usize;
    let zero_row = vec![0u8; row_len];

    let mut pixels = Vec::with_capacity(num_rows * row_len);
    let mut prev_row: &[u8] = &zero_row;
    // We need to keep all rows around since we reference prev_row
    let mut rows: Vec<Vec<u8>> = Vec::with_capacity(num_rows);

    for i in 0..num_rows {
        let row = unpredict_row(pids[i], prev_row, &residuals[i], ch);
        pixels.extend_from_slice(&row);
        rows.push(row);
        prev_row = &rows[i];
    }

    pixels
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::*;

    #[test]
    fn test_predict_none() {
        assert_eq!(predict(PredictorId::None, 100, 200, 50), 0);
    }

    #[test]
    fn test_predict_sub() {
        assert_eq!(predict(PredictorId::Sub, 100, 200, 50), 100);
    }

    #[test]
    fn test_predict_up() {
        assert_eq!(predict(PredictorId::Up, 100, 200, 50), 200);
    }

    #[test]
    fn test_predict_average() {
        assert_eq!(predict(PredictorId::Average, 100, 200, 50), 150);
        assert_eq!(predict(PredictorId::Average, 101, 200, 50), 150); // integer div
    }

    #[test]
    fn test_predict_paeth() {
        // p = 100 + 200 - 50 = 250
        // pa = |250 - 100| = 150
        // pb = |250 - 200| = 50
        // pc = |250 - 50| = 200
        // pb is smallest → return b = 200
        assert_eq!(predict(PredictorId::Paeth, 100, 200, 50), 200);
    }

    #[test]
    fn test_predict_gradient() {
        assert_eq!(predict(PredictorId::Gradient, 100, 200, 50), 250);
        // Clamp test: a + b - c > 255
        assert_eq!(predict(PredictorId::Gradient, 200, 200, 100), 255);
        // Clamp test: a + b - c < 0
        assert_eq!(predict(PredictorId::Gradient, 10, 10, 100), 0);
    }

    #[test]
    fn test_unpredict_row_round_trip() {
        // Test helper: predict a row (encode direction)
        fn predict_row(pid: PredictorId, prev: &[u8], cur: &[u8], ch: usize) -> Vec<i16> {
            cur.iter().enumerate().map(|(i, &x)| {
                let a = if i >= ch { cur[i - ch] } else { 0 };
                let b = prev[i];
                let c = if i >= ch { prev[i - ch] } else { 0 };
                x as i16 - predict(pid, a, b, c) as i16
            }).collect()
        }

        let prev = vec![10, 20, 30, 40, 50, 60];
        let cur = vec![15, 25, 35, 45, 55, 65];
        let ch = 3;

        for pid in [PredictorId::None, PredictorId::Sub, PredictorId::Up,
                    PredictorId::Average, PredictorId::Paeth, PredictorId::Gradient] {
            let residuals = predict_row(pid, &prev, &cur, ch);
            let recovered = unpredict_row(pid, &prev, &residuals, ch);
            assert_eq!(recovered, cur, "failed for {:?}", pid);
        }
    }

    #[test]
    fn test_unpredict_image() {
        fn predict_row(pid: PredictorId, prev: &[u8], cur: &[u8], ch: usize) -> Vec<i16> {
            cur.iter().enumerate().map(|(i, &x)| {
                let a = if i >= ch { cur[i - ch] } else { 0 };
                let b = prev[i];
                let c = if i >= ch { prev[i - ch] } else { 0 };
                x as i16 - predict(pid, a, b, c) as i16
            }).collect()
        }

        let header = Header { width: 2, height: 2, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight, predictor: PredictorId::Sub };
        let pixels = vec![10, 20, 30, 40, 50, 60,  // row 0
                          70, 80, 90, 100, 110, 120]; // row 1
        let ch = 3;
        let row0 = &pixels[0..6];
        let row1 = &pixels[6..12];
        let zero = vec![0u8; 6];

        let res0 = predict_row(PredictorId::Sub, &zero, row0, ch);
        let res1 = predict_row(PredictorId::Sub, row0, row1, ch);

        let pids = vec![PredictorId::Sub, PredictorId::Sub];
        let residuals = vec![res0, res1];
        let recovered = unpredict_image(&header, &pids, &residuals);
        assert_eq!(recovered, pixels);
    }
}
