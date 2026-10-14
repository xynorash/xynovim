# The <leader>r group (rust-analyzer assists), extract variable and rename.
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type "/Duration::from_millis"
Enter
Sleep 300ms
Type " "
Sleep 1800ms
Type "r"
Sleep 1800ms
Screenshot "03-refactor-menu.png"
Escape
Escape
Sleep 500ms
Type "/lo.parse"
Enter
Type "v"
Type "iw"
Sleep 400ms
Type " rv"
Sleep 2500ms
Screenshot "03-refactor-extract.png"
Sleep 500ms
