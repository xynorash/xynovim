# Treesitter at work: sticky scope (treesitter-context), :Inspect (captures and
# semantic tokens under the cursor), :InspectTree (the live syntax tree) and
# text objects (vaf selects the whole function).
Type "nvim src/lib.rs"
Enter
Wait+Screen@90s /RA ready/
Sleep 2s
Type "/ports.extend"
Enter
Type "zt"
Sleep 1500ms
Screenshot "04-treesitter-context.png"
Type ":Inspect"
Enter
Sleep 2s
Screenshot "04-treesitter-inspect.png"
Escape
Sleep 500ms
Type ":InspectTree"
Enter
Sleep 2500ms
Screenshot "04-treesitter-inspecttree.png"
Type "q"
Sleep 800ms
Type "/fn parse_ports"
Enter
Type "vaf"
Sleep 1500ms
Screenshot "04-treesitter-textobject.png"
Sleep 500ms
