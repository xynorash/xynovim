# Hero shot: Island Dark, rust-analyzer inlay hints, treesitter-context sticky
# scope (three header lines pinned at the top), statusline with git, breadcrumbs,
# server state and clippy state.
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 3s
Type "/ports.extend"
Enter
Type "zt"
Sleep 2s
Screenshot "01-hero.png"
Sleep 1s
