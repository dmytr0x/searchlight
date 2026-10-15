local H = require('tests.helpers')
local p = require('searchlight')
local view = require('searchlight.view')
local rg = require('searchlight.rg')

local function displayed(s)
  view.render(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local context, matches = {}, {}
  for row, line in ipairs(lines) do
    if line:match('^      %s*%d+ | ') then
      assert(not s.result_rows[row], 'context must not be an actionable match')
      table.insert(context, line:match(' | (.*)$'))
    elseif s.result_rows[row] then
      table.insert(matches, line:match(' | (.*)$'))
    end
  end
  return context, matches
end

local function edit(s, value)
  local heading = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]
  heading = heading:gsub('↕%[[^%]]*%]', function()
    return '↕[' .. value .. ']'
  end)
  vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = s.buf })
  return heading
end

H.test(
  'context size controls real ripgrep output above and below without adding matches',
  'Q-10,R-01',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'far above\nabove two\nabove one\nabc\nbelow one\nbelow two\nfar below')
    local s = H.search(a)
    H.eq(s.options.context, 2)
    assert(vim.tbl_contains(rg.match(s), '--context=2'))
    H.eq(displayed(s), { 'above two', 'above one', 'below one', 'below two' })
    H.eq(#s.results, 1)
    H.eq(s.snapshots[a .. '/one'].context_lines, {
      [2] = 'above two',
      [3] = 'above one',
      [5] = 'below one',
      [6] = 'below two',
    })
    local id = s.results[1].id
    p.action(s, 'exclude')
    s.config.max_results = 1
    for _, size in ipairs({ 0, 1, 20 }) do
      H.update(s, { context = size })
      assert(vim.tbl_contains(rg.match(s), '--context=' .. size))
      H.eq(#s.results, 1)
      H.eq(s.results[1].id, id)
      H.eq(s.results[1].enabled, false)
      H.eq(s.incomplete, false)
      H.eq(displayed(s), size == 0 and {} or size == 1 and { 'above one', 'below one' } or {
        'far above',
        'above two',
        'above one',
        'below one',
        'below two',
        'far below',
      })
    end
  end
)

H.test(
  'overlapping context is shown once and file boundaries retain individual occurrences',
  'Q-10,R-01,R-03',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\nshared above\nabc\nshared below\ntail\n')
    H.write(a .. '/two', 'head\nabc\n')
    local s = H.replace(a)
    local context, matches = displayed(s)
    H.eq(context, { 'shared above', 'shared below', 'tail', 'head' })
    H.eq(matches, { 'abc abc', 'abc', 'abc' })
    H.eq(#s.results, 4)
    p.navigate(s, 1)
    view.render(s)
    H.eq(s.result_rows[vim.api.nvim_win_get_cursor(0)[1]], s.selected)
    H.eq(p.action(s, 'replace_next').applied, 1)
    H.eq(H.lines(a .. '/one'), { 'abc X', 'shared above', 'abc', 'shared below', 'tail' })
    H.wait(s, 'complete')
  end
)

H.test(
  'context comes from unsaved snapshots in project and only-open searches',
  'Q-10,B-01,B-02',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'disk above\nabc\ndisk below\n')
    H.buffer(a .. '/one', { '雪 above', '', 'abc', 'unsaved below', 'last' })
    local s = H.search(a)
    for _, open in ipairs({ false, true }) do
      H.update(s, { open = open })
      H.eq(displayed(s), { '雪 above', '', 'unsaved below', 'last' })
      H.eq(#s.results, 1)
      H.eq(s.results[1].line, 3)
    end
  end
)

H.test(
  'editing context waits for refresh and preserves invalid and incomplete text',
  'Q-10,Q-09,S-02',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'above\nabc\nbelow\n')
    local s, other = H.replace(a), H.replace(a)
    local other_generation = other.generation
    p.recent(s.id)
    p.action(s, 'section', 'replace')
    p.action(s, 'section', 'filters')
    local generation = s.generation
    edit(s, '0')
    assert(s.generation > generation)
    H.eq(s.status, 'stale')
    H.eq(s.timer, nil)
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(s.options.context, 0)
    H.eq(displayed(s), {})
    H.eq(other.generation, other_generation)
    H.eq(other.options.context, 2)
    generation = s.generation
    for _, value in ipairs({ '', ' ', '-1', '1.5', 'abc', '1e2', '00', ' 0 ' }) do
      local heading = edit(s, value)
      view.render(s)
      H.eq(s.options.context, 0)
      H.eq(s.generation, generation)
      H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
    end
    local heading = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:gsub('↕%[[^%]]*%]', '↕[3')
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
    view.render(s)
    H.eq(s.generation, generation)
    H.eq(s.options.context, 0)
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
    H.eq(s.fields.query, 'abc')
    p.action(s, 'section', 'help')
    assert(
      table
        .concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
        :find('↕  Edit brackets', 1, true)
    )
  end
)

H.test('native undo restores context for the next explicit refresh', 'Q-10,Q-09', function()
  local a = H.fixture()
  H.write(a .. '/one', 'above\nabc\nbelow\n')
  local s = H.search(a)
  vim.api.nvim_buf_call(s.buf, function()
    vim.cmd('let &undolevels = &undolevels')
  end)
  edit(s, '0')
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(displayed(s), {})
  local generation = s.generation
  vim.api.nvim_buf_call(s.buf, function()
    vim.cmd('silent undo')
  end)
  assert(vim.wait(1000, function()
    return s.generation > generation
  end, 5))
  H.eq(s.status, 'stale')
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(s.options.context, 2)
  H.eq(displayed(s), { 'above', 'below' })
end)

H.test(
  'context defaults configure new sessions and reject invalid numeric API values',
  'Q-10,Q-08',
  function()
    local a = H.fixture()
    local before = vim.deepcopy(p.config)
    local ok, err = xpcall(function()
      local existing = p.search(a)
      p.setup({ context_size = 0 })
      local s = p.search(a)
      H.eq(s.options.context, 0)
      assert(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:find('↕[0]', 1, true))
      p.setup({ context_size = 3 })
      H.eq(p.search(a).options.context, 3)
      H.eq(existing.options.context, 2)
      H.eq(s.options.context, 0)
      for _, value in ipairs({ -1, 1.5, '2', true, math.huge, 0 / 0 }) do
        H.eq(pcall(p.setup, { context_size = value }), false)
        H.eq(pcall(p.set, s, { context = value }), false)
      end
      p.set(s, { context = 4 })
      H.eq(s.options.context, 4)
      H.eq(s.status, 'empty')
      H.eq(next(s.jobs), nil)
    end, debug.traceback)
    p.config = before
    if not ok then
      error(err)
    end
  end
)
