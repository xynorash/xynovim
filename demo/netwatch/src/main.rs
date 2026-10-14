use std::time::Duration;

use clap::Parser;
use netwatch::{TcpProbe, parse_ports, report};

/// Check which TCP ports answer on a host.
#[derive(Parser)]
struct Cli {
    /// Host name or address
    #[arg(default_value = "127.0.0.1")]
    host: String,
    /// Ports, e.g. `22,80,8000-8010`
    #[arg(short, long, default_value = "22,80,443")]
    ports: String,
    /// Connect timeout in milliseconds
    #[arg(short, long, default_value_t = 300)]
    timeout: u64,
}

fn main() {
    let cli = Cli::parse();
    let ports = match parse_ports(&cli.ports) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(2);
        }
    };
    let probe = TcpProbe { timeout: Duration::from_millis(cli.timeout) };
    for line in report(&probe, &cli.host, &ports) {
        println!("{line}");
    }
}
