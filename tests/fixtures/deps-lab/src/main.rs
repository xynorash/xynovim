use clap::Parser;
use serde::{Deserialize, Serialize};

#[derive(Debug, thiserror::Error)]
enum LabError {
    #[error("bad input: {0}")]
    Bad(String),
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Item {
    #[serde(rename = "itemId", default)]
    item_id: u32,
    name: String,
}

#[derive(Parser, Debug)]
#[command(name = "deps-lab", version)]
struct Cli {
    #[arg(short, long)]
    name: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let item = Item { item_id: 1, name: cli.name.unwrap_or_default() };
    if item.name == "bad" {
        return Err(LabError::Bad(item.name).into());
    }
    println!("{}", serde_json::to_string(&item)?);
    Ok(())
}
