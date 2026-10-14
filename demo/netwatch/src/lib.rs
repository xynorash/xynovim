//! netwatch: parse port lists and probe TCP endpoints.

use std::fmt;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

/// Why a probe failed.
#[derive(Debug, PartialEq, Eq)]
pub enum ProbeError {
    Resolve(String),
    Refused,
    TimedOut,
}

impl fmt::Display for ProbeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProbeError::Resolve(host) => write!(f, "cannot resolve {host}"),
            ProbeError::Refused => write!(f, "connection refused"),
            ProbeError::TimedOut => write!(f, "timed out"),
        }
    }
}

/// Something that can check whether `host:port` answers.
pub trait Probe {
    fn name(&self) -> &str;
    fn check(&self, host: &str, port: u16) -> Result<Duration, ProbeError>;
}

/// Plain TCP connect probe.
pub struct TcpProbe {
    pub timeout: Duration,
}

impl Probe for TcpProbe {
    fn name(&self) -> &str {
        "tcp"
    }

    fn check(&self, host: &str, port: u16) -> Result<Duration, ProbeError> {
        let addr = (host, port)
            .to_socket_addrs()
            .map_err(|_| ProbeError::Resolve(host.to_string()))?
            .next()
            .ok_or_else(|| ProbeError::Resolve(host.to_string()))?;
        let start = Instant::now();
        match TcpStream::connect_timeout(&addr, self.timeout) {
            Ok(_) => Ok(start.elapsed()),
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => Err(ProbeError::TimedOut),
            Err(_) => Err(ProbeError::Refused),
        }
    }
}

/// Parses `22,80,8000-8003` into a sorted, de-duplicated list of ports.
pub fn parse_ports(spec: &str) -> Result<Vec<u16>, String> {
    let mut ports = Vec::new();
    for part in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        match part.split_once('-') {
            Some((lo, hi)) => {
                let lo: u16 = lo.parse().map_err(|_| format!("bad port `{lo}`"))?;
                let hi: u16 = hi.parse().map_err(|_| format!("bad port `{hi}`"))?;
                if lo > hi {
                    return Err(format!("empty range {lo}-{hi}"));
                }
                ports.extend(lo..=hi);
            }
            None => ports.push(part.parse().map_err(|_| format!("bad port `{part}`"))?),
        }
    }
    ports.sort_unstable();
    ports.dedup();
    Ok(ports)
}

/// One line per probed port.
pub fn report(probe: &dyn Probe, host: &str, ports: &[u16]) -> Vec<String> {
    ports
        .iter()
        .map(|&port| match probe.check(host, port) {
            Ok(rtt) => format!("{host}:{port} open ({} ms)", rtt.as_millis()),
            Err(e) => format!("{host}:{port} closed ({e})"),
        })
        .collect()
}

#[cfg(feature = "json")]
pub fn report_json(lines: &[String]) -> String {
    let items: Vec<String> = lines.iter().map(|l| format!("{l:?}")).collect();
    format!("[{}]", items.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Always(Result<Duration, ProbeError>);

    impl Probe for Always {
        fn name(&self) -> &str {
            "always"
        }
        fn check(&self, _: &str, _: u16) -> Result<Duration, ProbeError> {
            match &self.0 {
                Ok(d) => Ok(*d),
                Err(ProbeError::Refused) => Err(ProbeError::Refused),
                Err(ProbeError::TimedOut) => Err(ProbeError::TimedOut),
                Err(ProbeError::Resolve(h)) => Err(ProbeError::Resolve(h.clone())),
            }
        }
    }

    #[test]
    fn parses_lists_and_ranges() {
        assert_eq!(parse_ports("80, 22,8000-8002,22").unwrap(), vec![22, 80, 8000, 8001, 8002]);
    }

    #[test]
    fn rejects_bad_input() {
        assert!(parse_ports("http").is_err());
        assert!(parse_ports("9-1").is_err());
    }

    #[test]
    fn reports_open_and_closed() {
        let open = report(&Always(Ok(Duration::from_millis(3))), "h", &[1]);
        assert_eq!(open, vec!["h:1 open (3 ms)"]);
        let closed = report(&Always(Err(ProbeError::Refused)), "h", &[2]);
        assert_eq!(closed, vec!["h:2 closed (connection refused)"]);
    }
}
