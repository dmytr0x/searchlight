-- Run with GRUG_FAR_PATH pointing at a disposable clone. XDG_DATA_HOME must be isolated.
assert(vim.env.GRUG_FAR_PATH, 'set GRUG_FAR_PATH')
vim.pack.add({ { src = 'file://' .. vim.env.GRUG_FAR_PATH } })
local adapter = dofile('tests/prototype/grug_adapter.lua')
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/a', 'p')
vim.fn.mkdir(root .. '/b', 'p')
vim.fn.writefile({ 'abc abc' }, root .. '/a/one.txt')
vim.fn.writefile({ 'xyz' }, root .. '/b/two.txt')
local ok, err = xpcall(function()
  local a = adapter.new(root .. '/a', { search = 'abc', replacement = 'X' })
  adapter.controls(a, { regex = true }, {}, {})
  local b = adapter.new(root .. '/b', { search = 'xyz', replacement = 'Y' })
  adapter.controls(b, { regex = true }, {}, {})
  assert(a.buf ~= b.buf and a.name ~= b.name)
  a.instance:search()
  b.instance:search()
  assert(vim.wait(5000, function()
    return (a.instance:get_status_info().stats or {}).matches == 2
      and (b.instance:get_status_info().stats or {}).matches == 1
  end, 10))
  adapter.focus(a)
  local lines = vim.api.nvim_buf_get_lines(a.buf, 0, -1, false)
  print('A results: ' .. vim.inspect(lines))
  print('B status: ' .. vim.inspect(b.instance:get_status_info()))
  local source = vim.fn.bufadd(root .. '/a/one.txt')
  vim.fn.bufload(source)
  vim.bo[source].buflisted = true
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved abc' })
  a.instance:update_input_values({ search = 'unsaved', paths = '<buflist-cwd>' }, false)
  a.instance:search()
  assert(vim.wait(5000, function()
    return (a.instance:get_status_info().stats or {}).matches == 0
  end, 10))
  vim.wait(300)
  print('Dirty buffer search: ' .. vim.inspect(a.instance:get_status_info()))
  print('Dirty search panel: ' .. vim.inspect(vim.api.nvim_buf_get_lines(a.buf, 0, -1, false)))
  assert(
    ((a.instance:get_status_info().stats or {}).matches or 0) == 0,
    're-evaluate: unsaved search changed'
  )
  a.instance:update_input_values({ search = 'abc', paths = root .. '/a' }, false)
  a.instance:search()
  vim.wait(1000)
  a.instance:replace()
  vim.wait(1000)
  print('Disk after Replace all: ' .. table.concat(vim.fn.readfile(root .. '/a/one.txt'), '\n'))
  print(
    'Dirty buffer after Replace all: '
      .. table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n')
  )
  assert(vim.fn.readfile(root .. '/a/one.txt')[1] == 'X X', 're-evaluate: disk replacement changed')
  -- Exercise the public selective-apply API with two occurrences on one line.
  vim.fn.writefile({ 'abc abc' }, root .. '/a/one.txt')
  a.instance:search()
  vim.wait(500)
  lines = vim.api.nvim_buf_get_lines(a.buf, 0, -1, false)
  for row, line in ipairs(lines) do
    if line == 'abc abc' then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      break
    end
  end
  a.instance:apply_next_change({ open_location = false, remove_synced = false })
  vim.wait(500)
  print('Disk after Apply next: ' .. table.concat(vim.fn.readfile(root .. '/a/one.txt'), '\n'))
  assert(vim.fn.readfile(root .. '/a/one.txt')[1] == 'X X', 're-evaluate: per-line apply changed')
  -- Explicit teardown, preserving the other named instance until its own deletion.
  vim.api.nvim_buf_delete(a.buf, { force = true })
  assert(vim.api.nvim_buf_is_valid(b.buf))
  vim.api.nvim_buf_delete(b.buf, { force = true })
end, debug.traceback)
vim.cmd.cd(vim.fn.fnameescape(vim.env.PWD))
vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit(1)
else
  vim.cmd.qa({ bang = true })
end
