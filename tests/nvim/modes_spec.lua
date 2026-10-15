local H = require('tests.helpers')
local p = require('searchlight')
local sessions = require('searchlight.sessions')
local view = require('searchlight.view')
local replace = require('searchlight.replace')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function panel(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
end
local function search_ui(s)
  H.eq(s.mode, 'search')
  H.eq(s.fields.replacement, nil)
  H.eq(s.sections.replace, nil)
  H.eq(s.regions.replacement, nil)
  for _, text in ipairs({
    '[Replace]',
    'Replace hidden',
    'Last apply:',
    'Replace next',
    'Replace all',
    'Regex captures:',
    'refresh search/previews',
    'Undo is per file',
  }) do
    assert(not panel(s):find(text, 1, true), 'Search contains ' .. text)
  end
  for _, key in ipairs({ 'r', 'v', 'n', 'A' }) do
    H.eq(vim.fn.maparg('<localleader>' .. key, 'n', false, true), {})
  end
end

for _, mode in ipairs({ 'search', 'replace' }) do
  H.test(
    mode .. ' commands and APIs capture roots and preserve their mode',
    'Modes,Creation',
    function()
      local a = H.fixture()
      local root = a .. '/root with spaces'
      vim.fn.mkdir(root, 'p')
      local command = mode == 'search' and 'SearchlightNew' or 'SearchlightReplaceNew'
      vim.cmd(command .. ' ' .. vim.fn.fnameescape(root))
      local s = sessions.get()
      H.eq({ s.mode, s.root }, { mode, root })
      local commands = vim.api.nvim_get_commands({})
      H.eq(commands[command].complete, 'dir')
      H.eq(commands[command].nargs, '?')
      local previous = vim.fn.getcwd()
      vim.cmd('lcd ' .. vim.fn.fnameescape(root))
      local ok, err = xpcall(function()
        vim.cmd(command)
        H.eq({ sessions.get().mode, sessions.get().root }, { mode, root })
        local another = p[mode]()
        H.eq({ another.mode, another.root }, { mode, root })
        assert(another.id ~= s.id)
        H.eq(another.config.mappings, nil)
        p.action(s, 'hide')
        H.eq(p.recent(s.id), s)
        H.eq(s.mode, mode)
        vim.cmd('SearchlightFocus ' .. another.id)
        H.eq(sessions.get(), another)
        H.eq(another.mode, mode)
      end, debug.traceback)
      vim.cmd('lcd ' .. vim.fn.fnameescape(previous))
      assert(ok, err)
    end
  )

  H.test(
    mode .. ' cycles only available fields in normal and insert mode',
    'Modes,Fields',
    function()
      local a = H.fixture()
      local s = p[mode](a)
      local fields = require('searchlight.modes').get(mode).fields
      for _, insert in ipairs({ false, true }) do
        view.focus_field(s, 'query')
        for i = 1, #fields do
          keys(insert and 'i<Tab><Esc>' or '<Tab>')
          H.eq(view.field_at_cursor(s), fields[i % #fields + 1])
        end
      end
      p.action(s, 'section', 'filters')
      view.focus_field(s, fields[#fields - 1])
      H.eq(s.sections.filters, true)
      if mode == 'replace' then
        p.action(s, 'section', 'replace')
        H.eq(s.regions.replacement, nil)
        view.focus_field(s, 'replacement')
        H.eq(s.sections.replace, true)
        assert(s.regions.replacement)
      else
        search_ui(s)
      end
    end
  )
end

H.test(
  'Search keeps replacement unavailable across redraw refresh undo and restoration',
  'Modes,Layout',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc xyz\n')
    local s = H.search(a)
    search_ui(s)
    p.action(s, 'section', 'help')
    search_ui(s)
    assert(panel(s):find(':SearchlightReplaceNew', 1, true))
    view.focus_field(s, 'query')
    keys('0Cxyz<Esc>')
    p.refresh(s)
    H.wait(s, 'complete')
    search_ui(s)
    keys('u')
    vim.wait(100)
    view.render(s)
    search_ui(s)
    p.action(s, 'hide')
    p.recent(s.id)
    p.setup()
    view.render(s)
    search_ui(s)
    p.action(s, 'hide')
    vim.cmd('buffer ' .. s.buf)
    search_ui(s)
    p.action(s, 'exclude')
    H.eq(s.results[1].enabled, false)
  end
)

H.test(
  'invalid Search input updates are atomic even before native synchronization',
  'Modes,Input',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H.search(a)
    local before = {
      fields = vim.deepcopy(s.fields),
      options = vim.deepcopy(s.options),
      root = s.root,
      generation = s.generation,
      results = vim.deepcopy(s.results),
      selected = s.selected,
    }
    local synchronize = require('searchlight.controller').synchronize
    local reads = 0
    local original = view.read
    view.read = function(...)
      reads = reads + 1
      return original(...)
    end
    local ok, err = xpcall(function()
      for _, changes in ipairs({
        { replacement = '' },
        { replacement = 'X', query = 'xyz', root = '/', case = true },
        { mode = 'replace', query = 'xyz' },
        { query = 'xyz', unknown = true },
      }) do
        H.eq(pcall(p.set, s, changes), false)
        H.eq(reads, 0)
        H.eq(s.fields, before.fields)
        H.eq(s.options, before.options)
        H.eq(s.root, before.root)
        H.eq(s.generation, before.generation)
        H.eq(s.results, before.results)
        H.eq(s.selected, before.selected)
      end
      H.eq(pcall(synchronize, s, 'set', { replacement = '' }), false)
      H.eq(reads, 0)
      local replacement = p.replace(a)
      H.eq(pcall(p.set, replacement, { mode = 'search', replacement = 'X' }), false)
      H.eq(replacement.mode, 'replace')
      H.eq(replacement.fields.replacement, '')
    end, debug.traceback)
    view.read = original
    assert(ok, err)
  end
)

H.test(
  'Search rejects all replacement entry points without synchronization or source edits',
  'Modes,Editing',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local buf = H.buffer(a .. '/one', { 'abc abc' })
    local s = H.search(a)
    local before = {
      generation = s.generation,
      selected = s.selected,
      fields = vim.deepcopy(s.fields),
      sections = vim.deepcopy(s.sections),
      report = s.report,
      cursor = vim.api.nvim_win_get_cursor(0),
      tick = vim.api.nvim_buf_get_changedtick(buf),
      undo = vim.api.nvim_buf_call(buf, vim.fn.undotree),
    }
    local original = view.read
    view.read = function()
      error('unavailable operations must not synchronize')
    end
    local ok, err = xpcall(function()
      local operations = {
        function()
          return p.action(s, 'replace_next')
        end,
        function()
          return p.action(s, 'replace_all')
        end,
        function()
          return p.action(s, 'field', 'replacement')
        end,
        function()
          return p.action(s, 'section', 'replace')
        end,
        function()
          return view.focus_field(s, 'replacement')
        end,
        function()
          return replace.apply(s, false)
        end,
        function()
          return replace.apply(s, true)
        end,
      }
      for _, operation in ipairs(operations) do
        local result, reason = operation()
        H.eq(result, nil)
        assert(reason:find('Search sessions', 1, true))
        H.eq(s.generation, before.generation)
        H.eq(s.selected, before.selected)
        H.eq(s.fields, before.fields)
        H.eq(s.sections, before.sections)
        H.eq(s.report, before.report)
        H.eq(vim.api.nvim_win_get_cursor(0), before.cursor)
        H.eq(vim.api.nvim_buf_get_changedtick(buf), before.tick)
        H.eq(vim.api.nvim_buf_call(buf, vim.fn.undotree), before.undo)
        H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'abc abc' })
        H.eq(H.read(a .. '/one'), 'abc abc\n')
      end
    end, debug.traceback)
    view.read = original
    assert(ok, err)
  end
)

H.test(
  'mode-specific requests omit replacement argv and values in Search',
  'Modes,Process',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local process, rg = require('searchlight.process'), require('searchlight.rg')
    local start, probe = process.start, rg.probe
    local argv = {}
    process.start = function(args, ...)
      if vim.tbl_contains(args, '--json') then
        argv[#argv + 1] = vim.deepcopy(args)
      end
      return start(args, ...)
    end
    local ok, err = xpcall(function()
      local s = H.search(a, { query = 'a(b)c', regex = true })
      for _, arg in ipairs(argv[1]) do
        assert(not arg:find('^%-%-replace='))
      end
      H.eq(s.results[1].replacement, nil)
      H.eq(replace.preview(s.results[1]), nil)
      local r = H.replace(a, { query = 'a(b)c', replacement = '$1!', regex = true })
      assert(vim.tbl_contains(argv[2], '--replace=$1!'))
      H.eq(r.results[1].replacement, 'b!')
      rg.probe = function()
        return { search = true, replacement = false, reason = 'capture expansion unavailable' }
      end
      argv = {}
      s = H.search(a)
      H.eq(#s.results, 1)
      H.eq(s.message, nil)
      H.eq(s.results[1].replacement, nil)
      for _, arg in ipairs(argv[1]) do
        assert(not arg:find('^%-%-replace='))
      end
      r = H.replace(a)
      assert(r.message:find('capture expansion unavailable', 1, true))
      H.eq(p.action(r, 'replace_all'), nil)
    end, debug.traceback)
    process.start, rg.probe = start, probe
    assert(ok, err)
  end
)

H.test(
  'recent restores surviving modes by usage and replacement invalidates Search',
  'Modes,Coexistence',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local first, second, third = H.search(a), H.replace(a), H.search(a)
    p.recent(first.id)
    p.recent(third.id)
    sessions.dispose(third)
    H.eq(p.recent(), first)
    vim.api.nvim_buf_delete(third.buf, { force = true })
    p.setup()
    p.action(first, 'hide')
    vim.cmd('buffer ' .. second.buf)
    H.eq(p.recent(), second)
    local generation = first.generation
    H.eq(p.action(second, 'replace_next').applied, 1)
    H.wait(second, 'complete')
    H.eq(first.status, 'stale')
    assert(first.generation > generation)
    H.eq(first.mode, 'search')
    H.eq(second.mode, 'replace')
    H.eq(H.read(a .. '/one'), 'abc abc\n')
    H.eq(H.lines(a .. '/one'), { 'X abc' })
    p.recent(first.id)
    search_ui(first)
  end
)

H.test('obsolete entry points and compatibility exports are absent', 'Modes,API', function()
  for _, name in ipairs({ 'new', 'focus', 'replace_new' }) do
    H.eq(p[name], nil)
  end
  H.eq(sessions.focus, nil)
  H.eq(sessions.option_settings, nil)
  H.eq(sessions.valid_context_size, nil)
  H.eq(replace.selected, nil)
  H.eq(view.read_options, nil)
  H.eq(view.set_options, nil)
  local a = H.fixture()
  H.eq(pcall(sessions.create, a, p.config), false)
end)

for _, mode in ipairs({ 'search', 'replace' }) do
  H.test(
    mode .. ' shares modifiers limits refresh and result highlighting',
    'Modes,Shared',
    function()
      local a = H.fixture()
      H.write(a .. '/one.lua', 'abc ABC abcd\n')
      H.write(a .. '/two.txt', 'abc\n')
      local s = H[mode](a)
      H.eq(#s.results, 4)
      H.update(s, { case = true, word = true, include = { '*.lua' }, context = 0 })
      H.eq(#s.results, 1)
      H.eq(s.results[1].match, 'abc')
      H.eq(s.results[1].context_size, 0)
      assert(#view.decorations(s) > 0)
      p.navigate(s, 1)
      local selected = s.selected
      p.refresh(s)
      H.wait(s, 'complete')
      H.eq(s.selected, selected)
      H.write(a .. '/one.lua', 'abc abc abc\n')
      s.config.max_results = 2
      p.refresh(s)
      H.wait(s, 'truncated')
      H.eq(#s.results, 2)
      if mode == 'search' then
        assert(not panel(s):find('Replace all', 1, true))
      end
      s.config.max_results = 10
      p.refresh(s)
      H.wait(s, 'complete')
      H.eq(#s.results, 3)
      H.eq(s.mode, mode)
    end
  )

  H.test(
    mode .. ' native multiline validation names only its available fields',
    'Modes,Input',
    function()
      local a = H.fixture()
      local s = p[mode](a)
      local region = s.regions.query
      vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'abc', 'def' })
      p.refresh(s)
      H.wait(s, 'error')
      assert(s.message:find('one logical line', 1, true))
      if mode == 'search' then
        assert(not s.message:find('Replace', 1, true))
      end
      if mode == 'replace' then
        p.set(s, { query = 'abc' })
        region = s.regions.replacement
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'X', 'Y' })
        p.refresh(s)
        H.wait(s, 'error')
        assert(s.message:find('Search and Replace', 1, true))
      end
    end
  )
end
