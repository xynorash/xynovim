# neotest with cargo-nextest (summary panel with per-test results), and
# coverage signs from cargo-llvm-cov in the gutter.
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type " ts"
Sleep 2s
Type " tt"
Sleep 15s
Screenshot "05-tests-summary.png"
Type " ts"
Sleep 1s
Type "/fn parse_ports"
Enter
Type "zt"
Type " tc"
Wait+Screen@240s /coverage loaded/
Sleep 3s
Screenshot "05-tests-coverage.png"
Sleep 500ms
