use basic::{answer, Shape, Square};

#[test]
fn answer_is_42() {
    assert_eq!(answer(), 42);
}

#[test]
fn square_area() {
    assert_eq!(Square(3.0).area(), 9.0);
}
