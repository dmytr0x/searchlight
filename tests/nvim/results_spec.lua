local H = require('tests.helpers')
local p = require('searchlight')
local view = require('searchlight.view')

local function result_lines(s)
  view.render(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  for row, line in ipairs(lines) do
    if line:match('^%[Results%]  %d+/%d+$') then
      return vim.list_slice(lines, row + 1)
    end
  end
end

local function header(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  H.eq(lines[s.regions.exclude.stop + 1], '')
  return lines[s.regions.exclude.stop + 2]
end

H.test('green circle markers follow the cursor without shifting source columns', 'R-01', function()
  local a = H.fixture()
  H.write(a .. '/one', 'above\n雪 abc abc\nabc\nbelow\n')
  local s = H.search(a)
  view.render(s)
  local namespace = vim.api.nvim_create_namespace('searchlight_cursor_marker')
  local function filled()
    return vim.api.nvim_buf_get_extmarks(s.buf, namespace, 0, -1, { details = true })
  end
  H.eq(filled(), {})
  H.eq(vim.api.nvim_get_hl(0, { name = 'SearchlightMarker' }).link, 'DiagnosticOk')
  H.eq(vim.api.nvim_get_hl(0, { name = 'SearchlightControl' }).link, 'Title')
  H.eq(vim.api.nvim_get_hl(0, { name = 'SearchlightFilename' }).fg, 0xffff00)
  H.eq(vim.api.nvim_get_hl(0, { name = 'SearchlightPath' }).fg, 0xffffff)
  local positions = vim.deepcopy(s.result_positions)
  for _, index in ipairs({ 1, 2, 3 }) do
    local position = positions[s.results[index].id]
    vim.api.nvim_win_set_cursor(0, { position.row, position.col })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.buf })
    H.eq(#filled(), 1)
    H.eq(filled()[1][2], position.row - 1)
    H.eq(filled()[1][3], 2)
    H.eq(filled()[1][4].virt_text, { { '●', 'SearchlightMarker' } })
    local line = vim.api.nvim_buf_get_lines(s.buf, position.row - 1, position.row, false)[1]
    H.eq(line:sub(position.col + 1, position.stop), 'abc')
    H.eq(line:sub(3, 2 + #'○'), '○')
  end
  view.render(s)
  H.eq(s.result_positions, positions)
  local mapped = {}
  for _, code in ipairs(H.code_rows(s)) do
    local line = vim.api.nvim_buf_get_lines(s.buf, code.row, code.row + 1, false)[1]
    mapped[code.line] =
      { col = code.col, display_col = vim.fn.strdisplaywidth(line:sub(1, code.col)) }
  end
  H.eq(mapped[1].display_col, mapped[2].display_col)
  H.eq(mapped[2].col, positions[s.results[1].id].col - #'雪 ')
  p.navigate(s, -1)
  H.eq(filled()[1][2], s.result_positions[s.selected].row - 1)
  vim.api.nvim_win_set_cursor(0, { s.file_headers[a .. '/one'], 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.buf })
  H.eq(filled(), {})
end)

H.test('match markers remain circles for excluded and stale results', 'R-01,R-06', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  local s = H.search(a)
  local function circles()
    H.eq(result_lines(s), { '▾ one', '> ○   1 | abc abc' })
    H.eq(s.result_markers[s.result_positions[s.selected].row], 2)
  end
  p.navigate(s, 0)
  p.action(s, 'exclude')
  circles()
  p.navigate(s, 1)
  p.action(s, 'exclude')
  circles()
  p.action(s, 'exclude')
  local buf = p.open(s)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc changed' })
  assert(vim.wait(1000, function()
    return s.status == 'stale'
  end, 5))
  circles()
  H.eq(s.results[1].enabled, false)
  H.eq(s.results[2].stale, true)
  local report, err = p.action(s, 'replace_all')
  H.eq(report, nil)
  assert(err:find('refresh', 1, true), err)
  H.eq(H.lines(a .. '/one'), { 'abc changed' })
end)

H.test('compact results header tracks individual occurrences and empty searches', 'R-01', function()
  local a = H.fixture()
  local s = p.new(a)
  H.eq(header(s), '[Results]  0/0')
  H.write(a .. '/one', 'abc abc\nabc\n')
  H.update(s, { query = 'abc' })
  view.render(s)
  H.eq(header(s), '[Results]  1/3')
  local text = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
  for _, removed in ipairs({ 'Searchlight #', 'Root:', 'Status:', 'Preview:' }) do
    assert(not text:find(removed, 1, true))
  end
  p.navigate(s, 1)
  H.eq(header(s), '[Results]  2/3')
  local position = s.result_positions[s.results[3].id]
  vim.api.nvim_win_set_cursor(0, { position.row, position.col })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.buf })
  assert(vim.wait(1000, function()
    return header(s) == '[Results]  3/3'
  end, 5))
  H.update(s, { query = 'missing' })
  view.render(s)
  H.eq(header(s), '[Results]  0/0')
  vim.cmd('normal nN')
  H.eq(header(s), '[Results]  0/0')
end)

H.test('n and N support counts and wrapscan and stay panel-local', 'R-01,S-05', function()
  local a = H.fixture()
  H.write(a .. '/one', '雪 abc abc\n')
  H.write(a .. '/two', 'abc\n')
  local s = H.search(a)
  local original = vim.o.wrapscan
  local ok, err = xpcall(function()
    vim.o.wrapscan = true
    for _, key in ipairs({ 'n', 'N' }) do
      H.eq(vim.fn.maparg(key, 'n', false, true).buffer, 1)
    end
    local function selected(index)
      H.eq(s.selected, s.results[index].id)
      local position = s.result_positions[s.selected]
      H.eq(vim.api.nvim_win_get_cursor(0), { position.row, position.col })
      H.eq(header(s), string.format('[Results]  %d/3', index))
    end
    -- Searching from the input block reaches the first result.
    vim.cmd('normal n')
    selected(1)
    vim.cmd('normal n')
    selected(2)
    vim.cmd('normal N')
    selected(1)
    vim.cmd('normal 2n')
    selected(3)
    vim.cmd('normal n')
    selected(1)
    vim.cmd('normal N')
    selected(3)
    vim.o.wrapscan = false
    vim.cmd('normal n')
    selected(3)
    -- Text between hits uses cursor position, as native search does.
    local position = s.result_positions[s.results[2].id]
    vim.api.nvim_win_set_cursor(0, { position.row, position.stop })
    vim.cmd('normal N')
    selected(2)
    vim.api.nvim_win_set_cursor(0, { position.row, s.result_positions[s.results[1].id].stop })
    vim.cmd('normal n')
    selected(2)
    vim.cmd('normal n')
    selected(3)
    vim.cmd('normal 2N')
    selected(1)
    vim.cmd('normal N')
    selected(1)
    -- Follow a manually moved cursor, including another hit on the same source line.
    vim.api.nvim_win_set_cursor(0, { position.row, position.col })
    vim.cmd('normal n')
    selected(3)
    s.collapsed_paths[a .. '/one'] = true
    view.render(s)
    vim.cmd('normal N')
    selected(2)
    H.eq(s.collapsed_paths[a .. '/one'], nil)
    p.open(s)
    H.eq(vim.fn.maparg('n', 'n', false, true), {})
    H.eq(vim.fn.maparg('N', 'n', false, true), {})
  end, debug.traceback)
  vim.o.wrapscan = original
  if not ok then
    error(err)
  end
end)

H.test(
  'file headers own paths and distinct context blocks share one file group',
  'R-01,Q-10',
  function()
    local a = H.fixture()
    H.write(
      a .. '/src/one.lua',
      'above\nabc abc\nbelow\nskipped\nskipped\nabove again\nabc\nbelow again\n'
    )
    H.write(a .. '/tests/one.lua', 'abc\n')
    local s = H.search(a, { query = 'abc', context = 1 })
    H.eq(result_lines(s), {
      '▾ one.lua  src/',
      '      1 | above',
      '> ○   2 | abc abc',
      '      3 | below',
      '      ⋯',
      '      6 | above again',
      '  ○   7 | abc',
      '      8 | below again',
      '',
      '▾ one.lua  tests/',
      '  ○   1 | abc',
    })
    H.eq(#s.results, 4)
    H.eq(vim.tbl_count(s.file_rows), 2)
    H.eq(vim.tbl_count(s.result_rows), 3)
    local marks = view.decorations(s)
    local highlighted, filenames, paths = {}, {}, {}
    for _, mark in ipairs(marks) do
      local details = mark[4]
      local line = vim.api.nvim_buf_get_lines(s.buf, mark[2], mark[2] + 1, false)[1]
      if details.hl_group == 'SearchlightMatch' or details.hl_group == 'SearchlightSelected' then
        table.insert(highlighted, line:sub(mark[3] + 1, details.end_col))
      elseif details.hl_group == 'SearchlightFilename' then
        table.insert(filenames, line:sub(mark[3] + 1, details.end_col))
      elseif details.hl_group == 'SearchlightPath' then
        table.insert(paths, line:sub(mark[3] + 1, details.end_col))
      end
    end
    H.eq(highlighted, { 'abc', 'abc', 'abc', 'abc' })
    H.eq(filenames, { '▾ one.lua', '▾ one.lua' })
    H.eq(paths, { 'src/', 'tests/' })
    -- Process callbacks can interleave files before the generation settles.
    s.results = { s.results[4], s.results[2], s.results[3], s.results[1] }
    H.eq(result_lines(s)[1], '▾ one.lua  src/')
    H.eq(vim.tbl_count(s.file_rows), 2)
    H.eq(vim.tbl_count(s.result_rows), 3)
  end
)

H.test(
  'shared code rows keep byte-accurate occurrence actions and selection',
  'R-01,R-03,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', '雪 abc abc\n')
    local s = H.search(a)
    view.render(s)
    local first, second = s.results[1], s.results[2]
    local position = s.result_positions[second.id]
    H.eq(position.row, s.result_positions[first.id].row)
    vim.api.nvim_win_set_cursor(0, { position.row, position.col + 1 })
    p.action(s, 'exclude')
    H.eq(s.selected, second.id)
    H.eq(first.enabled, true)
    H.eq(second.enabled, false)
    H.eq(result_lines(s), { '▾ one', '> ○   1 | 雪 abc abc' })
    position = s.result_positions[second.id]
    H.eq(vim.api.nvim_win_get_cursor(0), { position.row, position.col + 1 })
    p.refresh(s)
    H.wait(s, 'complete')
    view.render(s)
    H.eq(s.results[2].enabled, false)
    H.eq(vim.api.nvim_win_get_cursor(0), { position.row, position.col + 1 })
    p.navigate(s, -1)
    local cursor = vim.api.nvim_win_get_cursor(0)
    H.eq(cursor, { position.row, s.result_positions[first.id].col })
    p.navigate(s, 1)
    H.eq(vim.api.nvim_win_get_cursor(0), { position.row, position.col })
    local _, win = p.action(s, 'open')
    H.eq(vim.api.nvim_win_get_cursor(win), { 1, second.start })
    p.focus(s.id)
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(p.action(s, 'replace_all').applied, 1)
    H.eq(H.lines(a .. '/one'), { '雪 X abc' })
    H.wait(s, 'complete')
  end
)

H.test(
  'file collapse persists through redraw and refresh and navigation reveals matches',
  'R-01,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    H.write(a .. '/two', 'abc\n')
    local s = H.search(a)
    view.render(s)
    local generation = s.generation
    vim.api.nvim_win_set_cursor(0, { s.file_headers[a .. '/one'], 0 })
    p.action(s, 'open')
    H.eq(s.generation, generation)
    H.eq(result_lines(s), { '▸ one', '', '▾ two', '  ○   1 | abc' })
    H.eq(#s.results, 3)
    H.eq(s.result_positions[s.results[1].id], nil)
    H.eq(vim.api.nvim_win_get_cursor(0)[1], s.file_headers[a .. '/one'])
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(result_lines(s)[1], '▸ one')
    p.navigate(s, 1)
    H.eq(s.selected, s.results[2].id)
    H.eq(result_lines(s)[1], '▾ one')
    local position = s.result_positions[s.selected]
    H.eq(vim.api.nvim_win_get_cursor(0), { position.row, position.col })
    vim.api.nvim_win_set_cursor(0, { s.file_headers[a .. '/one'], 0 })
    p.action(s, 'open')
    p.action(s, 'open')
    H.eq(result_lines(s)[1], '▾ one')
    p.action(s, 'open')
    H.eq(p.action(s, 'replace_all').applied, 3)
    H.eq(H.lines(a .. '/one'), { 'X X' })
    H.eq(H.lines(a .. '/two'), { 'X' })
    H.wait(s, 'complete')
  end
)

H.test(
  'zero-width occurrences share a line and remain individually actionable',
  'R-01,R-03,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'ab\n')
    local s = H.search(a, { query = '\\b', regex = true, replacement = 'X', context = 0 })
    view.render(s)
    H.eq(#s.results, 2)
    H.eq(vim.tbl_count(s.result_rows), 1)
    p.navigate(s, 1)
    local position = s.result_positions[s.selected]
    H.eq(vim.api.nvim_win_get_cursor(0), { position.row, position.col })
    p.action(s, 'exclude')
    H.eq(s.results[1].enabled, true)
    H.eq(s.results[2].enabled, false)
    H.eq(p.action(s, 'replace_all').applied, 1)
    H.eq(H.lines(a .. '/one'), { 'Xab' })
    H.wait(s, 'complete')
  end
)

H.test('selection patches match a full render across 10,000 results', 'R-01', function()
  local a = H.fixture()
  for i = 1, 200 do
    H.write(a .. string.format('/file%03d', i), string.rep('abc = ' .. i .. ' -- abc\n', 25))
  end
  local s = H.search(a, { query = 'abc', context = 0 })
  H.eq(#s.results, 10000)
  view.render(s)
  local render, renders = view.render, 0
  view.render = function(...)
    renders = renders + 1
    return render(...)
  end
  local ok, err = xpcall(function()
    local undo = vim.fn.undotree(s.buf).seq_last
    local function matches_full_render()
      local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
      local rows = vim.deepcopy(s.result_rows)
      render(s)
      H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), lines)
      H.eq(s.result_rows, rows)
    end
    for step = 1, 60 do
      if step % 3 == 0 then
        p.navigate(s, 7)
      elseif step % 3 == 1 then
        p.navigate(s, -3)
      else
        local position = s.result_positions[s.results[(step * 137) % 10000 + 1].id]
        vim.api.nvim_win_set_cursor(0, { position.row, position.col })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.buf })
      end
      -- Odd steps stack two patches before comparing.
      if step % 2 == 0 then
        matches_full_render()
      end
    end
    p.navigate(s, 10000)
    matches_full_render()
    p.navigate(s, 1, true)
    H.eq(s.selected, s.results[1].id)
    matches_full_render()
    H.eq(renders, 0)
    H.eq(vim.fn.undotree(s.buf).seq_last, undo)
    -- The decoration provider, not stored extmarks, colors the selected match.
    p.navigate(s, 1)
    vim.cmd('normal! zz')
    vim.cmd('redraw!')
    local win = vim.api.nvim_get_current_win()
    local function attribute(row, col)
      local screen = vim.fn.screenpos(win, row, col + 1)
      return vim.api.nvim__inspect_cell(1, screen.row - 1, screen.col - 1)[2]
    end
    local first, second = unpack(s.result_occurrences[s.result_positions[s.selected].row])
    H.eq(second.id, s.selected)
    local selected, other = attribute(second.row, second.col), attribute(first.row, first.col)
    local plain = attribute(first.row, first.stop + 1)
    assert(not vim.deep_equal(selected, other), 'selected match is not distinct')
    assert(not vim.deep_equal(other, plain), 'match is not highlighted')
  end, debug.traceback)
  view.render = render
  if not ok then
    error(err)
  end
end)

H.test('panel colors follow the colorscheme and keep user overrides', 'R-01', function()
  local background = vim.o.background
  local ok, err = xpcall(function()
    vim.cmd('set background=light | colorscheme default')
    local function fg(name)
      return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
    end
    H.eq(fg('SearchlightFilename'), 0xffff00)
    H.eq(fg('SearchlightPath'), 0xffffff)
    H.eq(fg('SearchlightControl'), fg('Title'))
    H.eq(fg('SearchlightMarker'), fg('DiagnosticOk'))
    vim.cmd('highlight SearchlightPath guifg=#ff0000')
    p.setup()
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    H.eq(fg('SearchlightPath'), 0xff0000)
    local a = H.fixture()
    H.write(a .. '/src/one.lua', 'abc\n')
    local s = H.search(a)
    vim.cmd('redraw!')
    local win = vim.api.nvim_get_current_win()
    local filename, path
    for _, mark in ipairs(view.decorations(s)) do
      if mark[4].hl_group == 'SearchlightFilename' then
        filename = mark
      elseif mark[4].hl_group == 'SearchlightPath' then
        path = mark
      end
    end
    assert(filename, 'filename decoration missing')
    local name_screen = vim.fn.screenpos(win, filename[2] + 1, #'▾ ' + 1)
    assert(name_screen.row > 0, 'filename is off screen')
    local name_cell = vim.api.nvim__inspect_cell(1, name_screen.row - 1, name_screen.col - 1)
    H.eq(name_cell[1], 'o')
    H.eq(name_cell[2].foreground, 0xffff00)
    assert(path, 'path decoration missing')
    local screen = vim.fn.screenpos(win, path[2] + 1, path[3] + 1)
    assert(screen.row > 0, 'path is off screen')
    local cell = vim.api.nvim__inspect_cell(1, screen.row - 1, screen.col - 1)
    H.eq(cell[1], 's')
    H.eq(cell[2].foreground, 0xff0000)
  end, debug.traceback)
  vim.cmd('highlight clear SearchlightPath')
  vim.o.background = background
  vim.cmd('colorscheme default')
  if not ok then
    error(err)
  end
end)
