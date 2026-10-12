local H = require('tests.helpers')
local p = require('searchlight')
local view = require('searchlight.view')
H.test(
  'grouped inputs keep editable regions and compact search controls together',
  'Q-01,Q-05,Q-09',
  function()
    local a = H.fixture()
    local s = p.new(a)
    p.set(s, {
      query = 'abc',
      replacement = '雪',
      include = { '*.lua', '*.txt' },
      exclude = { 'generated/**' },
    })
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    H.eq(vim.list_slice(lines, 1, 9), {
      '[Search]    Aa[ ]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]',
      'abc',
      '[Replace]',
      '雪',
      '[Include]',
      '*.lua',
      '*.txt',
      '[Exclude]',
      'generated/**',
    })
    local heading = lines[1]
    local controls = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.buf, view.namespace, 0, -1, { details = true })) do
      if mark[2] == 0 and mark[4].hl_group == 'SearchlightControl' then
        table.insert(controls, heading:sub(mark[3] + 1, mark[4].end_col))
      end
    end
    H.eq(controls, { 'Aa[ ]', 'wd[ ]', '.*[ ]', '󰥩[ ]', '[ ]', '↕[2]' })
    -- Each extmark region contains only editable text, never headers.
    for _, name in ipairs({ 'query', 'replacement', 'include', 'exclude' }) do
      local region = s.regions[name]
      local value = s.fields[name]
      H.eq(
        vim.api.nvim_buf_get_lines(s.buf, region.start, region.stop, false),
        type(value) == 'table' and value or { value }
      )
    end
    view.focus_field(s, 'include')
    vim.api.nvim_win_set_cursor(0, { s.regions.include.start + 2, 2 })
    local fields = vim.deepcopy(s.fields)
    for _, option in ipairs({ 'case', 'word', 'regex', 'open', 'ignored' }) do
      p.action(s, 'toggle', option)
    end
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), {
      '[Search]    Aa[x]  wd[x]  .*[x]  󰥩[x]  [x]  ↕[2]',
    })
    H.eq(s.fields, fields)
    H.eq(vim.api.nvim_win_get_cursor(0), { s.regions.include.start + 2, 2 })
    H.wait(s, 'complete')
  end
)
H.test(
  'search-only layout omits Replace and keeps help below the input block',
  'Q-06,Q-09',
  function()
    local a = H.fixture()
    local s = p.new(a)
    p.action(s, 'section', 'replace')
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    H.eq(vim.list_slice(lines, 1, 8), {
      '[Search]    Aa[ ]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]',
      '',
      '[Include]',
      '',
      '[Exclude]',
      '',
      '',
      '[Results]  0/0',
    })
    local text = table.concat(lines, '\n')
    assert(not text:find('Replace', 1, true))
    assert(not text:find('Preview:', 1, true))
    assert(not text:find('Policy:', 1, true))
    p.action(s, 'section', 'help')
    lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    text = table.concat(lines, '\n')
    assert(s.help_row > s.regions.exclude.stop)
    H.eq(vim.api.nvim_win_get_cursor(0)[1], s.help_row)
    H.eq(vim.fn.winsaveview().topline, s.help_row)
    for _, legend in ipairs({
      'Aa  ,c  Match case',
      'wd  ,w  Match whole words',
      '.*  ,x  Use regular expressions',
      '󰥩  ,o  Only search open files',
      '  ,g  Also search ignored files',
      ',n Replace next | ,A Replace all',
      ',q Hide | ,D Close',
    }) do
      assert(text:find(legend, 1, true), 'missing help: ' .. legend)
    end
    p.action(s, 'section', 'help')
    p.action(s, 'field', 'replacement')
    H.eq(s.sections.replace, true)
    H.eq(vim.api.nvim_win_get_cursor(0)[1], s.regions.replacement.start + 1)
  end
)
H.test(
  'root and limit prompts refresh only their owning panel and ignore late input after deletion',
  'Q-08,Async',
  function()
    local a, b = H.fixture()
    H.write(a .. '/one', 'abc\n')
    H.write(b .. '/two', 'abc abc\n')
    local s = H.search(a)
    local original = vim.ui.input
    local ok, err = xpcall(function()
      vim.ui.input = function(_, done)
        done(b)
      end
      p.action(s, 'root')
      H.wait(s, 'complete')
      H.eq(s.root, b)
      H.eq(#s.results, 2)
      vim.ui.input = function(_, done)
        done('1')
      end
      p.action(s, 'limit')
      H.wait(s, 'truncated')
      H.eq(s.config.max_results, 1)
      local callback
      vim.ui.input = function(_, done)
        callback = done
      end
      p.action(s, 'root')
      p.close(s)
      callback(a)
      H.eq(require('searchlight.sessions').get(s.id), nil)
    end, debug.traceback)
    vim.ui.input = original
    if not ok then
      error(err)
    end
  end
)
H.test(
  'cursor stays on the selected result after an unchanged async refresh',
  'R-01,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H.search(a)
    p.navigate(s, 1)
    local selected = s.selected
    p.refresh(s)
    H.wait(s, 'complete')
    view.render(s)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    H.eq(s.result_rows[row], selected)
  end
)
H.test(
  'refresh mapping rereads changed files and current inputs only for its owning session',
  'Q-01,Q-09,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc\n')
    H.write(a .. '/skip.lua', 'abc\n')
    H.write(a .. '/two.txt', 'abc\n')
    local s = H.search(a, {
      query = 'abc',
      include = { '*.lua' },
      exclude = { 'skip*' },
      case = true,
    })
    local other = H.search(a)
    local other_generation = other.generation
    p.focus(s.id)
    H.eq(#s.results, 1)

    -- External writes bypass Neovim's source-change autocmds.
    H.write(a .. '/one.lua', 'abc abc ABC\n')
    H.write(a .. '/new.lua', 'abc\n')
    H.eq(#s.results, 1)
    local generation = s.generation
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(',R', true, false, true), 'xt', false)
    assert(s.generation > generation)
    H.wait(s, 'complete')
    H.eq(#s.results, 3)
    for _, result in ipairs(s.results) do
      H.eq(result.stale, false)
      H.eq(result.match, 'abc')
    end
    H.eq(other.generation, other_generation)

    -- Invoke the mapping before scheduled redraws/debounce read these edits.
    local heading = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:gsub('Aa%[x%]', 'Aa[ ]')
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
    local region = s.regions.query
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'ABC' })
    region = s.regions.include
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { '*.txt' })
    vim.fn.maparg('<localleader>R', 'n', false, true).callback()
    H.eq(s.status, 'searching')
    H.eq(s.timer, nil)
    H.wait(s, 'complete')
    H.eq(s.fields.query, 'ABC')
    H.eq(s.options.case, false)
    H.eq(s.fields.include, { '*.txt' })
    H.eq(s.fields.exclude, { 'skip*' })
    H.eq(#s.results, 1)
    H.eq(s.results[1].path, a .. '/two.txt')
    H.eq(other.generation, other_generation)
  end
)
H.test(
  'normal Vim editing keys remain free and every panel action is buffer-local',
  'Q-01,S-05',
  function()
    local a = H.fixture()
    local s = p.new(a)
    for _, key in ipairs({ 'd', 'w', 'x', 'c', 'r', 'g', 'I' }) do
      H.eq(vim.fn.maparg(key, 'n', false, true), {})
    end
    for _, key in ipairs({
      'c',
      'w',
      'x',
      'o',
      'g',
      'f',
      'v',
      'n',
      'A',
      'R',
      'd',
      'L',
      'q',
      'D',
      '/',
      'r',
      'I',
      'E',
    }) do
      local map = vim.fn.maparg('<localleader>' .. key, 'n', false, true)
      H.eq(map.buffer, 1)
      assert(map.callback)
    end
    p.action(s, 'section', 'help')
    H.eq(vim.api.nvim_win_get_cursor(0)[1], s.help_row)
  end
)
H.test(
  'explicit refresh reads comma-separated multiline filters and preserves declaration lines',
  'Q-01,Q-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc\n')
    H.write(a .. '/two.txt', 'abc\n')
    H.write(a .. '/three.md', 'abc\n')
    H.write(a .. '/skip.lua', 'abc\n')
    local s = p.new(a)
    local region = s.regions.query
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'abc' })
    p.refresh(s)
    assert(vim.wait(5000, function()
      return s.status == 'complete'
    end, 5))
    H.eq(#s.results, 4)
    region = s.regions.include
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { '*.lua, *.txt', '*.py' })
    p.refresh(s)
    assert(vim.wait(5000, function()
      return s.status == 'complete' and #s.results == 3
    end, 5))
    region = s.regions.exclude
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'skip.*, *.md' })
    p.refresh(s)
    assert(vim.wait(5000, function()
      return s.status == 'complete' and #s.results == 2
    end, 5))
    H.eq(s.fields.include, { '*.lua, *.txt', '*.py' })
    H.eq(s.fields.exclude, { 'skip.*, *.md' })
    require('searchlight.view').render(s)
    region = s.regions.include
    H.eq(
      vim.api.nvim_buf_get_lines(s.buf, region.start, region.stop, false),
      { '*.lua, *.txt', '*.py' }
    )
  end
)
H.test('hidden sections retain effective values without invalidating results', 'Q-06', function()
  local a = H.fixture()
  H.write(a .. '/one.lua', 'abc\n')
  local s =
    H.search(a, { query = 'abc', replacement = 'X', include = { '*.lua' }, exclude = { 'skip*' } })
  local generation = s.generation
  p.action(s, 'section', 'filters')
  p.action(s, 'section', 'replace')
  H.eq(s.generation, generation)
  H.eq(s.fields.replacement, 'X')
  H.eq(s.fields.include, { '*.lua' })
  local text = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
  assert(text:find('active value: "X"', 1, true))
  assert(text:find('Include: *.lua', 1, true))
  H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 2, false), {
    '[Search]    Aa[ ]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]',
    'abc',
  })
  H.eq(s.regions.replacement, nil)
  H.eq(s.regions.include, nil)
  H.eq(s.regions.exclude, nil)
  p.action(s, 'section', 'filters')
  H.eq(
    vim.api.nvim_buf_get_lines(s.buf, s.regions.include.start, s.regions.include.stop, false),
    { '*.lua' }
  )
  p.action(s, 'field', 'replacement')
  H.eq(s.sections.replace, true)
end)
H.test('displayed result edits cannot mutate the source or model', 'R-07,R-08', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local s = H.search(a)
  local row = next(s.result_rows)
  vim.api.nvim_buf_set_lines(s.buf, row - 1, row, false, { 'forged result data' })
  assert(
    vim.wait(1000, function()
      return not s.render_pending and not s.layout_invalid
    end, 5),
    'result edit was not repaired by the deferred redraw'
  )
  assert(not table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n'):find('forged'))
  view.render(s)
  H.eq(s.results[1].match, 'abc')
  H.eq(H.read(a .. '/one'), 'abc\n')
  assert(not table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n'):find('forged'))
end)
H.test(
  'queued result repair preserves newly edited input and its extmarks',
  'Q-01,R-07,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H.search(a)
    local model = vim.deepcopy(s.results)
    local generation = s.generation
    local region = s.regions.query
    vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'abc', 'second line' })
    local cursor = { region.start + 2, 4 }
    vim.api.nvim_win_set_cursor(0, cursor)
    local ns = vim.api.nvim_create_namespace('searchlight_test_input')
    local anchor = vim.api.nvim_buf_set_extmark(s.buf, ns, cursor[1] - 1, cursor[2], {})
    -- These edits happen before the scheduled input synchronization and layout repair.
    local row = s.result_positions[s.selected].row + 1
    vim.api.nvim_buf_set_lines(s.buf, row - 1, row, false, { 'forged', 'extra result row' })
    vim.api.nvim_buf_set_lines(s.buf, row - 1, row, false, { 'another forged edit' })
    H.eq(s.layout_invalid, true)
    H.eq(s.generation, generation)
    assert(vim.wait(1000, function()
      return not s.render_pending and not s.layout_invalid
    end, 5))
    H.eq(s.fields.query, 'abc\nsecond line')
    H.eq(s.generation, generation + 1)
    H.eq(s.timer, nil)
    H.eq(vim.api.nvim_win_get_cursor(0), cursor)
    H.eq(vim.api.nvim_buf_get_extmark_by_id(s.buf, ns, anchor, {}), { cursor[1] - 1, cursor[2] })
    H.eq(vim.api.nvim_buf_get_lines(s.buf, s.regions.query.start, s.regions.query.stop, false), {
      'abc',
      'second line',
    })
    for _, result in ipairs(model) do
      result.stale = true
    end
    H.eq(s.results, model)
    local text = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
    assert(not text:find('forged', 1, true))
    assert(not text:find('extra result row', 1, true))
    H.eq(H.read(a .. '/one'), 'abc abc\n')
  end
)
H.test('field focus and selected result survive rendering and resizing', 'R-01,Q-01', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  local s = H.search(a, { query = 'abc', replacement = 'XX' })
  p.navigate(s, 1)
  local selected = s.selected
  view.focus_field(s, 'replacement')
  vim.api.nvim_win_set_cursor(0, { s.regions.replacement.start + 1, 1 })
  vim.cmd('vertical resize 30')
  view.render(s)
  H.eq(vim.api.nvim_win_get_cursor(0), { s.regions.replacement.start + 1, 1 })
  H.eq(s.selected, selected)
end)
H.test('query paste deletion and native panel undo remain editable', 'Q-01', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc xyz\n')
  local s = H.search(a)
  view.focus_field(s, 'query')
  vim.api.nvim_buf_call(s.buf, function()
    vim.cmd('let &undolevels = &undolevels')
  end)
  vim.api.nvim_buf_set_lines(s.buf, s.regions.query.start, s.regions.query.stop, false, { 'xyz' })
  p.refresh(s)
  assert(vim.wait(5000, function()
    return s.status == 'complete' and s.fields.query == 'xyz'
  end, 5))
  vim.api.nvim_buf_call(s.buf, function()
    vim.cmd('silent undo')
  end)
  assert(vim.wait(5000, function()
    return s.fields.query == 'abc'
  end, 5))
  H.eq(s.fields.query, 'abc')
end)
H.test('deleting a field boundary repairs labels and keeps valid input', 'Q-01,Q-06', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local s = H.search(a)
  local row = s.regions.query.start
  vim.api.nvim_buf_set_lines(s.buf, row, s.regions.replacement.start, false, { 'abc' })
  vim.wait(100)
  view.render(s)
  H.eq(s.fields.query, 'abc')
  assert(
    table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n'):find('[Replace]', 1, true)
  )
end)
