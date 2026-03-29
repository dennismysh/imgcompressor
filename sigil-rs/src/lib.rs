//! Sigil decoder — reads `.sgl` files and returns raw pixel data.

mod types;
mod error;

pub use types::{Header, ColorSpace, BitDepth, PredictorId};
pub use error::SigilError;
