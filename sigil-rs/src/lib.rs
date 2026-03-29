//! Sigil decoder — reads `.sgl` files and returns raw pixel data.

mod types;
mod error;
mod crc32;
mod chunk;
mod zigzag;
mod token;

pub use types::{Header, ColorSpace, BitDepth, PredictorId};
pub use error::SigilError;
