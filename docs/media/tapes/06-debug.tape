# Debugging with nvim-dap + codelldb: breakpoint, then the Rust-aware variable view.
Type "nvim src/main.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type "/let ports"
Enter
Sleep 300ms
Type " db"
Sleep 800ms
Type " dR"
Sleep 3s
Screenshot "06-debug-picker.png"
Enter
Wait+Screen@120s /Stopped at line/
Sleep 3s
Screenshot "06-debug-stopped.png"
Sleep 500ms
