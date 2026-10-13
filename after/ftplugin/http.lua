-- LazyVim sets conceallevel=2 globally; in a request body it hid the quotes of JSON
-- (`{"a": 1}` showed as `{a: 1}`), which is not what a request sends.
vim.opt_local.conceallevel = 0
