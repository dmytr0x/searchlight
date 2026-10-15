local H = require('tests.helpers')
local p = require('searchlight')
local process = require('searchlight.process')
local view = require('searchlight.view')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

H.test(
  'render consumes input without reading or changing search generation',
  'Q-01,Async',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local s = H.search(a)
    local read, generation = view.read, s.generation
    view.read = function()
      error('render must not read input')
    end
    local ok, err = pcall(view.render, s)
    view.read = read
    assert(ok, err)
    H.eq(s.generation, generation)
    H.eq(s.status, 'complete')
  end
)

H.test('queued redraw preserves input edits and cancels pending debounce', 'Q-01,Async', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc xyz\n')
  local s = H.replace(a)
  local original, calls = process.start, 0
  process.start = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, err = xpcall(function()
    p.set(s, { query = 'abc' })
    view.request_render(s)
    local region = s.regions.query
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'xyz' })
    vim.wait(100)
    H.eq(s.fields.query, 'xyz')
    H.eq(
      vim.api.nvim_buf_get_lines(s.buf, s.regions.query.start, s.regions.query.stop, false),
      { 'xyz' }
    )
    H.eq(calls, 0)
    H.eq(s.status, 'stale')
    H.eq(s.timer, nil)
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(s.results[1].match, 'xyz')
  end, debug.traceback)
  process.start = original
  assert(ok, err)
end)

for _, field in ipairs({ 'query', 'replacement', 'include', 'exclude' }) do
  H.test('typing in ' .. field .. ' waits for Enter to search', 'Q-01,Q-05', function()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc xyz\n')
    H.write(a .. '/two.txt', 'abc\n')
    local s = H.replace(a)
    view.focus_field(s, field)
    local original, calls = process.start, 0
    process.start = function(...)
      calls = calls + 1
      return original(...)
    end
    local ok, err = xpcall(function()
      local inputs = { query = 'xyz', replacement = 'Y', include = '*.lua', exclude = '*.txt' }
      local input = inputs[field]
      keys('0C' .. input .. '<Esc>')
      vim.wait(100)
      H.eq(calls, 0, 'input typing launched a search')
      assert(s.results[1].stale)
      local windows = #vim.api.nvim_tabpage_list_wins(0)
      keys('<CR>')
      H.wait(s, 'complete')
      assert(calls > 0, 'Enter did not submit the input')
      H.eq(#vim.api.nvim_tabpage_list_wins(0), windows)
      H.eq(#s.results, field == 'replacement' and 2 or 1)
      H.eq(s.results[1].match, field == 'query' and 'xyz' or 'abc')
      if field == 'replacement' then
        H.eq(s.results[1].replacement, 'Y')
        H.eq(H.read(a .. '/one.lua'), 'abc xyz\n')
      end
    end, debug.traceback)
    process.start = original
    if not ok then
      error(err)
    end
  end)
end

for _, field in ipairs({ 'query', 'replacement', 'include', 'exclude' }) do
  H.test('insert Enter submits ' .. field .. ' without a newline', 'Q-01,Q-05', function()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc\n')
    local s = p.replace(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    H.wait(s, 'complete')
    view.focus_field(s, field)
    local inputs = { query = 'abc', replacement = 'Y', include = '*.lua', exclude = '*.txt' }
    local input = inputs[field]
    keys('0C' .. input .. '<CR><Esc>')
    H.wait(s, 'complete')
    H.eq(s.fields[field], (field == 'include' or field == 'exclude') and { input } or input)
    H.eq(#s.results, 1)
    if field == 'replacement' then
      H.eq(s.results[1].replacement, 'Y')
    end
    H.eq(vim.api.nvim_get_current_buf(), s.buf)
  end)
end

H.test('Enter submits an empty query without searching or opening an old result', 'Q-01', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local s = H.search(a)
  view.focus_field(s, 'query')
  local windows = #vim.api.nvim_tabpage_list_wins(0)
  keys('0C<CR><Esc>')
  vim.wait(100)
  H.eq(s.status, 'empty')
  H.eq(#s.results, 0)
  H.eq(s.timer, nil)
  H.eq(next(s.pending_jobs), nil)
  H.eq(#vim.api.nvim_tabpage_list_wins(0), windows)
end)

H.test('Enter still collapses file headers and opens result rows', 'S-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local s = H.search(a)
  local header = s.file_headers[a .. '/one']
  vim.api.nvim_win_set_cursor(0, { header, 0 })
  keys('<CR>')
  H.eq(s.collapsed_paths[a .. '/one'], true)
  keys('<CR>')
  H.eq(s.collapsed_paths[a .. '/one'], nil)
  local position = s.result_positions[s.selected]
  vim.api.nvim_win_set_cursor(0, { position.row, position.col })
  keys('<CR>')
  H.eq(vim.api.nvim_buf_get_name(0), a .. '/one')
  H.eq(vim.fn.maparg('<CR>', 'i', false, true), {})
end)

H.test('editing an opened source never launches searches on keystrokes', 'Q-01,S-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local s = H.search(a)
  local buf = p.open(s)
  vim.wait(100)
  local original, calls = process.start, 0
  process.start = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, err = xpcall(function()
    for i = 1, 3 do
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' .. string.rep('x', i) })
      vim.api.nvim_exec_autocmds('TextChangedI', { buffer = buf })
      vim.wait(100)
      H.eq(calls, 0, 'source typing launched a search')
    end
    H.eq(s.status, 'stale')
    assert(s.results[1].stale)
    p.refresh(s)
    H.wait(s, 'complete')
    assert(calls > 0, 'explicit refresh must still launch a search')
    H.eq(s.results[1].snapshot.text, 'abcxxx\n')
  end, debug.traceback)
  process.start = original
  if not ok then
    error(err)
  end
end)
