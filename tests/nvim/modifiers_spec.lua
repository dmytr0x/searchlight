local H = require('tests.helpers')
local p = require('searchlight')
local view = require('searchlight.view')

local function wait_for_edit(s, generation)
  assert(
    vim.wait(1000, function()
      return s.generation > generation
    end, 5),
    'modifier edit did not invalidate the search'
  )
  p.refresh(s)
  H.wait(s, 'complete')
end

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

H.test(
  'keyboard case edits and mappings enforce exact query case in matches and highlights',
  'Q-01,Q-02,Q-04,Q-09',
  function()
    local a = H.fixture()
    H.write(a .. '/one', '# Persistent search panel\nSearch SEARCH search\n')
    local s = p.search(a)
    local generation = s.generation
    keys('isearch<Esc>')
    wait_for_edit(s, generation)
    local source_buf
    local function matches(expected)
      local actual = {}
      for _, result in ipairs(s.results) do
        table.insert(actual, result.match)
        H.eq(result.stale, false)
        H.eq(result.generation, s.generation)
        H.eq(result.context:sub(result.start + 1, result.finish), result.match)
        if source_buf then
          H.eq(result.buf, source_buf, 'search did not use the unsaved buffer')
          if result.line == 1 then
            H.eq(result.context, '# Unsaved search panel')
          end
        end
        if s.options.case then
          H.eq(result.match, s.fields.query, 'case-sensitive search returned the wrong case')
        end
      end
      H.eq(actual, expected)
      -- Verify the visible highlight, rather than just the internal result count.
      local highlighted = {}
      local marks = view.decorations(s)
      for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        if
          (details.hl_group == 'SearchlightMatch' or details.hl_group == 'SearchlightSelected')
          and s.result_rows[row + 1]
        then
          local line = vim.api.nvim_buf_get_lines(s.buf, row, row + 1, false)[1]
          table.insert(highlighted, line:sub(col + 1, details.end_col))
        end
      end
      H.eq(highlighted, expected)
    end
    matches({ 'search', 'Search', 'SEARCH', 'search' })
    for _, source in ipairs({ 'disk', 'buffer' }) do
      if source == 'buffer' then
        source_buf = H.buffer(a .. '/one', { '# Unsaved search panel', 'Search SEARCH search' })
        p.refresh(s)
        H.wait(s, 'complete')
        p.recent(s.id)
      end
      for _, regex in ipairs({ false, true }) do
        if regex then
          generation = s.generation
          keys(',x')
          wait_for_edit(s, generation)
        end
        H.eq(s.options.regex, regex)
        generation = s.generation
        vim.api.nvim_win_set_cursor(0, { 1, #'[Search]    Aa[' })
        keys('rx')
        wait_for_edit(s, generation)
        H.eq(s.options.case, true)
        matches({ 'search', 'search' })
        for _, query in ipairs({ 'Search', 'SEARCH', 'search' }) do
          generation = s.generation
          keys(',/')
          keys('0C' .. query .. '<Esc>')
          wait_for_edit(s, generation)
          H.eq(s.fields.query, query)
          matches(query == 'search' and { 'search', 'search' } or { query })
        end
        generation = s.generation
        keys(',c')
        wait_for_edit(s, generation)
        H.eq(s.options.case, false)
        matches({ 'search', 'Search', 'SEARCH', 'search' })
      end
      generation = s.generation
      keys(',x')
      wait_for_edit(s, generation)
    end
  end
)

H.test(
  'every modifier applies on explicit refresh after editing or toggling in either direction',
  'Q-01,Q-09',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc ABC xabc axc\n')
    H.write(a .. '/closed', 'abc\n')
    H.write(a .. '/.hidden', 'abc\n')
    H.write(a .. '/.gitignore', '.hidden\n')
    H.buffer(a .. '/one')
    for _, control in ipairs({
      { label = 'Aa', option = 'case', query = 'abc', off = 4, on = 3 },
      { label = 'wd', option = 'word', query = 'abc', off = 4, on = 3 },
      { label = '.*', option = 'regex', query = 'a.c', off = 0, on = 5 },
      { label = '󰥩', option = 'open', query = 'abc', off = 4, on = 3 },
      { label = '', option = 'ignored', query = 'abc', off = 4, on = 5 },
    }) do
      local s = H.replace(a, { query = control.query })
      H.eq(#s.results, control.off, control.option)
      local other = H.replace(a, { query = control.query })
      local other_generation = other.generation
      p.recent(s.id)
      p.action(s, 'section', 'replace')
      p.action(s, 'section', 'filters')
      for _, method in ipairs({ 'edit', 'toggle' }) do
        for _, enabled in ipairs({ true, false }) do
          local generation = s.generation
          if method == 'edit' then
            local heading = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]
            heading = heading:gsub(vim.pesc(control.label) .. '%[[^%]]*%]', function()
              return control.label .. (enabled and '[x]' or '[]')
            end)
            vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
          else
            p.action(s, 'toggle', control.option)
          end
          wait_for_edit(s, generation)
          H.eq(s.options[control.option], enabled)
          H.eq(#s.results, enabled and control.on or control.off, control.option .. ' ' .. method)
          H.eq(other.generation, other_generation)
          H.eq(other.options[control.option], false)
        end
      end
    end
  end
)

H.test(
  'query text beginning with Search remains separate from the modifier heading',
  'Q-01,Q-09',
  function()
    local a = H.fixture()
    local s = p.search(a)
    p.set(s, { query = '[Search] text' })
    view.render(s)
    H.eq(s.fields.query, '[Search] text')
    H.wait(s, 'complete')
  end
)

H.test(
  'all search modifiers default to OFF and search literal punctuation',
  'Q-02,Q-04,Q-09',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'a.b axb A.B\n')
    local s = H.search(a, { query = 'a.b' })
    H.eq(
      s.options,
      { case = false, word = false, regex = false, open = false, ignored = false, context = 2 }
    )
    H.eq(#s.results, 2)
  end
)

H.test(
  'editing modifier brackets invalidates results and preserves text until refresh',
  'Q-02,Q-04,Q-09',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'a.b axb A.B\n')
    local s = H.search(a, { query = 'a.b', regex = false })
    local generation = s.generation
    local heading = '[Search]    Aa[yes]  wd[ ]  .*[x]  󰥩[ ]  [ ]  ↕[2]'
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, {
      heading,
    })
    vim.wait(50)
    assert(s.generation > generation, 'modifier edits did not invalidate the search')
    H.eq(s.status, 'stale')
    H.eq(s.timer, nil)
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(s.options.case, true)
    H.eq(s.options.regex, true)
    H.eq(#s.results, 2)
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
    generation = s.generation
    p.action(s, 'section', 'help')
    vim.wait(50)
    H.eq(s.generation, generation)
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
    H.eq(s.options.case, true)
    H.eq(s.options.regex, true)
    H.eq(#s.results, 2)
    H.eq(s.fields.query, 'a.b')
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
  end
)

H.test('settings configure modifier defaults for new sessions', 'Q-08,Q-09', function()
  local a = H.fixture()
  local before = vim.deepcopy(p.config)
  local ok, err = xpcall(function()
    local existing = p.search(a)
    p.setup({ match_case_sensetivity = true, use_regular_expressions = true })
    local s = p.search(a)
    H.eq(
      s.options,
      { case = true, word = false, regex = true, open = false, ignored = false, context = 2 }
    )
    H.eq(
      existing.options,
      { case = false, word = false, regex = false, open = false, ignored = false, context = 2 }
    )
    p.setup({
      match_whole_words = true,
      only_search_open_files = true,
      also_search_ignored_files = true,
    })
    local all = p.search(a)
    H.eq(
      all.options,
      { case = true, word = true, regex = true, open = true, ignored = true, context = 2 }
    )
    for _, option in ipairs({ 'case', 'word', 'regex', 'open', 'ignored' }) do
      p.action(all, 'toggle', option)
    end
    H.eq(all.options, existing.options)
    p.setup()
    H.eq(
      p.search(a).options,
      { case = true, word = true, regex = true, open = true, ignored = true, context = 2 }
    )
    H.eq(pcall(p.setup, { use_regular_expressions = 'true' }), false)
    H.eq(pcall(p.setup, { match_case_sensetivity = 1 }), false)
  end, debug.traceback)
  p.config = before
  if not ok then
    error(err)
  end
end)

H.test(
  'every modifier enables for non-space symbols and disables for empty, spaces or missing brackets',
  'Q-09',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local s = p.replace(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    H.wait(s, 'complete')
    local other = p.replace(a)
    p.recent(s.id)
    p.action(s, 'section', 'replace')
    p.action(s, 'section', 'filters')
    local controls =
      { Aa = 'case', wd = 'word', ['.*'] = 'regex', ['󰥩'] = 'open', [''] = 'ignored' }
    for label, option in pairs(controls) do
      for _, value in ipairs({ 'x', '0', 'false', '雪', '\t', '', ' ', '   ', ' x ' }) do
        local line = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]
        local edited = line:gsub(vim.pesc(label) .. '%[[^%]]*%]', function()
          return label .. '[' .. value .. ']'
        end)
        vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { edited })
        local enabled = value:find('[^ ]') ~= nil
        p.refresh(s)
        H.wait(s, 'complete')
        H.eq(s.options[option], enabled, label .. '[' .. value .. '] was not applied')
        H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { edited })
        H.eq(s.fields.query, 'abc')
        H.eq(other.generation, 0)
        H.eq(other.options[option], false)
      end
      local line = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]
      for _, value in ipairs({ '', '[', '[yes' }) do
        local edited = line:gsub(vim.pesc(label) .. '%[[^%]]*%]', function()
          return label .. value
        end)
        vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { edited })
        p.refresh(s)
        H.wait(s, 'complete')
        H.eq(s.options[option], false)
        H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { edited })
      end
      -- Restore the label ourselves for the next round of ordinary edits.
      vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { line })
    end
  end
)

H.test('empty and space-only modifier brackets are equivalent OFF values', 'Q-01,Q-09', function()
  local a = H.fixture()
  H.write(a .. '/one', 'a.b axb A.B\n')
  local s = H.search(a, { query = 'a.b' })
  local generation = s.generation
  for _, value in ipairs({ '', ' ', '   ', '' }) do
    local heading = '[Search]    '
      .. table.concat({
        'Aa[' .. value .. ']',
        'wd[' .. value .. ']',
        '.*[' .. value .. ']',
        '󰥩[' .. value .. ']',
        '[' .. value .. ']',
      }, '  ')
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = s.buf })
    vim.wait(50)
    H.eq(
      s.options,
      { case = false, word = false, regex = false, open = false, ignored = false, context = 2 }
    )
    H.eq(s.generation, generation)
    H.eq(#s.results, 2)
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
  end
end)

H.test('native undo refreshes edited modifiers and their search results', 'Q-01,Q-09', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc ABC\n')
  local s = H.search(a)
  local generation = s.generation
  vim.api.nvim_win_set_cursor(0, { 1, #'[Search]    Aa[' })
  vim.api.nvim_buf_call(s.buf, function()
    vim.cmd('let &undolevels = &undolevels')
  end)
  vim.api.nvim_buf_set_text(s.buf, 0, #'[Search]    Aa[', 0, #'[Search]    Aa[ ', { 'x' })
  wait_for_edit(s, generation)
  H.eq(s.options.case, true)
  H.eq(#s.results, 1)
  H.eq(vim.api.nvim_win_get_cursor(0), { 1, #'[Search]    Aa[' })
  generation = s.generation
  vim.api.nvim_buf_call(s.buf, function()
    vim.cmd('silent undo')
  end)
  wait_for_edit(s, generation)
  H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), {
    '[Search]    Aa[ ]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]',
  })
  H.eq(s.options.case, false)
  H.eq(#s.results, 2)
  H.eq(s.fields.query, 'abc')
end)

H.test(
  'modifier edits leave empty queries idle and unchanged option values avoid searches',
  'Q-01,Q-09',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc ABC\n')
    local s = p.search(a)
    local generation = s.generation
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, {
      '[Search]    Aa[x]  wd[x]  .*[x]  󰥩[x]  [x]  ↕[2]',
    })
    assert(vim.wait(1000, function()
      return s.generation > generation
    end, 5))
    H.eq(s.status, 'empty')
    H.eq(s.timer, nil)
    H.eq(next(s.jobs), nil)
    H.eq(#s.results, 0)
    p.set(
      s,
      { query = 'abc', word = false, regex = false, open = false, ignored = false, context = 2 }
    )
    H.wait(s, 'complete')
    generation = s.generation
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, {
      '[Search]    Aa[yes]  wd[   ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]',
    })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = s.buf })
    vim.wait(50)
    H.eq(s.generation, generation)
    H.eq(s.status, 'complete')
    H.eq(#s.results, 1)
  end
)

H.test('incremental modifier edits remain ordinary text through redraws', 'Q-01,Q-09', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc ABC\n')
  local s = H.search(a)
  local generation = s.generation
  local heading = '[Search]    Aa[ ]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]'
  for _, value in ipairs({ '', '[', '[y', '[ye', '[yes', '[yes]' }) do
    local edited = heading:gsub('Aa%[ %]', function()
      return 'Aa' .. value
    end)
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { edited })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = s.buf })
    vim.wait(20)
    if value == '[yes]' then
      assert(s.generation > generation)
      H.eq(s.status, 'stale')
      generation = s.generation
    end
    H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { edited })
    H.eq(s.generation, generation)
    H.eq(s.options.case, value == '[yes]')
  end
  -- Editing another option explicitly preserves the manually typed case value.
  p.set(s, { regex = true })
  H.wait(s, 'complete')
  H.eq(s.options.case, true)
  H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), {
    '[Search]    Aa[yes]  wd[ ]  .*[x]  󰥩[ ]  [ ]  ↕[2]',
  })
end)

H.test('explicit searches read the latest modifier text', 'Q-01,Q-09', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc ABC\n')
  local s = H.search(a)
  local heading = '[Search]    Aa[yes]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]'
  -- Change the options before explicitly submitting the search.
  p.set(s, { query = 'ABC' })
  vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(s.options.case, true)
  H.eq(#s.results, 1)
  H.eq(s.results[1].match, 'ABC')
  heading = heading:gsub('Aa%[yes%]', 'Aa[ ]')
  vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
  require('searchlight.search').source_changed(a .. '/one')
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(s.options.case, false)
  H.eq(#s.results, 2)
  H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
end)
