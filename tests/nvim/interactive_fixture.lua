-- Disposable roots for manual Search and Search & Replace walkthroughs.
local H = dofile('tests/nvim/helpers.lua')
local a, b = H.fixture()
H.write(a .. '/one.lua', '雪 abc abc\nsecond abc\n')
H.write(a .. '/two.txt', 'abc\n')
H.write(a .. '/skip.txt', 'abc\n')
H.write(a .. '/.venv/ignored.txt', 'abc\n')
H.write(a .. '/.git/metadata', 'abc\n')
H.write(b .. '/other.txt', 'xyz\n')
require('searchlight').setup()
local p = require('searchlight')
_G.manual = { a = a, b = b, search = p.search(a), replace = p.replace(a) }
vim.api.nvim_create_autocmd('VimLeavePre', {
  once = true,
  callback = function()
    vim.fn.delete(H.root, 'rf')
  end,
})
