local H = require('tests.helpers')
local p = require('searchlight')

local function with_search_state(run)
  local pattern, active, enabled = vim.fn.getreg('/'), vim.v.hlsearch, vim.o.hlsearch
  local ok, err = xpcall(run, debug.traceback)
  vim.fn.setreg('/', pattern)
  vim.o.hlsearch = enabled
  vim.v.hlsearch = active
  if not ok then
    error(err)
  end
end

local function attribute(win, row, col)
  local position = vim.fn.screenpos(win, row, col + 1)
  assert(position.row > 0 and position.col > 0, 'test text is off screen')
  return vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)[2]
end

H.test('returning from a native source search preserves panel highlights', 'R-09', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one.unsupported', 'alpha beta alpha\n')
    local s = H.search(a, { query = 'alpha', context = 0 })
    local result = s.results[1]
    p.navigate(s, 0)
    vim.cmd('normal! zt')
    vim.cmd('redraw!')
    local panel_win = vim.api.nvim_get_current_win()
    local position = s.result_positions[s.results[1].id]
    local selected = attribute(panel_win, position.row, position.col)
    local unselected = attribute(panel_win, position.row, position.col + #'alpha beta ')
    local normal = attribute(panel_win, position.row, position.col + #'alpha ')
    assert(not vim.deep_equal(selected, normal), 'selected match is not highlighted initially')
    assert(not vim.deep_equal(unselected, normal), 'other match is not highlighted initially')
    p.open(s)
    vim.cmd('silent normal! /beta\r')
    vim.wait(30)
    H.eq(vim.fn.getreg('/'), 'beta')
    vim.api.nvim_set_current_win(panel_win)
    vim.wait(30)
    vim.cmd('redraw!')
    -- Loading the source can mark the old snapshot stale and change its gutter.
    position = s.result_positions[result.id]
    H.eq(
      attribute(panel_win, position.row, position.col),
      selected,
      'selected panel highlight disappeared after the source search'
    )
    H.eq(
      attribute(panel_win, position.row, position.col + #'alpha beta '),
      unselected,
      'unselected panel highlight disappeared after the source search'
    )
    H.eq(
      attribute(panel_win, position.row, position.col + #'alpha '),
      normal,
      'source search leaked into the panel'
    )
    H.eq(vim.fn.getreg('/'), 'beta')
    for _, command in ipairs({ 'nohlsearch', 'set nohlsearch' }) do
      vim.cmd(command)
      vim.cmd('redraw!')
      H.eq(
        attribute(panel_win, position.row, position.col),
        selected,
        'clearing native highlighting cleared the selected panel match'
      )
      H.eq(
        attribute(panel_win, position.row, position.col + #'alpha beta '),
        unselected,
        'clearing native highlighting cleared other panel matches'
      )
    end
    vim.cmd('normal n')
    vim.wait(30)
    vim.cmd('redraw!')
    position = s.result_positions[result.id]
    H.eq(attribute(panel_win, position.row, position.col), unselected)
    H.eq(attribute(panel_win, position.row, position.col + #'alpha beta '), selected)
    vim.cmd('normal N')
    vim.wait(30)
    vim.cmd('redraw!')
    position = s.result_positions[result.id]
    H.eq(attribute(panel_win, position.row, position.col), selected)
    H.eq(attribute(panel_win, position.row, position.col + #'alpha beta '), unselected)
    H.eq(vim.fn.getreg('/'), 'beta')
  end)
end)

H.test(
  'changing the panel query removes highlights from the previous search',
  'Q-01,R-08',
  function()
    with_search_state(function()
      local a = H.fixture()
      H.write(a .. '/one.unsupported', 'function pending pending\nworker pending\n')
      local s = H.search(a, { query = 'function', context = 0 })
      p.open(s)
      p.focus(s.id)
      local region = s.regions.query
      vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'pending' })
      p.refresh(s)
      H.wait(s, 'complete')
      p.navigate(s, 0)
      vim.cmd('normal! zt')
      vim.cmd('redraw!')
      local win = vim.api.nvim_get_current_win()
      local position = s.result_positions[s.results[1].id]
      local normal = attribute(win, position.row, position.col - 1)
      assert(
        not vim.deep_equal(attribute(win, position.row, position.col), normal),
        'latest query is not highlighted'
      )
      H.eq(
        attribute(win, position.row, position.col - #'function '),
        normal,
        'previous query is still highlighted alongside the latest query'
      )
      assert(
        not vim.deep_equal(attribute(win, position.row, position.col + #'pending '), normal),
        'unselected matches are not highlighted'
      )
      H.eq(vim.fn.getreg('/'), '\\c\\Vfunction')
      H.eq(vim.v.hlsearch, 1)
      local _, source_win = p.open(s)
      vim.cmd('redraw!')
      H.eq(vim.fn.getreg('/'), '\\c\\Vpending')
      assert(
        not vim.deep_equal(attribute(source_win, 1, #'function '), attribute(source_win, 1, 0)),
        'opening the latest result did not highlight the source query'
      )
    end)
  end
)

H.test('native search highlights stay outside every panel window', 'R-08,S-05', function()
  with_search_state(function()
    local a = H.fixture()
    H.write(a .. '/one.unsupported', 'function pending pending\n')
    vim.fn.setreg('/', '\\Vfunction')
    vim.o.hlsearch, vim.v.hlsearch = true, 1
    local s = H.search(a, { query = 'pending', context = 0 })
    vim.cmd('split')
    H.eq(#vim.fn.win_findbuf(s.buf), 2)
    for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
      vim.api.nvim_win_call(win, function()
        p.navigate(s, 0)
        vim.cmd('normal! zt')
      end)
    end
    vim.cmd('redraw!')
    local position = s.result_positions[s.results[1].id]
    for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
      local normal = attribute(win, position.row, position.col - 1)
      H.eq(attribute(win, position.row, position.col - #'function '), normal)
      assert(not vim.deep_equal(attribute(win, position.row, position.col), normal))
    end
    H.eq(vim.fn.getreg('/'), '\\Vfunction')
    H.eq(vim.v.hlsearch, 1)
  end)
end)

H.test('leaving a panel restores the window highlight namespace', 'S-05', function()
  with_search_state(function()
    local a = H.fixture()
    local win = vim.api.nvim_get_current_win()
    local original = vim.api.nvim_get_hl_ns({ winid = win })
    local colors = vim.api.nvim_create_namespace('searchlight_test_window_colors')
    vim.api.nvim_win_set_hl_ns(win, colors)
    local ok, err = xpcall(function()
      local s = p.new(a)
      -- New may split an existing editor; reuse its panel window for the check.
      local panel_win = vim.api.nvim_get_current_win()
      local source = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(panel_win, source)
      vim.api.nvim_win_set_hl_ns(panel_win, colors)
      vim.api.nvim_win_set_buf(panel_win, s.buf)
      assert(vim.api.nvim_get_hl_ns({ winid = panel_win }) ~= colors)
      vim.api.nvim_win_set_buf(panel_win, source)
      H.eq(vim.api.nvim_get_hl_ns({ winid = panel_win }), colors)
      vim.api.nvim_win_set_buf(panel_win, s.buf)
      p.close(s)
      H.eq(vim.api.nvim_get_hl_ns({ winid = panel_win }), colors)
    end, debug.traceback)
    vim.api.nvim_win_set_hl_ns(win, original)
    if not ok then
      error(err)
    end
  end)
end)
