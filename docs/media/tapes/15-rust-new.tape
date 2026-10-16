# New Rust projects: the dashboard with all entries, the workspace flow (key w,
# kind library, name inventory, the prefilled member name, a temp parent directory,
# the creation notification, the generated tree and manifests), then a binary
# (hello-bin) ending in src/main.rs. The parent directory is a temp dir (support/rustnew.sh).
Hide
Type "source ../support/rustnew.sh"
Enter
Type "clear"
Enter
Show
Type "nvim"
Enter
Sleep 4s
Screenshot "15-rust-new-dashboard.png"
Sleep 1s
Type "w"
Sleep 2s
Type "inventory"
Sleep 1s
Screenshot "15-rust-new-workspace-name.png"
Sleep 2s
Enter
Sleep 2s
Screenshot "15-rust-new-workspace-directory.png"
Sleep 1s
Enter
Sleep 2s
Down
Sleep 500ms
Screenshot "15-rust-new-workspace-kind-library.png"
Sleep 1s
Enter
Sleep 2s
Screenshot "15-rust-new-workspace-member.png"
Sleep 1s
Enter
Sleep 1500ms
Screenshot "15-rust-new-workspace-created.png"
Sleep 4s
Type ":Neotree reveal"
Enter
Sleep 2s
Type "H"
Sleep 5s
Screenshot "15-rust-new-workspace-tree.png"
Sleep 1s
Type ":Neotree close"
Enter
Sleep 1s
Type ":e Cargo.toml"
Enter
Sleep 2s
Screenshot "15-rust-new-workspace-cargo-toml.png"
Sleep 1s
Type ":e crates/inventory-core/Cargo.toml"
Enter
Sleep 2s
Screenshot "15-rust-new-member-cargo-toml.png"
Sleep 1s
Type ":RustNewBin"
Enter
Sleep 2s
Type "hello-bin"
Sleep 1s
Screenshot "15-rust-new-bin-name.png"
Sleep 1s
Enter
Sleep 2s
Screenshot "15-rust-new-bin-directory.png"
Sleep 1s
Enter
Sleep 1500ms
Screenshot "15-rust-new-bin-created.png"
Sleep 4s
Screenshot "15-rust-new-bin-main-rs.png"
Sleep 1s
