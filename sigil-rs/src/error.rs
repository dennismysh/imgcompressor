use core::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SigilError {
    InvalidMagic,
    UnsupportedVersion { major: u8, minor: u8 },
    CrcMismatch { expected: u32, actual: u32 },
    InvalidPredictor(u8),
    InvalidCompressionMethod(u8),
    TruncatedInput,
    InvalidDimensions(u32, u32),
    InvalidColorSpace(u8),
    InvalidBitDepth(u8),
    InvalidTag,
    MissingChunk(&'static str),
}

impl fmt::Display for SigilError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SigilError::InvalidMagic => write!(f, "invalid magic bytes"),
            SigilError::UnsupportedVersion { major, minor } => write!(f, "unsupported version {major}.{minor}"),
            SigilError::CrcMismatch { expected, actual } => write!(f, "CRC mismatch: expected {expected:#010x}, got {actual:#010x}"),
            SigilError::InvalidPredictor(n) => write!(f, "invalid predictor id: {n}"),
            SigilError::InvalidCompressionMethod(n) => write!(f, "invalid compression method: {n}"),
            SigilError::TruncatedInput => write!(f, "truncated input"),
            SigilError::InvalidDimensions(w, h) => write!(f, "invalid dimensions: {w}x{h}"),
            SigilError::InvalidColorSpace(n) => write!(f, "invalid color space: {n}"),
            SigilError::InvalidBitDepth(n) => write!(f, "invalid bit depth: {n}"),
            SigilError::InvalidTag => write!(f, "invalid chunk tag"),
            SigilError::MissingChunk(name) => write!(f, "missing required chunk: {name}"),
        }
    }
}

impl std::error::Error for SigilError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_display() {
        assert_eq!(SigilError::InvalidMagic.to_string(), "invalid magic bytes");
        assert_eq!(SigilError::CrcMismatch { expected: 0xDEADBEEF, actual: 0 }.to_string(), "CRC mismatch: expected 0xdeadbeef, got 0x00000000");
    }
}
