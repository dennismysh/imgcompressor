use crate::error::SigilError;
use crate::types::{Header, PredictorId};
use crate::zigzag::unzigzag;
use crate::predict::unpredict_image;
use flate2::read::ZlibDecoder;
use std::io::Read;

/// Decompress an SDAT payload into raw pixel data.
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    let num_rows = header.height as usize;
    let row_len = header.row_bytes();
    let _total_samples = num_rows * row_len;

    // 1. Read predictor IDs
    let (pids, rest) = if header.predictor == PredictorId::Adaptive {
        if sdat_payload.len() < num_rows {
            return Err(SigilError::TruncatedInput);
        }
        let pids: Vec<PredictorId> = sdat_payload[..num_rows]
            .iter()
            .map(|&b| PredictorId::from_byte(b).unwrap_or(PredictorId::None))
            .collect();
        (pids, &sdat_payload[num_rows..])
    } else {
        (vec![header.predictor; num_rows], sdat_payload)
    };

    // 2. Zlib decompress
    let mut decoder = ZlibDecoder::new(rest);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)
        .map_err(|_| SigilError::TruncatedInput)?;

    // 3. Unpack big-endian Word16 values
    let zigzagged: Vec<u16> = decompressed.chunks_exact(2)
        .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
        .collect();

    // 4. Unzigzag
    let flat_residuals: Vec<i16> = zigzagged.iter().map(|&v| unzigzag(v)).collect();

    // 5. Split into rows
    let mut residual_rows: Vec<Vec<i16>> = Vec::with_capacity(num_rows);
    for i in 0..num_rows {
        let start = i * row_len;
        let end = start + row_len;
        if end > flat_residuals.len() {
            return Err(SigilError::TruncatedInput);
        }
        residual_rows.push(flat_residuals[start..end].to_vec());
    }

    // 6. Unpredict
    let pixels = unpredict_image(header, &pids, &residual_rows);
    Ok(pixels)
}
