use wasm_bindgen::prelude::*;

/// Decode a `.sgl` file and return an object with header info and pixel data.
///
/// Returns a JS object: `{ width, height, colorSpace, bitDepth, predictor, pixels: Uint8Array }`
#[wasm_bindgen(js_name = "decode")]
pub fn decode(data: &[u8]) -> Result<JsValue, JsValue> {
    let (header, pixels) = sigil_decode::decode(data)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    let obj = js_sys::Object::new();
    set(&obj, "width", &JsValue::from(header.width));
    set(&obj, "height", &JsValue::from(header.height));
    set(&obj, "colorSpace", &JsValue::from(color_space_str(header.color_space)));
    set(&obj, "bitDepth", &JsValue::from(bit_depth_num(header.bit_depth)));
    set(&obj, "predictor", &JsValue::from(predictor_str(header.predictor)));
    set(&obj, "pixels", &js_sys::Uint8Array::from(pixels.as_slice()));

    Ok(obj.into())
}

/// Read only the header from a `.sgl` file without decoding pixels.
///
/// Returns: `{ width, height, colorSpace, bitDepth, predictor }`
#[wasm_bindgen(js_name = "readHeader")]
pub fn read_header(data: &[u8]) -> Result<JsValue, JsValue> {
    let header = sigil_decode::read_header(data)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;

    let obj = js_sys::Object::new();
    set(&obj, "width", &JsValue::from(header.width));
    set(&obj, "height", &JsValue::from(header.height));
    set(&obj, "colorSpace", &JsValue::from(color_space_str(header.color_space)));
    set(&obj, "bitDepth", &JsValue::from(bit_depth_num(header.bit_depth)));
    set(&obj, "predictor", &JsValue::from(predictor_str(header.predictor)));

    Ok(obj.into())
}

fn set(obj: &js_sys::Object, key: &str, val: &JsValue) {
    js_sys::Reflect::set(obj, &JsValue::from_str(key), val).unwrap();
}

fn color_space_str(cs: sigil_decode::ColorSpace) -> &'static str {
    match cs {
        sigil_decode::ColorSpace::Grayscale => "grayscale",
        sigil_decode::ColorSpace::GrayscaleAlpha => "grayscale-alpha",
        sigil_decode::ColorSpace::Rgb => "rgb",
        sigil_decode::ColorSpace::Rgba => "rgba",
    }
}

fn bit_depth_num(bd: sigil_decode::BitDepth) -> u8 {
    match bd {
        sigil_decode::BitDepth::Eight => 8,
        sigil_decode::BitDepth::Sixteen => 16,
    }
}

fn predictor_str(p: sigil_decode::PredictorId) -> &'static str {
    match p {
        sigil_decode::PredictorId::None => "none",
        sigil_decode::PredictorId::Sub => "sub",
        sigil_decode::PredictorId::Up => "up",
        sigil_decode::PredictorId::Average => "average",
        sigil_decode::PredictorId::Paeth => "paeth",
        sigil_decode::PredictorId::Gradient => "gradient",
        sigil_decode::PredictorId::Adaptive => "adaptive",
    }
}
