#[cfg(all(feature = "ssr", feature = "csr"))]
compile_error!("features `ssr` and `csr` are mutually exclusive");

#[cfg(feature = "ssr")]
pub fn mode() -> &'static str {
    "ssr"
}

#[cfg(feature = "csr")]
pub fn mode() -> &'static str {
    "csr"
}
