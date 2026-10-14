# Two-tier diagnostics: rust-analyzer answers while typing (type errors,
# unresolved names), clippy follows about half a second later (lints).
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type "/pub fn report"
Enter
Type "o"
Sleep 300ms
Type 'let n: u32 = "zero";'
Escape
Sleep 2500ms
Screenshot "02-diagnostics-type-error.png"
Type "dd"
Type "O"
Type "if ports.len() == 0 { return Vec::new(); }"
Escape
Sleep 3500ms
Screenshot "02-diagnostics-clippy.png"
Type "]d"
Sleep 800ms
Type " cd"
Sleep 1500ms
Screenshot "02-diagnostics-float.png"
Sleep 500ms
