#!/usr/bin/env bash
# serde as a dependency WITHOUT its `derive` feature, a struct that derives
# Serialize anyway, and a second struct to put attributes on (12-attributes.tape).
# The registry download happens here, off camera.
sed -i 's|^clap = .*|&\nserde = "1"|' Cargo.toml
cargo fetch -q 2>/dev/null
sed -i 's|^use std::time::{Duration, Instant};|&\n\nuse serde::Serialize;|' src/lib.rs
cat >> src/lib.rs <<'RS'

/// One probe result, as sent to a dashboard.
#[derive(Debug, Serialize)]
pub struct Reading {
    pub host: String,
    pub open_ports: Vec<u16>,
}

/// A threshold that fired.
pub struct Alert {
    pub level: String,
    pub message: String,
    pub retries: u32,
}
RS
