#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSpace {
    Grayscale,
    GrayscaleAlpha,
    Rgb,
    Rgba,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BitDepth {
    Eight,
    Sixteen,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PredictorId {
    None,
    Sub,
    Up,
    Average,
    Paeth,
    Gradient,
    Adaptive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompressionMethod {
    Legacy,       // 0
    DwtLossless,  // 1
}

impl CompressionMethod {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(CompressionMethod::Legacy),
            1 => Some(CompressionMethod::DwtLossless),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub width: u32,
    pub height: u32,
    pub color_space: ColorSpace,
    pub bit_depth: BitDepth,
    pub compression_method: CompressionMethod,
}

impl Header {
    pub fn channels(&self) -> usize {
        match self.color_space {
            ColorSpace::Grayscale => 1,
            ColorSpace::GrayscaleAlpha => 2,
            ColorSpace::Rgb => 3,
            ColorSpace::Rgba => 4,
        }
    }

    pub fn bytes_per_channel(&self) -> usize {
        match self.bit_depth {
            BitDepth::Eight => 1,
            BitDepth::Sixteen => 2,
        }
    }

    pub fn row_bytes(&self) -> usize {
        self.width as usize * self.channels() * self.bytes_per_channel()
    }
}

impl ColorSpace {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(ColorSpace::Grayscale),
            1 => Some(ColorSpace::GrayscaleAlpha),
            2 => Some(ColorSpace::Rgb),
            3 => Some(ColorSpace::Rgba),
            _ => None,
        }
    }
}

impl BitDepth {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            8 => Some(BitDepth::Eight),
            16 => Some(BitDepth::Sixteen),
            _ => None,
        }
    }
}

impl PredictorId {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(PredictorId::None),
            1 => Some(PredictorId::Sub),
            2 => Some(PredictorId::Up),
            3 => Some(PredictorId::Average),
            4 => Some(PredictorId::Paeth),
            5 => Some(PredictorId::Gradient),
            6 => Some(PredictorId::Adaptive),
            _ => None,
        }
    }

    pub fn to_byte(self) -> u8 {
        match self {
            PredictorId::None => 0,
            PredictorId::Sub => 1,
            PredictorId::Up => 2,
            PredictorId::Average => 3,
            PredictorId::Paeth => 4,
            PredictorId::Gradient => 5,
            PredictorId::Adaptive => 6,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_channels() {
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::Grayscale, bit_depth: BitDepth::Eight, compression_method: CompressionMethod::Legacy }.channels(), 1);
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight, compression_method: CompressionMethod::Legacy }.channels(), 3);
        assert_eq!(Header { width: 1, height: 1, color_space: ColorSpace::Rgba, bit_depth: BitDepth::Eight, compression_method: CompressionMethod::Legacy }.channels(), 4);
    }

    #[test]
    fn test_row_bytes() {
        let hdr = Header { width: 256, height: 256, color_space: ColorSpace::Rgb, bit_depth: BitDepth::Eight, compression_method: CompressionMethod::DwtLossless };
        assert_eq!(hdr.row_bytes(), 768);
    }

    #[test]
    fn test_color_space_from_byte() {
        assert_eq!(ColorSpace::from_byte(0), Some(ColorSpace::Grayscale));
        assert_eq!(ColorSpace::from_byte(2), Some(ColorSpace::Rgb));
        assert_eq!(ColorSpace::from_byte(99), None);
    }

    #[test]
    fn test_predictor_round_trip() {
        for b in 0..=6u8 {
            let pid = PredictorId::from_byte(b).unwrap();
            assert_eq!(pid.to_byte(), b);
        }
        assert_eq!(PredictorId::from_byte(7), None);
    }

    #[test]
    fn test_bit_depth_from_byte() {
        assert_eq!(BitDepth::from_byte(8), Some(BitDepth::Eight));
        assert_eq!(BitDepth::from_byte(16), Some(BitDepth::Sixteen));
        assert_eq!(BitDepth::from_byte(0), None);
        assert_eq!(BitDepth::from_byte(32), None);
    }
}
