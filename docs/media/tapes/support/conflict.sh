#!/usr/bin/env bash
# Makes the demo crate's `ssr` and `csr` features mutually exclusive (07-context.tape).
cat >> src/lib.rs <<'RS'

#[cfg(all(feature = "ssr", feature = "csr"))]
compile_error!("ssr and csr are mutually exclusive");
RS
