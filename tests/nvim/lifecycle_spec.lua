local H = require('tests.helpers')
local p = require('searchlight')
local sessions = require('searchlight.sessions')
local function current_tab_test(name, requirements, run)
  H.test(name, requirements, function()
    local config = vim.deepcopy(p.config)
    p.setup({ open_in_new_tab = false })
    local ok, err = xpcall(run, debug.traceback)
    p.setup(config)
    assert(ok, err)
  end)
end
H.test(
  'public commands accept a root containing spaces and close their owning session',
  'S-01,S-03,Q-08',
  function()
    local a = H.fixture()
    local root = a .. '/root with spaces'
    vim.fn.mkdir(root, 'p')
    vim.cmd('SearchlightNew ' .. vim.fn.fnameescape(root))
    local s = sessions.get()
    H.eq(s.root, root)
    vim.cmd('SearchlightFocus ' .. s.id)
    H.eq(vim.api.nvim_get_current_buf(), s.buf)
    vim.cmd('SearchlightClose')
    H.eq(sessions.get(s.id), nil)
  end
)
H.test(
  'recent without an id restores the most recently used panel including :buffer access',
  'S-03',
  function()
    local a = H.fixture()
    local sa, sb = p.search(a), p.search(a)
    vim.cmd('buffer ' .. sa.buf)
    p.action(sa, 'hide')
    H.eq(p.recent(), sa)
    assert(sessions.owns(sb))
  end
)
current_tab_test(
  'search reuses the empty startup window instead of leaving a blank split',
  'S-01,S-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
    local editor = vim.api.nvim_get_current_win()
    local s = H.search(a)
    H.eq(vim.api.nvim_tabpage_list_wins(0), { editor })
    H.eq(vim.api.nvim_win_get_buf(editor), s.buf)
    local buf, source = p.open(s)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    H.eq(vim.api.nvim_buf_get_name(buf), a .. '/one')
    assert(vim.api.nvim_win_get_position(source)[1] > 0)
    H.eq(vim.api.nvim_win_get_buf(editor), s.buf)
  end
)
current_tab_test(
  'opening search preserves named, modified, and special empty buffers',
  'S-01',
  function()
    local a = H.fixture()
    for _, kind in ipairs({ 'named', 'modified', 'special' }) do
      local buf = vim.api.nvim_create_buf(true, false)
      if kind == 'named' then
        vim.api.nvim_buf_set_name(buf, a .. '/empty')
      elseif kind == 'modified' then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved text' })
      else
        vim.bo[buf].buftype = 'nofile'
      end
      vim.api.nvim_win_set_buf(0, buf)
      local editor = vim.api.nvim_get_current_win()
      local s = p.search(a)
      H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
      H.eq(vim.api.nvim_win_get_buf(editor), buf)
      p.action(s, 'hide')
      p.close(s)
    end
  end
)
current_tab_test(
  'opening search preserves an existing layout of empty editor splits',
  'S-01',
  function()
    local a = H.fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)
    vim.cmd('vsplit')
    local editors = vim.api.nvim_tabpage_list_wins(0)
    p.search(a)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 3)
    for _, win in ipairs(editors) do
      H.eq(vim.api.nvim_win_get_buf(win), buf)
    end
  end
)
current_tab_test(
  'every New Search creates a uniquely named listed nofile top split',
  'S-01,S-02',
  function()
    local a = H.fixture()
    local editor = vim.api.nvim_get_current_win()
    local sa, sb = p.search(a), p.search(a)
    assert(sa.id ~= sb.id and sa.buf ~= sb.buf)
    H.eq(vim.api.nvim_buf_get_name(sa.buf), 'searchlight://' .. sa.id)
    H.eq(vim.bo[sa.buf].bufhidden, 'hide')
    H.eq(vim.bo[sa.buf].buftype, 'nofile')
    H.eq(vim.bo[sa.buf].buflisted, true)
    assert(#vim.fn.win_findbuf(sa.buf) > 0 and #vim.fn.win_findbuf(sb.buf) > 0)
    local first, second = vim.fn.win_findbuf(sa.buf)[1], vim.fn.win_findbuf(sb.buf)[1]
    H.eq(vim.api.nvim_win_get_position(second), { 0, 0 })
    H.eq(vim.api.nvim_win_get_width(second), vim.o.columns)
    assert(vim.api.nvim_win_get_position(first)[1] > 0)
    assert(vim.api.nvim_win_get_position(editor)[1] > vim.api.nvim_win_get_position(first)[1])
  end
)
H.test('listed panel names include the search term and stay unique', 'S-01,S-02', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc xyz\n')
  local sa = H.search(a, { query = 'abc' })
  local sb = H.search(a, { query = 'xyz' })
  H.eq(vim.api.nvim_buf_get_name(sa.buf), 'searchlight://' .. sa.id .. '/abc')
  H.eq(vim.api.nvim_buf_get_name(sb.buf), 'searchlight://' .. sb.id .. '/xyz')
  H.eq(vim.bo[sa.buf].buftype, 'nofile')
  H.eq(vim.bo[sa.buf].buflisted, true)
  local previous = vim.api.nvim_buf_get_name(sa.buf)
  p.set(sa, { query = 'a/b#c' })
  H.eq(vim.api.nvim_buf_get_name(sa.buf), 'searchlight://' .. sa.id .. '/a_b_c')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    assert(not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= previous)
  end
  p.set(sa, { query = string.rep('q', 41) })
  H.eq(
    vim.api.nvim_buf_get_name(sa.buf),
    'searchlight://' .. sa.id .. '/' .. string.rep('q', 40) .. '…'
  )
  p.set(sa, { query = '' })
  H.eq(vim.api.nvim_buf_get_name(sa.buf), 'searchlight://' .. sa.id)
  p.set(sa, { query = 'abc' })
  p.action(sa, 'hide')
  vim.cmd('buffer searchlight://' .. sa.id .. '/abc')
  H.eq(vim.api.nvim_get_current_buf(), sa.buf)
end)
H.test(
  'window closure hides, recent restores, explicit delete disposes only the owner',
  'S-03,S-04',
  function()
    local a, b = H.fixture()
    H.write(a .. '/one', 'abc\n')
    H.write(b .. '/two', 'abc\n')
    local sa, sb = H.search(a), H.search(b)
    p.action(sa, 'hide')
    H.eq(#vim.fn.win_findbuf(sa.buf), 0)
    assert(sessions.owns(sa))
    H.eq(p.recent(sa.id), sa)
    H.eq(vim.api.nvim_get_current_buf(), sa.buf)
    H.eq(vim.api.nvim_win_get_position(0), { 1, 0 })
    H.eq(vim.api.nvim_win_get_width(0), vim.o.columns)
    vim.cmd('bdelete ' .. sa.buf)
    H.eq(sessions.get(sa.id), nil)
    assert(sessions.owns(sb))
    H.eq(p.recent(), sb)
  end
)
H.test(
  'sessions survive separate tabs and ordinary config reloads',
  'S-02,S-03,Integration',
  function()
    local a, b = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    H.write(b .. '/two', 'xyz\n')
    local sa = H.search(a)
    p.navigate(sa, 1)
    vim.cmd('tabnew')
    local sb = H.search(b, { query = 'xyz', case = true })
    local selected, generation = sa.selected, sa.generation
    local handlers = #vim.api.nvim_get_autocmds({ group = 'SearchlightSources' })
    for _ = 1, 3 do
      require('searchlight').setup()
    end
    H.eq(sa.selected, selected)
    H.eq(sa.generation, generation)
    assert(sessions.owns(sa) and sessions.owns(sb))
    p.recent(sa.id)
    H.eq(vim.api.nvim_get_current_buf(), sa.buf)
    H.eq(#vim.api.nvim_get_autocmds({ group = 'SearchlightSources' }), handlers)
  end
)
H.test(
  'opening results preserves every panel and navigates by byte column',
  'S-05,R-01,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', '雪 abc abc\n')
    local sa, sb = H.search(a), H.search(a)
    p.navigate(sa, 1)
    p.action(sa, 'exclude')
    local selected = sa.selected
    local buf, win = p.open(sa)
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 8 })
    H.eq(vim.api.nvim_buf_get_name(buf), a .. '/one')
    assert(sessions.owns(sa) and sessions.owns(sb))
    assert(#vim.fn.win_findbuf(sa.buf) > 0 and #vim.fn.win_findbuf(sb.buf) > 0)
    p.recent(sa.id)
    H.eq(sa.selected, selected)
    H.eq(sa.results[2].enabled, false)
  end
)
H.test('source jumps center matches while preserving occurrence selection', 'R-10', function()
  local a = H.fixture()
  local lines = {}
  for i = 1, 240 do
    lines[i] = 'source line ' .. i
  end
  lines[1], lines[120], lines[240] = '雪 abc', '雪 abc abc', '雪 abc'
  H.write(a .. '/one', table.concat(lines, '\n') .. '\n')
  local s = H.search(a)
  for _, height in ipairs({ 6, 10 }) do
    for index, cursor in ipairs({ { 1, 4 }, { 120, 4 }, { 120, 8 }, { 240, 4 } }) do
      p.recent(s.id)
      vim.api.nvim_win_set_height(0, height)
      p.navigate(s, -#s.results)
      p.navigate(s, index - 1)
      local selected = s.selected
      local _, win = p.open(s)
      vim.cmd('redraw')
      H.eq(vim.api.nvim_win_get_cursor(win), cursor)
      H.eq(
        vim.fn.winline(),
        math.min(cursor[1], math.floor(vim.api.nvim_win_get_height(win) / 2) + 1)
      )
      H.eq(s.selected, selected)
      -- Leave a scrolled view behind before reopening this source buffer.
      vim.cmd('normal! Gzt')
      vim.api.nvim_win_close(win, true)
    end
  end
end)
H.test('each source jump opens a fresh horizontal split below search', 'S-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  H.write(a .. '/two', 'abc\n')
  local editor = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_win_get_buf(editor)
  local s = H.search(a)
  local panel = vim.api.nvim_get_current_win()
  local windows = #vim.api.nvim_tabpage_list_wins(0)
  local buf, first = p.action(s, 'open')
  H.eq(#vim.api.nvim_tabpage_list_wins(0), windows + 1)
  H.eq(vim.api.nvim_win_get_cursor(first), { 1, 0 })
  p.recent(s.id)
  p.navigate(s, 1)
  local same_buf, second = p.action(s, 'open')
  assert(first ~= second)
  H.eq(same_buf, buf)
  H.eq(#vim.api.nvim_tabpage_list_wins(0), windows + 2)
  H.eq(vim.api.nvim_win_get_cursor(first), { 1, 0 })
  H.eq(vim.api.nvim_win_get_cursor(second), { 1, 4 })
  -- The API also opens below the panel when called from a source window.
  p.navigate(s, 1)
  local other_buf, third = p.open(s)
  assert(third ~= first and third ~= second)
  H.eq(vim.api.nvim_buf_get_name(other_buf), a .. '/two')
  H.eq(#vim.api.nvim_tabpage_list_wins(0), windows + 3)
  H.eq(vim.api.nvim_win_get_buf(first), buf)
  H.eq(vim.api.nvim_win_get_buf(second), buf)
  H.eq(vim.api.nvim_win_get_buf(editor), original_buf)
  H.eq(vim.api.nvim_win_get_position(panel), { 1, 0 })
  for _, win in ipairs({ first, second, third }) do
    H.eq(vim.api.nvim_win_get_width(win), vim.o.columns)
    assert(vim.api.nvim_win_get_position(win)[1] > 0)
  end
end)
H.test(
  'source jumps restore hidden search in its tab and empty searches do not split',
  'S-03,S-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local empty = p.search(a)
    local windows = #vim.api.nvim_tabpage_list_wins(0)
    H.eq(p.open(empty), nil)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), windows)
    p.close(empty)
    local s = H.search(a)
    p.action(s, 'hide')
    local _, source = p.open(s)
    local panel = vim.fn.win_findbuf(s.buf)[1]
    H.eq(vim.api.nvim_win_get_position(panel), { 1, 0 })
    assert(vim.api.nvim_win_get_position(source)[1] > 0)
    local tab = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabnew')
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_windows = vim.api.nvim_tabpage_list_wins(other_tab)
    local _, next_source = p.open(s)
    H.eq(vim.api.nvim_win_get_tabpage(next_source), tab)
    H.eq(vim.api.nvim_tabpage_list_wins(other_tab), other_windows)
    assert(vim.api.nvim_win_get_position(panel)[1] < vim.api.nvim_win_get_position(next_source)[1])
  end
)
H.test(
  'normal Vim search settings and conflicting global mappings are preserved',
  'Integration',
  function()
    H.fixture()
    vim.o.ignorecase, vim.o.hlsearch = false, true
    vim.keymap.set('n', '<leader>sp', '<Nop>', { desc = 'existing mapping' })
    vim.keymap.set('n', '<leader>fg', '<Nop>', { desc = 'Telescope existing picker' })
    p.setup()
    H.eq(vim.fn.maparg('<leader>sp', 'n', false, true).desc, 'existing mapping')
    H.eq(vim.fn.maparg('<leader>fg', 'n', false, true).desc, 'Telescope existing picker')
    H.eq(vim.o.ignorecase, false)
    H.eq(vim.o.hlsearch, true)
    vim.keymap.del('n', '<leader>sp')
    vim.keymap.del('n', '<leader>fg')
    p.setup()
  end
)
H.test('captured root survives later cwd changes', 'Q-08', function()
  local a, b = H.fixture()
  local original = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(a))
  local s = p.search()
  vim.cmd.cd(vim.fn.fnameescape(b))
  H.eq(s.root, require('searchlight.scope').path(a))
  vim.cmd.cd(vim.fn.fnameescape(original))
end)
