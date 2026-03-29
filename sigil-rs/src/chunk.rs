use crate::crc32::crc32;
use crate::error::SigilError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Shdr,
    Smta,
    Spal,
    Sdat,
    Send,
}

impl Tag {
    pub fn from_bytes(b: &[u8]) -> Result<Tag, SigilError> {
        match b {
            b"SHDR" => Ok(Tag::Shdr),
            b"SMTA" => Ok(Tag::Smta),
            b"SPAL" => Ok(Tag::Spal),
            b"SDAT" => Ok(Tag::Sdat),
            b"SEND" => Ok(Tag::Send),
            _ => Err(SigilError::InvalidTag),
        }
    }
}

#[derive(Debug)]
pub struct Chunk<'a> {
    pub tag: Tag,
    pub payload: &'a [u8],
    pub crc: u32,
}

impl<'a> Chunk<'a> {
    pub fn verify(&self) -> Result<(), SigilError> {
        let computed = crc32(self.payload);
        if computed == self.crc {
            Ok(())
        } else {
            Err(SigilError::CrcMismatch {
                expected: self.crc,
                actual: computed,
            })
        }
    }
}

fn read_u32_be(data: &[u8], offset: usize) -> Result<u32, SigilError> {
    if offset + 4 > data.len() {
        return Err(SigilError::TruncatedInput);
    }
    Ok(u32::from_be_bytes([
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
    ]))
}

/// Parse all chunks from the data starting at `offset`.
/// Returns the list of chunks. Stops after SEND.
pub fn parse_chunks(data: &[u8], mut offset: usize) -> Result<Vec<Chunk<'_>>, SigilError> {
    let mut chunks = Vec::new();
    loop {
        if offset + 4 > data.len() {
            return Err(SigilError::TruncatedInput);
        }
        let tag = Tag::from_bytes(&data[offset..offset + 4])?;
        offset += 4;

        let length = read_u32_be(data, offset)? as usize;
        offset += 4;

        if offset + length > data.len() {
            return Err(SigilError::TruncatedInput);
        }
        let payload = &data[offset..offset + length];
        offset += length;

        let crc = read_u32_be(data, offset)?;
        offset += 4;

        let chunk = Chunk { tag, payload, crc };
        chunk.verify()?;

        let is_end = tag == Tag::Send;
        chunks.push(chunk);
        if is_end {
            break;
        }
    }
    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tag_from_bytes() {
        assert_eq!(Tag::from_bytes(b"SHDR"), Ok(Tag::Shdr));
        assert_eq!(Tag::from_bytes(b"SEND"), Ok(Tag::Send));
        assert!(Tag::from_bytes(b"XXXX").is_err());
    }

    #[test]
    fn test_chunk_verify() {
        let payload = b"hello";
        let crc = crc32(payload);
        let chunk = Chunk { tag: Tag::Sdat, payload, crc };
        assert!(chunk.verify().is_ok());

        let bad_chunk = Chunk { tag: Tag::Sdat, payload, crc: 0 };
        assert!(bad_chunk.verify().is_err());
    }
}
