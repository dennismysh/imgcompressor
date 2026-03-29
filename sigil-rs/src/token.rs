#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Token {
    ZeroRun(u16),
    Value(u16),
}

/// Expand a token stream back into a flat vector of values.
pub fn untokenize(tokens: &[Token]) -> Vec<u16> {
    let mut result = Vec::new();
    for token in tokens {
        match token {
            Token::ZeroRun(n) => {
                result.extend(std::iter::repeat(0u16).take(*n as usize));
            }
            Token::Value(v) => {
                result.push(*v);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_untokenize_zeros() {
        assert_eq!(untokenize(&[Token::ZeroRun(5)]), vec![0, 0, 0, 0, 0]);
    }

    #[test]
    fn test_untokenize_values() {
        assert_eq!(untokenize(&[Token::Value(3), Token::Value(7)]), vec![3, 7]);
    }

    #[test]
    fn test_untokenize_mixed() {
        assert_eq!(
            untokenize(&[Token::ZeroRun(2), Token::Value(5), Token::ZeroRun(1)]),
            vec![0, 0, 5, 0]
        );
    }

    #[test]
    fn test_untokenize_empty() {
        assert_eq!(untokenize(&[]), vec![]);
    }
}
