// No Cargo.toml next to this file: rust-analyzer treats it as a detached file.
fn main() {
    let v = vec![1, 2, 3];
    println!("{}", v.iter().sum::<i32>());
}
