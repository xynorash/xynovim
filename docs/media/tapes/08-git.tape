# Git UI: lazygit with delta, diffview, and the local-history safety net.
Hide
Type "bash ../support/edit-doc.sh"
Enter
Type "clear"
Enter
Show
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type " gg"
Sleep 6s
Screenshot "08-git-lazygit.png"
Type "q"
Sleep 800ms
Type " gv"
Sleep 3s
Screenshot "08-git-diffview.png"
Type " gq"
Sleep 800ms
Type "o"
Type "// local history"
Escape
Type ":w"
Enter
Sleep 800ms
Type ":LocalHistory"
Enter
Sleep 2s
Screenshot "08-git-local-history.png"
Escape
Sleep 500ms
