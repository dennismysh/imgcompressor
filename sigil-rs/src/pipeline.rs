use crate::error::SigilError;
use crate::types::{Header, PredictorId};
use crate::rice::decode_token_stream;
use crate::token::untokenize;
use crate::zigzag::unzigzag;
use crate::predict::unpredict_image;

/// Decompress an SDAT payload into raw pixel data.
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    let num_rows = header.height as usize;
    let row_len = header.row_bytes();
    let total_samples = num_rows * row_len;

    // 1. Read predictor IDs (1 byte each if adaptive, otherwise all same)
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

    // 2. Decode token stream
    let tokens = decode_token_stream(rest, total_samples);

    // 3. Untokenize → flat zigzagged values
    let zigzagged = untokenize(&tokens);

    // 4. Unzigzag → signed residuals
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

    // 6. Unpredict → raw pixels
    let pixels = unpredict_image(header, &pids, &residual_rows);

    Ok(pixels)
}
