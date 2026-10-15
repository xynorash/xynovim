# serde without its `derive` feature: the error and the "Enable feature" fix;
# then derive-name completion (the import is added), #[serde( keys and values
# with their docs, and #[arg( in the clap struct of main.rs.
Set Framerate 10
Hide
Type "bash ../support/attributes.sh"
Enter
Type "clear"
Enter
Show
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 3s
Type "137G"
Sleep 3s
Screenshot "12-attributes-missing-feature.png"
Sleep 500ms
Type " rG"
Sleep 1s
Screenshot "12-attributes-fix.png"
Sleep 15s
Screenshot "12-attributes-fixed.png"
Sleep 500ms
Type ":vsp Cargo.toml"
Enter
Sleep 3s
Screenshot "12-attributes-cargo-toml.png"
Sleep 500ms
Type ":q"
Enter
Sleep 500ms
Type "144G"
Type "O"
Type "#[derive(Des"
Sleep 3s
Screenshot "12-attributes-derive-menu.png"
Sleep 500ms
Enter
Sleep 6s
Escape
Sleep 1s
Type "gg"
Sleep 1s
Screenshot "12-attributes-derive-import.png"
Sleep 500ms
Type "145G"
Type "O"
Type "#[serde("
Sleep 3s
Screenshot "12-attributes-serde-keys.png"
Sleep 500ms
Type 'rename_all = "'
Sleep 3s
Screenshot "12-attributes-serde-values.png"
Sleep 500ms
Type "camel"
Sleep 800ms
Enter
Sleep 1s
Escape
Sleep 500ms
Type ":w"
Enter
Type ":e src/main.rs"
Enter
Sleep 4s
Type "17G"
Type "o"
Type "retries: u32,"
Escape
Type "O"
Type "#[arg("
Sleep 3s
Screenshot "12-attributes-arg-keys.png"
Sleep 500ms
Type 'long, value_name = "N"'
Sleep 1s
Screenshot "12-attributes-arg-done.png"
Sleep 500ms
Escape
Sleep 500ms
