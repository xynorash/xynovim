# Neotest summary + dap-ui at 93 columns

Real pixels (Ghostty, X11, 93 columns, `tools/ui-capture/narrow/shot.sh`), both panels opened together.

- `before-93col.png`: the code window is 21 columns wide (48-column summary split plus a 40-column dap-ui sidebar).
- `after-93col.png`: below 120 columns (`vim.g.xynovim_narrow_columns`) the summary is a float over the right edge
  (`q` or leaving it closes it) and dap-ui is one bottom strip; the code window is the full 93 columns.
  The float also covers part of the strip while it is open: that is the price of not shrinking the code.

The window of this capture was only 30 rows high (the compositor decides), so the strip leaves few code rows.
