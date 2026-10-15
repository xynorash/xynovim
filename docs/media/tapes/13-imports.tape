# An ambiguous `Error` (std, std::io, std::fmt, clap): the ranked picker with
# its reasons, the choice remembered for the next file; the macro expansion
# lens on a derive; signature help on a macro_rules! call.
Set Framerate 6
Hide
Type "bash ../support/imports.sh"
Enter
Type "clear"
Enter
Show
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 3s
Type "145G"
Type "fE"
Sleep 2s
Screenshot "13-imports-unresolved.png"
Sleep 500ms
Type " rI"
Sleep 3s
Screenshot "13-imports-picker.png"
Sleep 500ms
Down 4
Sleep 1s
Screenshot "13-imports-choice.png"
Sleep 500ms
Enter
Sleep 4s
Type ":w"
Enter
Sleep 1s
Type ":e src/main.rs"
Enter
Sleep 3s
Type "Go"
Type 'fn fail(e: &Error) { eprintln!("{e}"); }'
Escape
Sleep 2s
Screenshot "13-imports-remembered.png"
Sleep 500ms
Type "y"
Sleep 4s
Type "gg"
Sleep 1s
Screenshot "13-imports-imported.png"
Sleep 500ms
Type ":w"
Enter
Sleep 1s
Type ":e src/lib.rs"
Enter
Sleep 3s
Type "Go"
Enter
Type "pub fn sample() -> String { probe_line!("
Ctrl+k
Sleep 3s
Screenshot "13-imports-signature.png"
Sleep 500ms
Type '"db", 5432, '
Ctrl+k
Sleep 3s
Screenshot "13-imports-signature-arm.png"
Sleep 500ms
Escape
Escape
Type ":w"
Enter
Sleep 1s
Type ":e src/main.rs"
Enter
Sleep 3s
Type "8G"
Type "0fP"
Type " rx"
Sleep 6s
Screenshot "13-imports-expand.png"
Sleep 500ms
Type "gi"
Sleep 2s
Screenshot "13-imports-expand-items.png"
Sleep 500ms
Escape
Sleep 500ms
