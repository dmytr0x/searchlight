vim.env.NVIM_LOG_FILE = vim.fn.tempname()
local original_config = vim.env.RIPGREP_CONFIG_PATH
local H = dofile('tests/nvim/helpers.lua')
package.loaded['tests.helpers'] = H
-- Enable cell highlight inspection before groups and cached screen attributes are created.
vim.api.nvim__inspect_cell(1, 0, 0)
local p = require('searchlight')
p.setup({ debounce_ms = 10 })
local files = {}
io.stdout:setvbuf('no')
-- Keep mode and file/search messages out of the PASS/FAIL stream.
vim.opt.shortmess:append('sWFS')
vim.o.showmode = false
for name, kind in vim.fs.dir('tests/nvim') do
  if kind == 'file' and name:match('_spec%.lua$') then
    table.insert(files, name)
  end
end
table.sort(files)
for _, file in ipairs(files) do
  dofile('tests/nvim/' .. file)
end
local failed, started = 0, vim.uv.hrtime()
for _, case in ipairs(H.cases) do
  local ok, err = xpcall(case.run, debug.traceback)
  if ok then
    io.stdout:write('PASS ' .. case.name .. ' [' .. case.requirements .. ']\n')
  else
    failed = failed + 1
    io.stderr:write('FAIL ' .. case.name .. '\n' .. err .. '\n')
  end
  H.cleanup()
end
vim.env.RIPGREP_CONFIG_PATH = original_config
print(
  string.format(
    '%d/%d passed in %.2fs',
    #H.cases - failed,
    #H.cases,
    (vim.uv.hrtime() - started) / 1e9
  )
)
if failed > 0 then
  vim.cmd.cquit(1)
else
  vim.cmd.qa({ bang = true })
end
