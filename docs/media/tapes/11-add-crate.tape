# A path starting with a crate that is no dependency: the hint, the "Add crate"
# picker with features and target, the build recognising it, and the import for
# a name typed afterwards (the yes/no auto-import dialog).
Hide
Type "bash ../support/add-crate.sh"
Enter
Type "clear"
Enter
Show
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 3s
Type "Gk^"
Sleep 2s
Screenshot "11-add-crate-hint.png"
Sleep 500ms
Type " ca"
Sleep 2s
Screenshot "11-add-crate-action.png"
Sleep 500ms
Type "choose"
Sleep 500ms
Enter
Sleep 4s
Screenshot "11-add-crate-search.png"
Sleep 500ms
Enter
Sleep 3s
Screenshot "11-add-crate-features-all.png"
Sleep 500ms
Type "v4"
Sleep 800ms
Tab
Sleep 1s
Screenshot "11-add-crate-features.png"
Sleep 500ms
Enter
Sleep 5s
Screenshot "11-add-crate-target.png"
Sleep 500ms
Enter
Sleep 20s
Screenshot "11-add-crate-added.png"
Sleep 500ms
Type ":vsp Cargo.toml"
Enter
Sleep 3s
Screenshot "11-add-crate-cargo-toml.png"
Sleep 500ms
Type ":q"
Enter
Sleep 500ms
Type "Go"
Type "pub fn nil_id() -> Uuid { Uuid::nil() }"
Escape
Sleep 2s
Screenshot "11-add-crate-import.png"
Sleep 500ms
Type "y"
Sleep 2s
Screenshot "11-add-crate-imported.png"
Sleep 8s
Type "gg"
Sleep 1s
Screenshot "11-add-crate-imported-top.png"
Sleep 500ms
