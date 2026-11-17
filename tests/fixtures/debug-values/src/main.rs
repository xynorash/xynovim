use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

#[derive(Debug)]
#[allow(dead_code)]
enum Shape {
    Unit,
    Circle(f64),
    Rect { w: u32, h: u32 },
}

fn work() {
    let owned = String::from("hello");
    let borrowed: &str = "world";
    let v = vec![1, 2, 3];
    let mut m = HashMap::new();
    m.insert("a".to_string(), 1);
    let some: Option<i32> = Some(5);
    let none: Option<String> = None;
    let ok: Result<i32, String> = Ok(1);
    let err: Result<i32, String> = Err("bad".into());
    let rc = Rc::new(String::from("rc"));
    let rc2 = Rc::clone(&rc);
    let arc = Arc::new(vec![1u8, 2]);
    let cell = RefCell::new(5);
    let shape = Shape::Rect { w: 2, h: 3 };
    let unit = Shape::Unit;
    let slice: &[i32] = &v[1..];
    let long = "x".repeat(600);
    std::hint::black_box((&owned, &borrowed, &m, &some, &none, &ok, &err, &rc2, &arc, &cell, &shape, &unit, slice, &long)); // STOP
}

fn count() -> u32 {
    let mut total = 0;
    for i in 0..5 {
        total += i; // LOOP
    }
    total
}

pub fn add(a: i32, b: i32) -> i32 {
    let sum = a + b; // IN_TEST
    sum
}

fn main() {
    work();
    println!("count {}", count());
    if std::env::var("DV_PANIC").is_ok() {
        panic!("requested");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds() {
        assert_eq!(add(2, 3), 5);
    }
}
