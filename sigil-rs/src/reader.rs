use crate::chunk::{parse_chunks, Tag};
use crate::error::SigilError;
use crate::pipeline::decompress;
use crate::types::{Header, ColorSpace, BitDepth, PredictorId};

const MAGIC: [u8; 6] = [0x89, 0x53, 0x47, 0x4C, 0x0D, 0x0A];

/// Parse an .sgl file and return the header + raw pixel data.
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError> {
    let header = read_header(data)?;

    // Skip magic (6) + version (2) = 8 bytes
    let chunks = parse_chunks(data, 8)?;

    // Concatenate SDAT payloads
    let mut sdat_payload = Vec::new();
    for chunk in &chunks {
        if chunk.tag == Tag::Sdat {
            sdat_payload.extend_from_slice(chunk.payload);
        }
    }

    let pixels = decompress(&header, &sdat_payload)?;
    Ok((header, pixels))
}

/// Read only the header without decoding pixel data.
pub fn read_header(data: &[u8]) -> Result<Header, SigilError> {
    // Validate magic
    if data.len() < 8 {
        return Err(SigilError::TruncatedInput);
    }
    if data[0..6] != MAGIC {
        return Err(SigilError::InvalidMagic);
    }

    // Validate version
    let major = data[6];
    let minor = data[7];
    if major != 0 || minor != 3 {
        return Err(SigilError::UnsupportedVersion { major, minor });
    }

    // Parse chunks to find SHDR
    let chunks = parse_chunks(data, 8)?;
    let shdr = chunks.iter().find(|c| c.tag == Tag::Shdr)
        .ok_or(SigilError::MissingChunk("SHDR"))?;

    parse_header(shdr.payload)
}

fn parse_header(payload: &[u8]) -> Result<Header, SigilError> {
    if payload.len() < 11 {
        return Err(SigilError::TruncatedInput);
    }

    let width = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let height = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);

    if width == 0 || height == 0 {
        return Err(SigilError::InvalidDimensions(width, height));
    }

    let color_space = ColorSpace::from_byte(payload[8])
        .ok_or(SigilError::InvalidColorSpace(payload[8]))?;

    let bit_depth = BitDepth::from_byte(payload[9])
        .ok_or(SigilError::InvalidBitDepth(payload[9]))?;

    let predictor = PredictorId::from_byte(payload[10])
        .ok_or(SigilError::InvalidPredictor(payload[10]))?;

    Ok(Header { width, height, color_space, bit_depth, predictor })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_invalid_magic() {
        let data = [0x00; 100];
        assert_eq!(decode(&data).unwrap_err(), SigilError::InvalidMagic);
    }

    #[test]
    fn test_unsupported_version() {
        let mut data = [0u8; 100];
        data[0..6].copy_from_slice(&MAGIC);
        data[6] = 1; // major = 1
        data[7] = 0; // minor = 0
        assert_eq!(decode(&data).unwrap_err(), SigilError::UnsupportedVersion { major: 1, minor: 0 });
    }

    #[test]
    fn test_truncated() {
        assert_eq!(decode(&[0x89]).unwrap_err(), SigilError::TruncatedInput);
    }
}
