local H = require('tests.helpers')
local p = require('searchlight')
local view = require('searchlight.view')

local function with_scroll_options(run)
  local globals, windows = {}, {}
  for _, option in ipairs({ 'scrolloff', 'sidescrolloff' }) do
    globals[option] = vim.go[option]
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    windows[win] = { scrolloff = vim.wo[win].scrolloff, sidescrolloff = vim.wo[win].sidescrolloff }
  end
  local ok, err = xpcall(run, debug.traceback)
  for option, value in pairs(globals) do
    vim.go[option] = value
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    for option in pairs(globals) do
      vim.wo[win][option] = windows[win] and windows[win][option] or -1
    end
  end
  if not ok then
    error(err)
  end
end

local function panel()
  local a = H.fixture()
  -- Wide characters and tabs distinguish screen columns from byte offsets.
  local line = string.rep('雪\t', 20)
    .. 'abc'
    .. string.rep('x', 100)
    .. 'abc'
    .. string.rep('x', 100)
  H.write(a .. '/one', string.rep(line .. '\n', 100))
  local s = H.search(a, { query = 'abc', context = 0 })
  vim.api.nvim_win_set_height(0, 12)
  p.navigate(s, 80)
  return s
end

local function assert_margins(above, beside)
  vim.cmd('redraw!')
  local row, col = vim.fn.winline(), vim.fn.wincol()
  local height, width = vim.api.nvim_win_get_height(0), vim.api.nvim_win_get_width(0)
  assert(row > above and row <= height - above, 'vertical scroll margin was lost')
  assert(col > beside and col <= width - beside, 'horizontal scroll margin was lost')
end

H.test('panel movement and refresh respect scrolloff and sidescrolloff', 'R-01,R-08', function()
  with_scroll_options(function()
    vim.opt.scrolloff = 3
    vim.opt.sidescrolloff = 8
    local s = panel()
    assert_margins(3, 8)
    for _, keys in ipairs({ '6j', '6k', '50l', '50h', 'n', 'N', ']', '[' }) do
      vim.cmd('normal ' .. keys)
      vim.wait(20)
      assert_margins(3, 8)
      view.render(s)
      assert_margins(3, 8)
    end
    p.action(s, 'section', 'filters')
    assert_margins(3, 8)
    p.refresh(s)
    H.wait(s, 'complete')
    assert_margins(3, 8)
    p.action(s, 'hide')
    p.focus(s.id)
    assert_margins(3, 8)
  end)
end)

H.test('panels follow changed global scroll margins and retain local overrides', 'S-03,R-01', function()
  with_scroll_options(function()
    vim.opt.scrolloff = 2
    vim.opt.sidescrolloff = 4
    local s = panel()
    assert_margins(2, 4)
    -- Unset local values continue to use global settings after the panel is created.
    vim.opt_local.scrolloff = -1
    vim.opt_local.sidescrolloff = -1
    vim.opt_global.scrolloff = 4
    vim.opt_global.sidescrolloff = 12
    p.navigate(s, 20)
    assert_margins(4, 12)
    vim.opt_local.scrolloff = 999
    vim.opt_local.sidescrolloff = 999
    p.focus(s.id)
    p.navigate(s, 1)
    view.render(s)
    vim.cmd('redraw!')
    H.eq(vim.wo.scrolloff, 999)
    H.eq(vim.wo.sidescrolloff, 999)
    local middle = math.floor(vim.api.nvim_win_get_height(0) / 2) + 1
    assert(math.abs(vim.fn.winline() - middle) <= 1, 'large scrolloff did not center the cursor')
    local center = math.floor(vim.api.nvim_win_get_width(0) / 2) + 1
    assert(math.abs(vim.fn.wincol() - center) <= 1, 'large sidescrolloff did not center the cursor')
  end)
end)

H.test('result scrolling matches a normal buffer at buffer and line boundaries', 'R-01', function()
  with_scroll_options(function()
    vim.opt.scrolloff = 5
    vim.opt.sidescrolloff = 5
    local s = panel()
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    local options = {}
    for _, name in ipairs({
      'wrap',
      'number',
      'relativenumber',
      'signcolumn',
      'foldmethod',
      'virtualedit',
      'scrolloff',
      'sidescrolloff',
    }) do
      options[name] = vim.wo[name]
    end
    local function snapshot()
      vim.cmd('redraw!')
      return {
        cursor = vim.api.nvim_win_get_cursor(0),
        row = vim.fn.winline(),
        col = vim.fn.wincol(),
        view = vim.fn.winsaveview(),
      }
    end
    local initial, expected = snapshot(), {}
    local motions = { '6j', '6k', '50l', '50h', 'G', 'gg', '0', '$' }
    for _, keys in ipairs(motions) do
      vim.cmd('normal! ' .. keys)
      view.render(s)
      expected[keys] = snapshot()
    end
    -- Native scrolloff does not add blank rows beyond the last buffer line.
    H.eq(expected.G.row, vim.api.nvim_win_get_height(0))
    H.eq(expected.gg.row, 1)
    H.eq(expected['0'].col, 1)

    local native = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(native, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, native)
    for name, value in pairs(options) do
      vim.wo[name] = value
    end
    vim.fn.winrestview(initial.view)
    for _, keys in ipairs(motions) do
      vim.cmd('normal! ' .. keys)
      H.eq(
        snapshot(),
        expected[keys],
        'panel scrolling differs from a normal buffer after ' .. keys
      )
    end
  end)
end)
