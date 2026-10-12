//! Fixture: a library with a trait, an impl and one clippy finding.

pub trait Shape {
    fn area(&self) -> f64;
}

pub struct Square(pub f64);

impl Shape for Square {
    fn area(&self) -> f64 {
        self.0 * self.0
    }
}

/// clippy::needless_return fires here.
pub fn answer() -> i32 {
    return 42;
}
