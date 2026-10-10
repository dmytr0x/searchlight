local H = require('tests.helpers')
local p = require('searchlight')

local function with_search_state(run)
  local saved = {
    pattern = vim.fn.getreg('/'),
    active = vim.v.hlsearch,
    direction = vim.v.searchforward,
  }
  for _, option in ipairs({ 'hlsearch', 'ignorecase', 'smartcase', 'magic', 'wrapscan' }) do
    saved[option] = vim.o[option]
  end
  local ok, err = xpcall(run, debug.traceback)
  vim.fn.setreg('/', saved.pattern)
  for _, option in ipairs({ 'hlsearch', 'ignorecase', 'smartcase', 'magic', 'wrapscan' }) do
    vim.o[option] = saved[option]
  end
  vim.v.hlsearch = saved.active
  vim.v.searchforward = saved.direction
  if not ok then
    error(err)
  end
end

local function count()
  return vim.fn.searchcount({ recompute = true, maxcount = 0, timeout = 1000 }).total
end

H.test('reopening a source rebuilds a readable whole-word search', 'Q-03,S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', 'Action Action_\nAction\n')
    H.write(a .. '/two', 'Action\nAction Action_\n')
    local s = H.search(a, { query = 'Action', word = true })
    local buf, win = p.open(s)
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 2, 0 })
    vim.api.nvim_buf_delete(buf, { force = true })
    p.focus(s.id)
    p.navigate(s, 2)
    p.open(s)
    H.eq(vim.fn.getreg('/'), '\\c\\<\\VAction\\>')
    H.eq(count(), 2)
  end)
end)

H.test(
  'source jumps replace prior searches for every matching modifier combination',
  'Q-02,Q-03,Q-04,S-05',
  function()
    with_search_state(function()
      for _, regex in ipairs({ false, true }) do
        for _, word in ipairs({ false, true }) do
          for _, case in ipairs({ false, true }) do
            local a = H.fixture()
            H.write(a .. '/one', 'abc ABC abcc\nabc ABC abcc\n')
            H.write(a .. '/two', 'abc ABC abcc\nabc ABC abcc\n')
            local query = regex and 'ab+c' or 'abc'
            local s = H.search(a, { query = query, regex = regex, word = word, case = case })
            local expected = (case and '\\C' or '\\c')
              .. (
                regex and (word and '\\v<(ab+c)>' or '\\vab+c')
                or (word and '\\<\\Vabc\\>' or '\\Vabc')
              )
            local total = 2 * (word and (case and 1 or 2) or (case and 2 or 3))
            for _ = 1, 2 do
              p.focus(s.id)
              p.navigate(s, -#s.results)
              local buf, win = p.open(s)
              H.eq(vim.fn.getreg('/'), expected)
              H.eq(count(), total)
              vim.cmd('normal! n')
              H.eq(
                vim.api.nvim_win_get_cursor(win),
                case and (word and { 2, 0 } or { 1, 8 }) or { 1, 4 }
              )
              vim.api.nvim_buf_delete(buf, { force = true })
              if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
              end
              -- A user search between jumps must be replaced, never retained or appended.
              vim.fn.setreg('/', '\\Cunrelated')
              p.focus(s.id)
              p.navigate(s, #s.results)
              buf, win = p.open(s)
              H.eq(vim.api.nvim_buf_get_name(buf), a .. '/two')
              H.eq(vim.fn.getreg('/'), expected)
              H.eq(count(), total)
              vim.cmd('normal! N')
              H.eq(vim.fn.getreg('/'), expected)
              vim.api.nvim_win_close(win, true)
            end
            H.cleanup()
          end
        end
      end
    end)
  end
)

H.test(
  'whole-word regex groups alternatives without matching word prefixes',
  'Q-03,Q-04,S-05',
  function()
    with_search_state(function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc_ abc xyz xyz_\n')
      local s = H.search(a, { query = 'abc|xyz', regex = true, word = true })
      local _, win = p.open(s)
      H.eq(vim.fn.getreg('/'), '\\c\\v<(abc|xyz)>')
      H.eq(count(), 2)
      vim.cmd('normal! n')
      H.eq(vim.api.nvim_win_get_cursor(win), { 1, 9 })
    end)
  end
)

H.test('opening a literal result keeps the native search pattern readable', 'S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', 'Action\n')
    local s = H.search(a, { query = 'Action' })
    p.open(s)
    H.eq(vim.fn.getreg('/'), '\\c\\VAction')
    H.eq(count(), 1)
    H.update(s, { query = 'Action' })
    local _, win = p.open(s)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, {
      'Action action Action',
    })
    H.eq(count(), 3)
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 7 })
  end)
end)

H.test('opening results highlights file matches and enables native n and N', 'S-05,R-08', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', '雪 abc abc\nABC\n')
    H.write(a .. '/two', 'abc abc abc abc\n')
    vim.o.ignorecase, vim.o.smartcase, vim.o.magic = false, true, false
    vim.o.hlsearch, vim.o.wrapscan = false, true
    local prior = H.buffer(a .. '/prior', { 'previous', 'previous' })
    vim.api.nvim_set_current_buf(prior)
    vim.cmd('silent normal! ?previous?e\r')
    H.eq(vim.v.searchforward, 0)
    local s = H.search(a)
    H.eq(vim.fn.getreg('/'), 'previous')
    H.eq(vim.o.hlsearch, false)
    s.results[2].enabled = false
    p.navigate(s, 1)
    local _, win = p.action(s, 'open')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 8 })
    H.eq(vim.o.hlsearch, true)
    H.eq(vim.v.hlsearch, 1)
    H.eq(vim.v.searchforward, 1)
    H.eq(count(), 3)
    H.eq(vim.o.ignorecase, false)
    H.eq(vim.o.smartcase, true)
    H.eq(vim.o.magic, false)
    H.eq(vim.fn.maparg('n', 'n', false, true), {})
    H.eq(vim.fn.maparg('N', 'n', false, true), {})
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 2, 0 })
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 4 })
    vim.cmd('normal! N')
    H.eq(vim.api.nvim_win_get_cursor(win), { 2, 0 })
    vim.cmd('normal! 2N')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 4 })
    vim.o.wrapscan = false
    local ok = pcall(vim.cmd, 'normal! N')
    H.eq(ok, false)
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 4 })
    vim.cmd('nohlsearch')
    H.eq(vim.v.hlsearch, 0)
    p.focus(s.id)
    p.open(s)
    H.eq(vim.v.hlsearch, 1)
    vim.fn.setreg('/', '\\CABC')
    H.eq(count(), 1)
  end)
end)

H.test('source search preserves literal punctuation and match case', 'Q-04,S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', '雪 a.b\\c/d A.B\\C/D axb\\c/d\na.b\\c/d\n')
    vim.o.ignorecase, vim.o.magic = true, false
    local s = H.search(a, { query = 'a.b\\c/d', case = true })
    local _, win = p.open(s)
    H.eq(vim.fn.getreg('/'), '\\C\\Va.b\\\\c/d')
    H.eq(count(), 2)
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 2, 0 })
    vim.cmd('normal! N')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 4 })
  end)
end)

H.test('whole-word source search uses native buffer word boundaries', 'Q-03,S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', 'Action Action_ Action-x\n')
    local s = H.search(a, { query = 'Action', word = true })
    H.eq(#s.results, 2)
    local buf, win = p.open(s)
    H.eq(vim.fn.getreg('/'), '\\c\\<\\VAction\\>')
    H.eq(count(), 2)
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 15 })
    vim.bo[buf].iskeyword = '@,48-57,_,-'
    H.eq(count(), 1)
  end)
end)

H.test('capped source search uses the query beyond recorded occurrences', 'S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', 'Action Action Action\n')
    local s = p.new(a)
    s.config.max_results = 2
    p.set(s, { query = 'Action' })
    p.refresh(s)
    H.wait(s, 'truncated')
    H.eq(#s.results, 2)
    local _, win = p.open(s)
    H.eq(vim.fn.getreg('/'), '\\c\\VAction')
    H.eq(count(), 3)
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 7 })
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 14 })
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, 0 })
  end)
end)

H.test('opening stale results uses the current query and controls', 'S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', 'Action Action xyz\n')
    local s = H.search(a, { query = 'Action' })
    p.set(s, { query = 'xyz', case = true, word = true })
    H.eq(s.status, 'waiting')
    p.open(s)
    H.eq(vim.fn.getreg('/'), '\\C\\<\\Vxyz\\>')
    H.eq(count(), 1)
  end)
end)

H.test('source search applies regex and whole-word controls to the query', 'Q-04,S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abcc ABC abc_\nabbbbc abc\n')
    local s = H.search(a, { query = 'ab+c', regex = true, word = true })
    H.eq(#s.results, 4)
    local _, win = p.open(s)
    H.eq(vim.fn.getreg('/'), '\\c\\v<(ab+c)>')
    H.eq(count(), 4)
    for _, cursor in ipairs({ { 1, 9 }, { 2, 0 }, { 2, 7 } }) do
      vim.cmd('normal! n')
      H.eq(vim.api.nvim_win_get_cursor(win), cursor)
    end
    -- The native highlight covers the full variable-length capture.
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    H.eq(vim.fn.searchpos('', 'cenW'), { 2, 6 })
  end)
end)

H.test(
  'source search follows the opened session and handles zero-width hits',
  'S-02,S-05',
  function()
    with_search_state(function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc xyz\nabc xyz\n')
      local sa = H.search(a)
      local sb = H.search(a, { query = '^|$', regex = true })
      p.open(sb)
      H.eq(count(), 4)
      p.focus(sa.id)
      p.open(sa)
      H.eq(count(), 2)
      vim.cmd('normal! n')
      H.eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
      p.focus(sb.id)
      p.open(sb)
      H.eq(count(), 4)
    end)
  end
)

H.test('source search supports the default result cap without regexp overflow', 'S-05', function()
  with_search_state(function()
    local a = H.fixture()
    local lines = {}
    for i = 1, 10000 do
      lines[i] = 'abc'
    end
    H.buffer(a .. '/one', lines)
    local s = H.search(a, { query = 'abc', open = true })
    H.eq(#s.results, 10000)
    p.open(s)
    vim.cmd('normal! n')
    H.eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
    vim.cmd('normal! N')
    H.eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
  end)
end)
