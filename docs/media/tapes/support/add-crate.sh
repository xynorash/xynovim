#!/usr/bin/env bash
# A function that uses a crate netwatch does not depend on yet (11-add-crate.tape).
cat >> src/lib.rs <<'RS'

/// An id for one run, printed in the report header.
pub fn run_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
RS
