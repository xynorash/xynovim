# New egui Project: the dashboard entry, the prompts (name with the hyphen
# conversion, author name and e-mail prefilled, parent directory), the created
# project opened. The template ZIP is staged by record.sh, the parent directory is
# a temp dir (support/egui.sh).
Hide
Type "source ../support/egui.sh"
Enter
Type "clear"
Enter
Show
Type "nvim"
Enter
Sleep 4s
Screenshot "14-egui-new-dashboard.png"
Sleep 1s
Type "e"
Sleep 2s
Type "weather-panel"
Sleep 1s
Screenshot "14-egui-new-name.png"
Sleep 2s
Enter
Sleep 2s
Screenshot "14-egui-new-author.png"
Sleep 1s
Enter
Sleep 1500ms
Screenshot "14-egui-new-email.png"
Sleep 1s
Enter
Sleep 1500ms
Screenshot "14-egui-new-directory.png"
Sleep 1s
Enter
Sleep 2500ms
Screenshot "14-egui-new-created.png"
Sleep 1s
Type ":vsp Cargo.toml"
Enter
Sleep 2s
Screenshot "14-egui-new-cargo-toml.png"
Sleep 1s
Type ":e index.html"
Enter
Sleep 2s
Screenshot "14-egui-new-index-html.png"
Sleep 1s
Type ":only | e src/main.rs"
Enter
Sleep 3s
Screenshot "14-egui-new-main-rs.png"
Sleep 1s
