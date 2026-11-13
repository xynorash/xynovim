/// Doubles a port.
///
/// ```
/// assert_eq!(failing_tests::double(2), 4);
/// ```
///
/// ```
/// assert_eq!(failing_tests::double(2), 5);
/// ```
pub fn double(p: u16) -> u16 {
    p * 2
}

pub fn ports() -> Vec<u16> {
    vec![1, 2, 3]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles() {
        assert_eq!(double(2), 4);
    }

    #[test]
    fn vec_mismatch() {
        println!("probing before the check");
        assert_eq!(ports(), vec![1, 2, 4], "ports differ");
    }

    #[test]
    fn string_mismatch() {
        assert_eq!(format!("{}", "refused"), "reset");
    }

    #[test]
    fn plain_panic() {
        let v: Vec<u8> = Vec::new();
        let _ = v[3];
    }
}
