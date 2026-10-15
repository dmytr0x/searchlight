local H = require('tests.helpers')
local p = require('searchlight')
local sessions = require('searchlight.sessions')
local view = require('searchlight.view')
local process = require('searchlight.process')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

-- Hold the inventory at the process boundary: each recorded call is one logical run.
local function controlled(run)
  local original, calls = process.start, {}
  process.start = function(argv, opts, done)
    assert(vim.tbl_contains(argv, '--files'), 'unexpected search phase')
    local call = { argv = argv, opts = opts, done = done, killed = false }
    calls[#calls + 1] = call
    return {
      kill = function()
        call.killed = true
      end,
    }
  end
  local ok, err = xpcall(function()
    run(calls)
  end, debug.traceback)
  process.start = original
  for _, call in ipairs(calls) do
    call.done({ code = 1 })
  end
  vim.wait(20)
  assert(ok, err)
end

local function panel(s)
  return vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
end

for _, mode in ipairs({ 'search', 'replace' }) do
  H.test(
    mode .. ': creation renders final fields, controls, limits and visibility',
    'API,Creation',
    function()
      local a = H.fixture()
      local options = {
        root = a,
        query = '"\\%|λ.*[x]',
        include = { '*.lua,*.md', 'a\\,b' },
        exclude = { 'vendor/**' },
        case = true,
        word = true,
        regex = false,
        open = true,
        ignored = true,
        context = 0,
        max_results = 7,
        close_on_open = true,
        sections = { filters = true, help = true },
      }
      if mode == 'replace' then
        options.replacement = '\\"%|λ$1'
        options.sections.replace = true
      end
      local before = vim.deepcopy(options)
      local render, first = view.render, nil
      view.render = function(s)
        render(s)
        first = first
          or {
            fields = vim.deepcopy(s.fields),
            sections = vim.deepcopy(s.sections),
            lines = panel(s),
          }
      end
      local ok, err = xpcall(function()
        local s = p[mode](options)
        H.eq(s.root, a)
        H.eq(s.config.max_results, 7)
        H.eq(s.config.close_on_open, true)
        H.eq(
          s.options,
          { case = true, word = true, regex = false, open = true, ignored = true, context = 0 }
        )
        H.eq(view.read(s).options, s.options)
        H.eq(first.fields, s.fields)
        H.eq(first.sections, s.sections)
        H.eq(first.lines, panel(s))
        assert(table.concat(first.lines, '\n'):find(options.query, 1, true))
        if mode == 'replace' then
          assert(table.concat(first.lines, '\n'):find(options.replacement, 1, true))
        end
        H.eq(options, before)
        options.include[1], options.sections.help, options.query = '*.txt', false, 'different'
        H.eq(s.fields.include, before.include)
        H.eq(s.sections.help, true)
        local another = p[mode](before)
        p.close(another)
      end, debug.traceback)
      view.render = render
      assert(ok, err)
    end
  )

  H.test(
    mode .. ': creation supports old call forms and reusable options safely',
    'API,Creation',
    function()
      local a = H.fixture()
      local options = { query = 'abc', include = { '*.lua' }, sections = { filters = false } }
      local before = vim.deepcopy(options)
      local first, second = p[mode](a, options), p[mode](a, options)
      H.eq(first.fields, second.fields)
      H.eq(options, before)
      options.include[1], options.sections.filters = '*.md', true
      H.eq(first.fields.include, { '*.lua' })
      H.eq(second.sections.filters, false)
      p.set(first.id, { include = {}, exclude = {}, query = '', context = 0 }, { refresh = false })
      H.eq(first.fields.query, '')
      H.eq(first.fields.include, {})
      H.eq(second.fields.query, 'abc')
      H.eq(p[mode](a).root, a)
      H.eq(p[mode](nil, {}).root, require('searchlight.scope').path(vim.fn.getcwd()))
      H.eq(p[mode]().mode, mode)
    end
  )

  H.test(
    mode .. ': false overrides true defaults and empty values clear fields',
    'API,Defaults',
    function()
      local a = H.fixture()
      local config = vim.deepcopy(p.config)
      local ok, err = xpcall(function()
        p.setup({
          match_case_sensetivity = true,
          match_whole_words = true,
          use_regular_expressions = true,
          only_search_open_files = true,
          also_search_ignored_files = true,
          close_on_open = true,
          context_size = 3,
        })
        local options = {
          case = false,
          word = false,
          regex = false,
          open = false,
          ignored = false,
          close_on_open = false,
          context = 0,
          query = '',
          include = {},
          exclude = {},
        }
        if mode == 'replace' then
          options.replacement = ''
        end
        local s = p[mode](a, options)
        H.eq(
          s.options,
          { case = false, word = false, regex = false, open = false, ignored = false, context = 0 }
        )
        H.eq(s.config.close_on_open, false)
        H.eq(s.fields.query, '')
        H.eq(s.fields.include, {})
        H.eq(s.fields.exclude, {})
        p.set(s, { query = 'abc', include = { '*.lua' } }, { refresh = false })
        local clears = { query = '', include = {}, exclude = {} }
        if mode == 'replace' then
          clears.replacement = ''
        end
        p.set(s, clears, { refresh = false })
        H.eq(s.fields.query, '')
        H.eq(s.fields.include, {})
        H.eq(s.status, 'empty')
        H.eq(p.config.context_size, 3)
      end, debug.traceback)
      p.setup(config)
      assert(ok, err)
    end
  )

  H.test(
    mode .. ': execution policies launch once and preserve presentation-only work',
    'API,Async',
    function()
      local a = H.fixture()
      controlled(function(calls)
        local s = p[mode](a, { query = 'abc' })
        vim.wait(40)
        H.eq(#calls, 0)
        H.eq(s.timer, nil)
        p.set(s, { query = 'xyz' }, { refresh = false })
        vim.wait(40)
        H.eq(#calls, 0)
        p.action(s, 'enter')
        H.eq(#calls, 1)
        local generation = s.generation
        p.set(s, { sections = { help = true, filters = false }, close_on_open = true })
        vim.wait(40)
        H.eq(#calls, 1)
        H.eq(s.generation, generation)
        H.eq(calls[1].killed, false)
        p.set(s, { query = 'final', max_results = 3 }, { refresh = 'immediate' })
        H.eq(#calls, 2)
        H.eq(calls[1].killed, true)
        H.eq(s.timer, nil)
        vim.wait(40)
        H.eq(#calls, 2)
        calls[1].opts.stdout(nil, './obsolete\0')
        calls[1].done({ code = 0 })
        vim.wait(20)
        H.eq(#s.results, 0)
        H.eq(s.status, 'searching')
        p.set(s, {}, { refresh = 'immediate' })
        H.eq(#calls, 3)
        p.set(s, { sections = { help = false } }, { refresh = 'debounced' })
        H.eq(#calls, 3)
        assert(calls[3].killed)
        vim.wait(40)
        H.eq(#calls, 4)
        p.set(s, { query = 'default' })
        H.eq(#calls, 4)
        vim.wait(40)
        H.eq(#calls, 5)
        p.set(s, { query = '' }, { refresh = 'immediate' })
        vim.wait(40)
        H.eq(#calls, 5)
        H.eq(s.status, 'empty')
        H.eq(s.timer, nil)
        p[mode](a, { query = 'initial immediate', refresh = 'immediate' })
        H.eq(#calls, 6)
        p[mode](a, { query = 'initial debounce', refresh = 'debounced' })
        H.eq(#calls, 6)
        vim.wait(40)
        H.eq(#calls, 7)
        p[mode](a, { query = 'prefill', refresh = false })
        vim.wait(40)
        H.eq(#calls, 7)
      end)
    end
  )

  H.test(
    mode .. ': pending native edits survive patches and wait on presentation changes',
    'API,Native',
    function()
      local a = H.fixture()
      controlled(function(calls)
        local s = p[mode](a, { query = 'abc' })
        local region = s.regions.query
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'native' })
        p.set(s, { sections = { filters = false } })
        vim.wait(40)
        H.eq(s.fields.query, 'native')
        H.eq(#calls, 0)
        H.eq(s.status, 'stale')
        p.set(s, { context = 0 }, { refresh = 'immediate' })
        H.eq(s.fields.query, 'native')
        H.eq(#calls, 1)
        region = s.regions.query
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'unsubmitted' })
        p.set(s, { query = 'api wins' }, { refresh = 'immediate' })
        H.eq(s.fields.query, 'api wins')
        H.eq(#calls, 2)
        vim.wait(40)
        H.eq(#calls, 2)
        H.eq(s.status, 'searching')
        p.set(s, { query = 'debounce' })
        view.request_render(s)
        region = s.regions.query
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'manual again' })
        vim.wait(40)
        H.eq(#calls, 2)
        H.eq(s.status, 'stale')
        H.eq(s.timer, nil)
      end)
    end
  )
end

H.test(
  'invalid creation preserves buffers, windows, registry, counter and focus',
  'API,Validation',
  function()
    local a = H.fixture()
    local before = {
      bufs = vim.api.nvim_list_bufs(),
      wins = vim.api.nvim_list_wins(),
      id = sessions.next_id,
      ids = vim.tbl_keys(sessions.by_id),
      last = sessions.last,
      buf = vim.api.nvim_get_current_buf(),
      win = vim.api.nvim_get_current_win(),
    }
    for _, mode in ipairs({ 'search', 'replace' }) do
      for _, options in ipairs({
        false,
        'invalid',
        1,
        { query = 'ok', sections = { help = 1 } },
        { query = 'a\nb' },
        { include = { [2] = '*.lua' } },
        { max_results = math.huge },
        { refresh = true },
        { unknown = false },
        { mode = 'replace' },
        { root = false },
      }) do
        H.eq(pcall(p[mode], a, options), false)
      end
      H.eq(pcall(p[mode], a, { root = a }), false)
      H.eq(pcall(p[mode], false), false)
      H.eq(pcall(p[mode], {}, {}), false)
    end
    for _, options in ipairs({ { replacement = '' }, { sections = { replace = false } } }) do
      H.eq(pcall(p.search, options), false)
    end
    H.eq(vim.api.nvim_list_bufs(), before.bufs)
    H.eq(vim.api.nvim_list_wins(), before.wins)
    H.eq(sessions.next_id, before.id)
    H.eq(vim.tbl_keys(sessions.by_id), before.ids)
    H.eq(sessions.last, before.last)
    H.eq(vim.api.nvim_get_current_buf(), before.buf)
    H.eq(vim.api.nvim_get_current_win(), before.win)
  end
)

H.test(
  'invalid patches and policies reject before native reads or any search/UI mutation',
  'API,Validation,Async',
  function()
    local a = H.fixture()
    controlled(function(calls)
      local s = p.search(a, { query = 'abc', refresh = 'immediate' })
      local region = s.regions.query
      vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, { 'pending native' })
      local before = {
        fields = vim.deepcopy(s.fields),
        options = vim.deepcopy(s.options),
        config = vim.deepcopy(s.config),
        sections = vim.deepcopy(s.sections),
        results = vim.deepcopy(s.results),
        generation = s.generation,
        cursor = vim.api.nvim_win_get_cursor(0),
        lines = panel(s),
        heading = s.search_heading,
        input_changed = s.input_changed,
        jobs = s.jobs,
        group = s.job_group,
        root = s.root,
      }
      local read = view.read
      view.read = function()
        error('invalid patch read native edits')
      end
      local ok, err = xpcall(function()
        for _, patch in ipairs({
          { query = 'valid', max_results = 0 },
          { query = 'valid', sections = { replace = false } },
          { query = 'valid', close_on_open = 'yes' },
          { include = { 'ok', extra = 'bad' } },
          false,
        }) do
          H.eq(pcall(p.set, s, patch), false)
        end
        for _, execution in ipairs({
          false,
          { refresh = true },
          { refresh = 'later' },
          { unknown = true },
        }) do
          H.eq(pcall(p.set, s, { query = 'valid' }, execution), false)
        end
        H.eq(pcall(p.action, s, 'toggle', 'context'), false)
        H.eq(pcall(p.action, s, 'toggle', 'unknown'), false)
        H.eq(pcall(p.action, s, 'section', 'unknown'), false)
        H.eq(s.fields, before.fields)
        H.eq(s.options, before.options)
        H.eq(s.config, before.config)
        H.eq(s.sections, before.sections)
        H.eq(s.results, before.results)
        H.eq(s.generation, before.generation)
        H.eq(s.search_heading, before.heading)
        H.eq(s.input_changed, before.input_changed)
        H.eq(s.jobs, before.jobs)
        H.eq(s.job_group, before.group)
        H.eq(s.root, before.root)
        H.eq(vim.api.nvim_win_get_cursor(0), before.cursor)
        H.eq(panel(s), before.lines)
        H.eq(calls[1].killed, false)
        H.eq(#calls, 1)
      end, debug.traceback)
      view.read = read
      assert(ok, err)
    end)
  end
)

H.test(
  'root, filters, modifiers and session limit control real results and previews',
  'API,Results',
  function()
    local a, b = H.fixture()
    H.write(a .. '/one.lua', 'abc ABC abcd abc\n')
    H.write(a .. '/skip.lua', 'abc\n')
    H.write(a .. '/two.txt', 'abc\n')
    H.write(b .. '/other.lua', 'abc other\n')
    local s = p.replace({
      root = a,
      query = 'abc',
      replacement = 'X',
      include = { '*.lua' },
      exclude = { 'skip*' },
      case = true,
      word = true,
      max_results = 1,
      sections = { filters = false, replace = false },
      refresh = 'immediate',
    })
    H.wait(s, 'truncated')
    H.eq(#s.results, 1)
    H.eq(s.results[1].replacement, 'X')
    H.eq(H.read(a .. '/one.lua'), 'abc ABC abcd abc\n')
    p.set(s, { max_results = 10 }, { refresh = 'immediate' })
    H.wait(s, 'complete')
    H.eq(#s.results, 2)
    H.eq(s.regions.include, nil)
    H.eq(s.regions.replacement, nil)
    p.set(s, { root = b, exclude = {}, replacement = 'Y' }, { refresh = 'immediate' })
    H.wait(s, 'complete')
    H.eq(#s.results, 1)
    H.eq(s.results[1].path, b .. '/other.lua')
    H.eq(s.results[1].replacement, 'Y')
    H.eq(H.read(b .. '/other.lua'), 'abc other\n')
    H.eq(p.config.max_results, 10000)
  end
)

H.test(
  'literal special characters survive real search without interpolation',
  'API,Results',
  function()
    local a = H.fixture()
    local query = '"\\%|λ.*[x]'
    H.write(a .. '/one', query .. '\n')
    local s = p.search(a, { query = query, regex = false, refresh = 'immediate' })
    H.wait(s, 'complete')
    H.eq(#s.results, 1)
    H.eq(s.results[1].match, query)
    H.eq(s.fields.query, query)
  end
)

H.test(
  'visibility patches are repeatable, merge keys and update hidden sessions without focus',
  'API,Visibility',
  function()
    local a = H.fixture()
    local s = p.replace(a, {
      query = 'abc',
      replacement = 'X',
      include = { '*.lua' },
      sections = { filters = false, replace = false, help = true },
    })
    p.action(s, 'hide')
    local buf, win, cursor =
      vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
    for _ = 1, 2 do
      p.set(s.id, {
        replacement = 'Y',
        include = { '*.md' },
        close_on_open = true,
        sections = { filters = false },
      })
    end
    H.eq(s.sections, { filters = false, replace = false, help = true })
    H.eq(vim.api.nvim_get_current_buf(), buf)
    H.eq(vim.api.nvim_get_current_win(), win)
    H.eq(vim.api.nvim_win_get_cursor(0), cursor)
    H.eq(vim.fn.win_findbuf(s.buf), {})
    p.recent(s.id)
    H.eq(s.regions.include, nil)
    H.eq(s.fields.include, { '*.md' })
    p.action(s, 'field', 'include')
    H.eq(s.sections.filters, true)
    p.action(s, 'field', 'replacement')
    H.eq(s.sections.replace, true)
    H.eq(s.fields.replacement, 'Y')
    p.set(nil, { sections = { help = false } })
    H.eq(s.sections.help, false)
  end
)

H.test(
  'interactive limit prompt uses validated immediate updates and surviving sessions',
  'API,Actions',
  function()
    local a = H.fixture()
    controlled(function(calls)
      local s = p.search(a, { query = 'abc' })
      local original, callback = vim.ui.input, nil
      vim.ui.input = function(_, cb)
        callback = cb
      end
      local ok, err = xpcall(function()
        p.action(s, 'limit')
        for _, value in ipairs({ '0', '-1', '1.5', 'inf', 'no number' }) do
          callback(value)
        end
        callback(nil)
        H.eq(#calls, 0)
        callback('3')
        H.eq(#calls, 1)
        H.eq(s.config.max_results, 3)
        H.eq(s.timer, nil)
        p.action(s, 'limit')
        p.close(s)
        callback('4')
        H.eq(#calls, 1)
      end, debug.traceback)
      vim.ui.input = original
      assert(ok, err)
    end)
  end
)

H.test(
  'cursor-word mapping reads the source before activation and replacement recipe waits',
  'API,Mappings',
  function()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'needle other\n')
    H.write(a .. '/two.txt', 'needle\n')
    local buf = H.buffer(a .. '/one.lua')
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    local previous, s, r = vim.fn.getcwd(), nil, nil
    vim.cmd('lcd ' .. vim.fn.fnameescape(a))
    vim.keymap.set('n', '<F19>', function()
      local query = vim.fn.expand('<cword>')
      s = p.search({
        query = query,
        include = { '*.lua' },
        regex = false,
        word = true,
        case = true,
        refresh = 'immediate',
      })
    end, { buffer = buf })
    vim.keymap.set('n', '<F20>', function()
      r = p.replace({
        query = 'config',
        replacement = 'settings',
        include = { '*.lua' },
        regex = false,
        sections = { replace = true, filters = true },
        refresh = false,
      })
    end, { buffer = buf })
    local ok, err = xpcall(function()
      keys('<F19>')
      H.wait(s, 'complete')
      H.eq(s.fields.query, 'needle')
      H.eq(s.root, a)
      H.eq(#s.results, 1)
      H.eq(s.results[1].path, a .. '/one.lua')
      p.action(s, 'hide')
      vim.api.nvim_set_current_buf(buf)
      keys('<F20>')
      vim.wait(40)
      H.eq(
        r.fields,
        { query = 'config', replacement = 'settings', include = { '*.lua' }, exclude = {} }
      )
      H.eq(r.timer, nil)
      H.eq(next(r.pending_jobs), nil)
      H.eq(H.read(a .. '/one.lua'), 'needle other\n')
      keys('0CFIXME<Esc>')
      vim.wait(40)
      H.eq(r.status, 'stale')
      keys('u')
      vim.wait(40)
      H.eq(r.timer, nil)
      p.action(r, 'section', 'help')
      H.eq(vim.api.nvim_win_get_cursor(0), { r.help_row, 0 })
      p.action(r, 'section', 'help')
      p.action(r, 'section', 'filters')
      p.action(r, 'hide')
      p.recent(r.id)
      H.eq(r.sections.filters, false)
    end, debug.traceback)
    vim.api.nvim_buf_del_keymap(buf, 'n', '<F19>')
    vim.api.nvim_buf_del_keymap(buf, 'n', '<F20>')
    vim.cmd('lcd ' .. vim.fn.fnameescape(previous))
    assert(ok, err)
  end
)
