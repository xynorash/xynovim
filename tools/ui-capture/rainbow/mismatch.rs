fn main() {
    let v = vec![(1, 2), (3, 4];
    println!("{}", compute(v, (5 + 6));
}

fn compute(v: Vec<(i32, i32)>, k: i32) -> i32 {
    v.iter().map(|(a, b)| (a + b) * k).sum()
}
