# The automated test suite, run the way anyone can run it after cloning.
Set Width 1300
Set Height 760
Type "cd ~/.config/nvim && scripts/test.sh smoke theme-island rust-routes rust-context"
Enter
Wait+Screen@240s /total: [0-9]+ passed/
Sleep 2s
Screenshot "10-test-suite.png"
Sleep 500ms
