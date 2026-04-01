use crate::error::SigilError;
use crate::types::{Header, CompressionMethod, ColorSpace};
use crate::color_transform::inverse_rct;
use crate::wavelet::dwt_inverse_multi;
use crate::serialize::{decode_varint, unpack_subband, unpack_ll_subband};
use flate2::read::ZlibDecoder;
use std::io::Read;

/// Decompress an SDAT payload into raw pixel data.
pub fn decompress(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    match header.compression_method {
        CompressionMethod::Legacy            => decompress_legacy(header, sdat_payload),
        CompressionMethod::DwtLossless       => decompress_dwt(header, sdat_payload),
        CompressionMethod::DwtLosslessVarint => decompress_dwt_varint(header, sdat_payload),
    }
}

// ---------------------------------------------------------------------------
// Legacy path (v0.4 predict + zigzag)
// ---------------------------------------------------------------------------

fn decompress_legacy(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    use crate::types::PredictorId;
    use crate::zigzag::unzigzag;
    use crate::predict::unpredict_image;

    let num_rows = header.height as usize;
    let row_len = header.row_bytes();

    // In legacy mode we treat the compression_method field as meaning "Adaptive"
    // predictor (it was the only format before v0.5), but since the header now
    // uses CompressionMethod we can't read a predictor from it.  Legacy files
    // always used Adaptive predictor in the SDAT payload, so we read per-row
    // predictor IDs from the start of the payload.
    let (pids, rest) = {
        if sdat_payload.len() < num_rows {
            return Err(SigilError::TruncatedInput);
        }
        let pids: Vec<PredictorId> = sdat_payload[..num_rows]
            .iter()
            .map(|&b| PredictorId::from_byte(b).unwrap_or(PredictorId::None))
            .collect();
        (pids, &sdat_payload[num_rows..])
    };

    // Zlib decompress
    let mut decoder = ZlibDecoder::new(rest);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)
        .map_err(|_| SigilError::TruncatedInput)?;

    // Unpack big-endian Word16 values
    let zigzagged: Vec<u16> = decompressed.chunks_exact(2)
        .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
        .collect();

    // Unzigzag
    let flat_residuals: Vec<i16> = zigzagged.iter().map(|&v| unzigzag(v)).collect();

    // Split into rows
    let mut residual_rows: Vec<Vec<i16>> = Vec::with_capacity(num_rows);
    for i in 0..num_rows {
        let start = i * row_len;
        let end = start + row_len;
        if end > flat_residuals.len() {
            return Err(SigilError::TruncatedInput);
        }
        residual_rows.push(flat_residuals[start..end].to_vec());
    }

    // Unpredict
    let pixels = unpredict_image(header, &pids, &residual_rows);
    Ok(pixels)
}

// ---------------------------------------------------------------------------
// DWT lossless path (v0.5)
// ---------------------------------------------------------------------------

fn decompress_dwt(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    if sdat_payload.len() < 3 {
        return Err(SigilError::TruncatedInput);
    }

    let num_levels    = sdat_payload[0] as usize;
    let ct_byte       = sdat_payload[1];
    let num_channels  = sdat_payload[2] as usize;
    let use_rct       = ct_byte == 1;
    let compressed    = &sdat_payload[3..];

    // Zlib decompress
    let mut decoder = ZlibDecoder::new(compressed);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)
        .map_err(|_| SigilError::TruncatedInput)?;

    let w = header.width  as usize;
    let h = header.height as usize;

    // Compute subband sizes at each level (deepest-first), matching Haskell
    // computeLevelSizes: reverse $ go numLevels w h
    //   go 0 _ _ = []
    //   go n cw ch = (wLow, hLow, wHigh, hHigh) : go (n-1) wLow hLow
    // The resulting list is shallowest-first; then reversed → deepest-first.
    let level_sizes: Vec<(usize, usize, usize, usize)> = {
        let mut raw: Vec<(usize, usize, usize, usize)> = Vec::with_capacity(num_levels);
        let mut cw = w;
        let mut ch = h;
        for _ in 0..num_levels {
            let w_low  = (cw + 1) / 2;
            let w_high = cw / 2;
            let h_low  = (ch + 1) / 2;
            let h_high = ch / 2;
            raw.push((w_low, h_low, w_high, h_high));
            cw = w_low;
            ch = h_low;
        }
        raw.reverse(); // now deepest-first
        raw
    };

    // Final LL size = deepest level's LL
    let (ll_w, ll_h) = if level_sizes.is_empty() {
        (w, h)
    } else {
        let (wl, hl, _, _) = level_sizes[0];
        (wl, hl)
    };
    let ll_count = ll_w * ll_h;

    // Deserialize all channels from the decompressed bytes
    let mut offset = 0usize;
    let mut channels_i32: Vec<Vec<i32>> = Vec::with_capacity(num_channels);

    for _ in 0..num_channels {
        // Read finalLL
        let final_ll = read_i32_slice(&decompressed, &mut offset, ll_count)?;

        // Read detail subbands: deepest-first (LH, HL, HH) for each level
        let mut levels: Vec<(Vec<i32>, Vec<i32>, Vec<i32>)> = Vec::with_capacity(num_levels);
        for &(w_low, h_low, w_high, h_high) in &level_sizes {
            let lh_count = h_low  * w_high;
            let hl_count = h_high * w_low;
            let hh_count = h_high * w_high;
            let lh = read_i32_slice(&decompressed, &mut offset, lh_count)?;
            let hl = read_i32_slice(&decompressed, &mut offset, hl_count)?;
            let hh = read_i32_slice(&decompressed, &mut offset, hh_count)?;
            levels.push((lh, hl, hh));
        }

        // Inverse multi-level DWT → reconstructed channel
        let reconstructed = dwt_inverse_multi(&final_ll, &levels, w, h, num_levels);
        channels_i32.push(reconstructed);
    }

    // Inverse color transform + interleave
    let pixels = if use_rct {
        match header.color_space {
            ColorSpace::Rgb => {
                // channels_i32: [Y, Cb, Cr]
                inverse_rct(w, h, &channels_i32[0], &channels_i32[1], &channels_i32[2])
            }
            ColorSpace::Rgba => {
                // channels_i32: [Y, Cb, Cr, Alpha]
                let rgb = inverse_rct(w, h, &channels_i32[0], &channels_i32[1], &channels_i32[2]);
                // Append alpha, interleaved: convert [R,G,B,R,G,B,...] + alpha → [R,G,B,A,...]
                let n = w * h;
                let mut rgba = Vec::with_capacity(n * 4);
                for i in 0..n {
                    rgba.push(rgb[i * 3]);
                    rgba.push(rgb[i * 3 + 1]);
                    rgba.push(rgb[i * 3 + 2]);
                    rgba.push(channels_i32[3][i].clamp(0, 255) as u8);
                }
                rgba
            }
            _ => {
                // Shouldn't happen (RCT only for RGB/RGBA), fall through to plain
                interleave_channels(&channels_i32, w, h)
            }
        }
    } else {
        interleave_channels(&channels_i32, w, h)
    };

    Ok(pixels)
}

/// Read `count` i32 values (big-endian) from `data` starting at `*offset`.
fn read_i32_slice(data: &[u8], offset: &mut usize, count: usize) -> Result<Vec<i32>, SigilError> {
    let byte_count = count * 4;
    if *offset + byte_count > data.len() {
        return Err(SigilError::TruncatedInput);
    }
    let mut result = Vec::with_capacity(count);
    for i in 0..count {
        let off = *offset + i * 4;
        let v = i32::from_be_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
        result.push(v);
    }
    *offset += byte_count;
    Ok(result)
}

// ---------------------------------------------------------------------------
// DWT lossless varint path (v0.6)
// ---------------------------------------------------------------------------

fn decompress_dwt_varint(header: &Header, sdat_payload: &[u8]) -> Result<Vec<u8>, SigilError> {
    if sdat_payload.len() < 3 {
        return Err(SigilError::TruncatedInput);
    }

    let num_levels    = sdat_payload[0] as usize;
    let ct_byte       = sdat_payload[1];
    let num_channels  = sdat_payload[2] as usize;
    let use_rct       = ct_byte == 1;
    let compressed    = &sdat_payload[3..];

    let mut decoder = ZlibDecoder::new(compressed);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)
        .map_err(|_| SigilError::TruncatedInput)?;

    let w = header.width  as usize;
    let h = header.height as usize;

    // Compute level sizes (deepest-first)
    let level_sizes: Vec<(usize, usize, usize, usize)> = {
        let mut raw: Vec<(usize, usize, usize, usize)> = Vec::with_capacity(num_levels);
        let mut cw = w;
        let mut ch = h;
        for _ in 0..num_levels {
            let w_low  = (cw + 1) / 2;
            let w_high = cw / 2;
            let h_low  = (ch + 1) / 2;
            let h_high = ch / 2;
            raw.push((w_low, h_low, w_high, h_high));
            cw = w_low;
            ch = h_low;
        }
        raw.reverse();
        raw
    };

    let mut offset = 0usize;
    let mut channels_i32: Vec<Vec<i32>> = Vec::with_capacity(num_channels);

    for _ in 0..num_channels {
        // Read explicit LL dimensions from the stream (per spec)
        let ll_w = decode_varint(&decompressed, &mut offset) as usize;
        let ll_h = decode_varint(&decompressed, &mut offset) as usize;
        let ll_count = ll_w * ll_h;

        let final_ll = unpack_ll_subband(&decompressed, &mut offset, ll_count, ll_w);

        let mut levels: Vec<(Vec<i32>, Vec<i32>, Vec<i32>)> = Vec::with_capacity(num_levels);
        for &(w_low, h_low, w_high, h_high) in &level_sizes {
            let lh_count = h_low  * w_high;
            let hl_count = h_high * w_low;
            let hh_count = h_high * w_high;
            let lh = unpack_subband(&decompressed, &mut offset, lh_count);
            let hl = unpack_subband(&decompressed, &mut offset, hl_count);
            let hh = unpack_subband(&decompressed, &mut offset, hh_count);
            levels.push((lh, hl, hh));
        }

        let reconstructed = dwt_inverse_multi(&final_ll, &levels, w, h, num_levels);
        channels_i32.push(reconstructed);
    }

    // Inverse color transform + interleave (identical to decompress_dwt)
    let pixels = if use_rct {
        match header.color_space {
            ColorSpace::Rgb => {
                inverse_rct(w, h, &channels_i32[0], &channels_i32[1], &channels_i32[2])
            }
            ColorSpace::Rgba => {
                let rgb = inverse_rct(w, h, &channels_i32[0], &channels_i32[1], &channels_i32[2]);
                let n = w * h;
                let mut rgba = Vec::with_capacity(n * 4);
                for i in 0..n {
                    rgba.push(rgb[i * 3]);
                    rgba.push(rgb[i * 3 + 1]);
                    rgba.push(rgb[i * 3 + 2]);
                    rgba.push(channels_i32[3][i].clamp(0, 255) as u8);
                }
                rgba
            }
            _ => interleave_channels(&channels_i32, w, h),
        }
    } else {
        interleave_channels(&channels_i32, w, h)
    };

    Ok(pixels)
}

/// Interleave per-channel i32 arrays into flat u8 pixels (grayscale / grayscale-alpha).
fn interleave_channels(channels: &[Vec<i32>], w: usize, h: usize) -> Vec<u8> {
    let n = w * h;
    let ch = channels.len();
    let mut out = Vec::with_capacity(n * ch);
    for i in 0..n {
        for c in 0..ch {
            out.push(channels[c][i].clamp(0, 255) as u8);
        }
    }
    out
}
