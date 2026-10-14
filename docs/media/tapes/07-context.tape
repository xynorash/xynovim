# Feature/target switcher: ssr and csr are mutually exclusive here.
# Both diagnostic tiers show the conflict until the context is narrowed.
Hide
Type "bash ../support/conflict.sh"
Enter
Type "clear"
Enter
Show
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 4s
Type "G"
Sleep 2s
Screenshot "07-context-conflict.png"
Type " rF"
Sleep 3s
Screenshot "07-context-picker.png"
Type "ssr"
Sleep 600ms
Tab
Sleep 600ms
Enter
Sleep 2s
Screenshot "07-context-target.png"
Enter
Sleep 9s
Screenshot "07-context-resolved.png"
Sleep 500ms
