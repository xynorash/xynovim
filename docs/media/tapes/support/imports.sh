#!/usr/bin/env bash
# An `Error` that std, std::io, std::fmt and clap all export, and a macro_rules!
# macro with two matcher arms (13-imports.tape).
cat >> src/lib.rs <<'RS'

/// One report line: `probe_line!(host, port)` or with a note.
#[macro_export]
macro_rules! probe_line {
    ($host:expr, $port:expr) => {
        format!("{}:{}", $host, $port)
    };
    ($host:expr, $port:expr, $note:expr) => {
        format!("{}:{} ({})", $host, $port, $note)
    };
}

pub fn describe(e: &Error) -> String {
    e.to_string()
}
RS
