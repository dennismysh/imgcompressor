use std::path::Path;

/// Load a .sgl file and decode it with the Rust decoder.
fn decode_sgl(name: &str) -> (sigil_decode::Header, Vec<u8>) {
    let sgl_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/corpus/expected")
        .join(name);
    let data = std::fs::read(&sgl_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", sgl_path.display(), e));
    sigil_decode::decode(&data)
        .unwrap_or_else(|e| panic!("Failed to decode {}: {}", name, e))
}

/// Load a source PNG and extract raw RGB pixel data using the image crate.
fn load_png_pixels(name: &str) -> Vec<u8> {
    let png_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/corpus")
        .join(name);
    let img = image::open(&png_path)
        .unwrap_or_else(|e| panic!("Failed to open {}: {}", png_path.display(), e));
    let rgb = img.to_rgb8();
    rgb.into_raw()
}

#[test]
fn conformance_gradient_256x256() {
    let (header, pixels) = decode_sgl("gradient_256x256.sgl");
    assert_eq!(header.width, 256);
    assert_eq!(header.height, 256);
    assert_eq!(header.color_space, sigil_decode::ColorSpace::Rgb);

    let expected = load_png_pixels("gradient_256x256.png");
    assert_eq!(pixels.len(), expected.len(), "pixel data length mismatch");
    assert_eq!(pixels, expected, "pixel data mismatch for gradient_256x256");
}

#[test]
fn conformance_flat_white_100x100() {
    let (header, pixels) = decode_sgl("flat_white_100x100.sgl");
    assert_eq!(header.width, 100);
    assert_eq!(header.height, 100);

    let expected = load_png_pixels("flat_white_100x100.png");
    assert_eq!(pixels, expected, "pixel data mismatch for flat_white_100x100");
}

#[test]
fn conformance_noise_128x128() {
    let (header, pixels) = decode_sgl("noise_128x128.sgl");
    assert_eq!(header.width, 128);
    assert_eq!(header.height, 128);

    let expected = load_png_pixels("noise_128x128.png");
    assert_eq!(pixels, expected, "pixel data mismatch for noise_128x128");
}

#[test]
fn conformance_checkerboard_64x64() {
    let (header, pixels) = decode_sgl("checkerboard_64x64.sgl");
    assert_eq!(header.width, 64);
    assert_eq!(header.height, 64);

    let expected = load_png_pixels("checkerboard_64x64.png");
    assert_eq!(pixels, expected, "pixel data mismatch for checkerboard_64x64");
}

#[test]
fn read_header_only() {
    let sgl_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/corpus/expected/gradient_256x256.sgl");
    let data = std::fs::read(&sgl_path).unwrap();
    let header = sigil_decode::read_header(&data).unwrap();
    assert_eq!(header.width, 256);
    assert_eq!(header.height, 256);
    assert_eq!(header.color_space, sigil_decode::ColorSpace::Rgb);
    assert_eq!(header.bit_depth, sigil_decode::BitDepth::Eight);
    assert_eq!(header.compression_method, sigil_decode::CompressionMethod::DwtLosslessVarint);
}
