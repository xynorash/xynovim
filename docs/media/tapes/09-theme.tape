# Island Dark (converted from a RustRover export): completion with docs,
# a picker, and hover.
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type "/ports.dedup"
Enter
Type "o"
Type "ports.so"
Sleep 4s
Screenshot "09-theme-completion.png"
Escape
Type "u"
Sleep 400ms
Type " ff"
Sleep 2s
Screenshot "09-theme-picker.png"
Escape
Escape
Sleep 400ms
Type "/fn report"
Enter
Type "K"
Sleep 2500ms
Screenshot "09-theme-hover.png"
Sleep 400ms
