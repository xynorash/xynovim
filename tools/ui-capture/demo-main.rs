use std::collections::HashMap;

struct Holder(String);

impl Holder {
    fn pick(&self, _other: &str) -> &str {
        &self.0
    }
}

fn add(a: i32, b: i32) -> i32 {
    a + b
}

fn main() {
    let n = add(1, 2);
    let mut table = HashMap::new();
    table.insert("one", n);
    let s: String = n;
    let unused = 5;
    println!("{} {}", Holder(String::new()).pick("x"), s);
}
