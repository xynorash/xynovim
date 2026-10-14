#!/usr/bin/env bash
# One uncommitted edit so the git tapes have something to show (08-git.tape).
sed -i 's|probe TCP endpoints\.|probe TCP endpoints (edited).|' src/lib.rs
