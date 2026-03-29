/// Decode a zigzag-encoded unsigned value back to a signed residual.
/// Mapping: 0→0, 1→-1, 2→1, 3→-2, 4→2, ...
pub fn unzigzag(n: u16) -> i16 {
    ((n >> 1) as i16) ^ (-((n & 1) as i16))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_known_values() {
        assert_eq!(unzigzag(0), 0);
        assert_eq!(unzigzag(1), -1);
        assert_eq!(unzigzag(2), 1);
        assert_eq!(unzigzag(3), -2);
        assert_eq!(unzigzag(4), 2);
    }

    #[test]
    fn test_round_trip_with_zigzag() {
        // Test helper: zigzag encode (not in the crate, just for testing)
        fn zigzag(n: i16) -> u16 {
            ((n << 1) ^ (n >> 15)) as u16
        }
        for n in -255i16..=255 {
            assert_eq!(unzigzag(zigzag(n)), n);
        }
    }
}
