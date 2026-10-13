use std::fmt;

pub trait Shape {
    fn area(&self) -> f64;
}

pub struct Square(pub f64);

impl Shape for Square {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

pub struct Wrapper(pub i32);

impl fmt::Display for Wrapper {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<i32> for Wrapper {
    fn from(v: i32) -> Self {
        Wrapper(v)
    }
}

impl Wrapper {
    pub fn plain(&self) -> i32 {
        self.0
    }
}

pub fn used(a: i32) -> i32 {
    a * 2
}

/// Documentation with a misspeled word.
fn main() {
    let total = 1 + 2 + 3; // comment bdword
    let name_wrdx = "strng literal";
    println!("{} {}", used(total), Square(2.0).area());
    let _ = (name_wrdx, Wrapper::from(1).plain());
}

#[cfg(test)]
mod tests {
    use super::used;

    #[test]
    fn doubles() {
        assert_eq!(used(1), 2);
    }
}
