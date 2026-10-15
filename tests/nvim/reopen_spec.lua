local H = require('tests.helpers')
local p = require('searchlight')
local sessions = require('searchlight.sessions')

local function settings(s)
  return vim.deepcopy({
    root = s.root,
    mode = s.mode,
    fields = s.fields,
    options = s.options,
    sections = s.sections,
    config = s.config,
    heading = s.search_heading,
  })
end

H.test('reopen without a previous session is an informational no-op', 'Reopen,Entries', function()
  sessions.previous = nil
  local notify, messages = vim.notify, {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message, level }
  end
  local id, buf = sessions.next_id, vim.api.nvim_get_current_buf()
  local ok, err = xpcall(function()
    H.eq(p.reopen(), nil)
    vim.cmd('SearchlightReopen')
    H.eq(sessions.next_id, id)
    H.eq(vim.api.nvim_get_current_buf(), buf)
    H.eq(messages, {
      { 'No previous Searchlight session', vim.log.levels.INFO },
      { 'No previous Searchlight session', vim.log.levels.INFO },
    })
  end, debug.traceback)
  vim.notify = notify
  assert(ok, err)
end)

for _, mode in ipairs({ 'search', 'replace' }) do
  H.test(mode .. ': reopen restores a hidden panel without changing any state', 'Reopen', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H[mode](a)
    p.navigate(s, 1)
    p.action(s, 'exclude')
    p.set(s, { sections = { filters = false, help = true } }, { refresh = false })
    local before, selected, results, generation = settings(s), s.selected, s.results, s.generation
    p.action(s, 'hide')
    vim.cmd('SearchlightReopen')
    H.eq(sessions.get(), s)
    H.eq(settings(s), before)
    H.eq(s.selected, selected)
    assert(s.results == results)
    H.eq(s.results[2].enabled, false)
    H.eq(s.generation, generation)
    H.eq(p.reopen(), s)
    H.eq(s.generation, generation)
  end)

  for _, close in ipairs({ 'close', 'bdelete', 'bwipeout', 'peeker' }) do
    H.test(
      mode .. ': reopen after ' .. close .. ' retains all settings across setup and cwd changes',
      'Reopen,Configuration,Lifecycle',
      function()
        local config = vim.deepcopy(p.config)
        local cwd = vim.fn.getcwd()
        local ok, err = xpcall(function()
          local a, b = H.fixture()
          local root = a .. '/root with spaces'
          H.write(root .. '/one.txt', 'abc abc\n')
          H.buffer(root .. '/one.txt')
          p.setup({
            syntax_highlighting = false,
            syntax_injections = true,
            syntax_max_file_bytes = 512,
            concurrency = 2,
            max_files = 100,
            max_output_bytes = 16384,
            max_source_bytes = 8192,
            max_snapshot_bytes = 32768,
          })
          local options = {
            query = 'abc',
            include = { '*.txt, *.lua', '' },
            exclude = { 'vendor/**', '*.bak' },
            case = true,
            word = true,
            regex = true,
            open = true,
            ignored = true,
            context = 0,
            max_results = 27,
            close_on_open = close == 'peeker',
            refresh = 'immediate',
          }
          if mode == 'replace' then
            options.replacement = 'X'
          end
          local s = H.wait(p[mode](root, options), 'complete')
          local sections = { filters = false, help = true }
          if mode == 'replace' then
            sections.replace = false
          end
          p.set(s, { sections = sections }, { refresh = false })
          local before = settings(s)
          if close == 'close' then
            vim.cmd('SearchlightClose')
          elseif close == 'peeker' then
            p.open(s)
          else
            vim.cmd(close .. '! ' .. s.buf)
          end
          H.eq(sessions.get(s.id), nil)
          p.setup(config)
          vim.cmd('cd ' .. vim.fn.fnameescape(b))
          vim.cmd('SearchlightReopen')
          local reopened = H.wait(sessions.get(), 'complete')
          assert(reopened.id ~= s.id and reopened.buf ~= s.buf)
          H.eq(settings(reopened), before)
          H.eq(#reopened.results, 2)
          H.eq(H.read(root .. '/one.txt'), 'abc abc\n')
          H.eq(p.reopen(), reopened)
        end, debug.traceback)
        vim.cmd('cd ' .. vim.fn.fnameescape(cwd))
        p.setup(config)
        assert(ok, err)
      end
    )
  end

  H.test(
    mode .. ': reopen retains native edits closed before scheduled rendering',
    'Reopen,Input',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'pending\n')
      local s = p[mode](a)
      local function edit(field, text)
        local region = s.regions[field]
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { text })
      end
      edit('query', 'pending')
      edit('include', 'one')
      vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, {
        require('searchlight.input').heading({
          case = true,
          word = true,
          regex = true,
          open = false,
          ignored = true,
          context = 0,
        }),
      })
      if mode == 'replace' then
        edit('replacement', 'native replacement')
      end
      local before = settings(s)
      p.close(s)
      local reopened = H.wait(p.reopen(), 'complete')
      H.eq(settings(reopened), before)
      H.eq(reopened.fields.query, 'pending')
      H.eq(#reopened.results, 1)
    end
  )
end

for _, close in ipairs({ 'close', 'bdelete', 'bwipeout' }) do
  H.test(
    'reopen keeps the intentionally activated panel after ' .. close .. ' in the same callback',
    'Reopen,Lifecycle',
    function()
      local a = H.fixture()
      local surviving = p.replace(a, { query = 'surviving', replacement = 'saved' })
      local departing = p.search(a, { query = 'departing' })
      p.recent(surviving.id)
      -- Do not yield to scheduled departure cleanup between activation and disposal.
      if close == 'close' then
        p.close(departing)
      else
        vim.cmd(close .. '! ' .. departing.buf)
      end
      H.eq(p.reopen(), surviving)
      H.eq(sessions.get(departing.id), nil)
    end
  )

  H.test(
    'reopen after ' .. close .. ' keeps the latest panel when Neovim enters an older panel',
    'Reopen,Lifecycle',
    function()
      local a = H.fixture()
      local older = p.search(a, { query = 'older' })
      local latest = p.replace(a, { query = 'latest', replacement = 'saved' })
      if close == 'close' then
        p.close(latest)
      else
        vim.cmd(close .. '! ' .. latest.buf)
      end
      local reopened = p.reopen()
      H.eq(reopened.mode, 'replace')
      H.eq(reopened.fields.query, 'latest')
      assert(sessions.owns(older))
      -- Explicit :buffer access still chooses the older session afterward.
      vim.cmd('buffer ' .. older.buf)
      H.eq(p.reopen(), older)
    end
  )
end

H.test(
  'reopen retains a deleted panel when its only window switches to an older buffer',
  'Reopen,Lifecycle',
  function()
    local a = H.fixture()
    local older = p.search(a)
    local latest = p.replace(a, { replacement = 'saved' })
    vim.cmd('only!')
    vim.cmd('bdelete! ' .. latest.buf)
    local reopened = p.reopen()
    H.eq(reopened.mode, 'replace')
    H.eq(reopened.fields.replacement, 'saved')
    assert(sessions.owns(older))
  end
)

H.test(
  'reopen follows explicit buffer access and ignores disposal of older panels',
  'Reopen,Lifecycle',
  function()
    local a = H.fixture()
    local first, second = p.search(a), p.replace(a)
    vim.cmd('buffer ' .. first.buf)
    p.action(first, 'hide')
    H.eq(p.reopen(), first)
    p.close(second)
    H.eq(p.reopen(), first)
  end
)
