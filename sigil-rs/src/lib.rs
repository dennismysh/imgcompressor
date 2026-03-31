//! Sigil decoder — reads `.sgl` files and returns raw pixel data.
//!
//! # Example
//! ```ignore
//! let data = std::fs::read("image.sgl").unwrap();
//! let (header, pixels) = sigil_decode::decode(&data).unwrap();
//! println!("{}x{} {:?}", header.width, header.height, header.color_space);
//! ```

mod types;
mod error;
mod crc32;
mod chunk;
mod zigzag;
mod token;
mod rice;
mod predict;
mod pipeline;
mod reader;
pub mod wavelet;
pub mod color_transform;

pub use types::{Header, ColorSpace, BitDepth, PredictorId, CompressionMethod};
pub use error::SigilError;

/// Decode a `.sgl` file from bytes. Returns the header and raw pixel data.
///
/// Pixels are row-major interleaved samples: `[r,g,b, r,g,b, ...]` for RGB.
/// Use `header.row_bytes()` to compute row stride.
pub fn decode(data: &[u8]) -> Result<(Header, Vec<u8>), SigilError> {
    reader::decode(data)
}

/// Read only the header from a `.sgl` file without decoding pixels.
pub fn read_header(data: &[u8]) -> Result<Header, SigilError> {
    reader::read_header(data)
}
