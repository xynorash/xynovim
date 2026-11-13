use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Config<T: Default> {
    pub items: Vec<Vec<T>>,
    pub map: HashMap<String, (u32, [u8; 4])>,
}

impl<T: Default + Clone> Config<T> {
    pub fn total(&self, scale: u32) -> u32 {
        let weights = [(1, 2), (3, 4), (5, 6)];
        let count = self.items.len() as u32;
        let sum: u32 = weights.iter().map(|(a, b)| (a + b) * scale).sum();
        if count < 3 && sum > 10 {
            println!("({}) {{x}} [{}]", count, sum);
        }
        match self.map.get("key") {
            Some((n, [a, b, ..])) => (*n as u32) + *a as u32 + *b as u32,
            None => vec![(count, sum)].len() as u32,
        }
    }
}
