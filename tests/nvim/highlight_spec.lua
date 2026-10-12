local H = require('tests.helpers')
local p = require('searchlight')
local view = require('searchlight.view')
local syntax = require('searchlight.highlight')

local function show_results(s)
  p.navigate(s, 0)
  vim.cmd('normal! zt')
end

local function settled()
  syntax._test.collect()
  assert(
    vim.wait(3000, function()
      if syntax.diagnostics().busy then
        return false
      end
      for _, demand in pairs(syntax._test.demands()) do
        if not demand.done then
          return false
        end
      end
      return true
    end, 5),
    'syntax worker did not settle: ' .. vim.inspect(syntax.diagnostics())
  )
end

local function spans()
  local found = {}
  for _, entry in pairs(syntax._test.entries()) do
    for _, chunk in pairs(entry.chunks) do
      for i = 1, #chunk.spans, 5 do
        found[#found + 1] = vim.list_slice(chunk.spans, i, i + 4)
      end
    end
  end
  return found
end

local function bounds()
  local d = syntax.diagnostics()
  for key, value in pairs(d.high_water) do
    assert(not d.limits[key] or value <= d.limits[key], 'in-flight budget exceeded: ' .. key)
  end
  for _, key in ipairs({
    'parsers',
    'retained_bytes',
    'managed_bytes',
    'spans',
    'rows',
    'blocks',
    'chunks',
    'demands',
    'languages',
    'failures',
    'missing',
    'groups',
  }) do
    assert(d[key] >= 0 and d[key] <= d.limits[key], key .. ': ' .. vim.inspect(d))
  end
end

H.test('syntax mappings share exact rendering blocks and byte gutters', 'Syntax,Layout', function()
  local a = H.fixture()
  H.write(
    a .. '/one.lua',
    'local above = "雪"\nabc abc\n-- below\nskip\nskip\n-- above\nabc\n-- below\n'
  )
  local s = H.search(a, { query = 'abc', context = 1 })
  view.render(s)
  local mapping, lines = {}, vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  require('searchlight.results').mappings(
    s,
    0,
    #lines,
    function(row, snapshot, line, col, length)
      mapping[#mapping + 1] = line
      H.eq(lines[row + 1]:sub(col + 1), snapshot.lines[line])
      H.eq(length, #snapshot.lines[line])
      assert(not s.file_rows[row + 1])
    end
  )
  H.eq(mapping, { 1, 2, 3, 6, 7, 8 })
  local revision = s.layout_revision
  p.navigate(s, 1)
  H.eq(s.layout_revision, revision)
  p.action(s, 'section', 'filters')
  assert(s.layout_revision > revision)
  s.collapsed_paths[a .. '/one.lua'] = true
  view.render(s)
  mapping = {}
  require('searchlight.results').mappings(s, 0, #lines, function(row)
    mapping[#mapping + 1] = row
  end)
  H.eq(mapping, {})
end)

H.test(
  'decoration drawing clips ephemeral UTF-8 spans to code and leaves fields plain',
  'Syntax,Drawing',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local text = "雪 abc"\n-- context\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    local maps, emitted = {}, {}
    require('searchlight.results').mappings(
      s,
      0,
      vim.api.nvim_buf_line_count(s.buf),
      function(row, _, _, col, length)
        maps[row] = { col, length }
      end
    )
    local original = vim.api.nvim_buf_set_extmark
    vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, options)
      if ns == syntax.namespace and buf == s.buf then
        local mapping = assert(maps[row], 'syntax was drawn on a non-code row')
        assert(options.ephemeral)
        assert(col >= mapping[1] and options.end_col <= mapping[1] + mapping[2])
        assert(options.priority < 2000)
        emitted[options.hl_group] = true
      end
      return original(buf, ns, row, col, options)
    end
    local ok, err = xpcall(function()
      settled()
      vim.cmd('redraw!')
      assert(emitted[vim.api.nvim_get_hl_id_by_name('@string.lua')], 'string syntax was not drawn')
      assert(
        emitted[vim.api.nvim_get_hl_id_by_name('@comment.lua')],
        'context syntax was not drawn'
      )
    end, debug.traceback)
    vim.api.nvim_buf_set_extmark = original
    if not ok then
      error(err)
    end
  end
)

H.test(
  'real snapshot syntax covers Lua and C context and preserves search overlays',
  'Syntax,Parser',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local abc = "雪"\n-- below\nreturn abc\n')
    H.write(a .. '/two.c', 'int abc = 42;\n/* context */\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    local buffers = #vim.api.nvim_list_bufs()
    local before = syntax.diagnostics().parses
    settled()
    assert(syntax.diagnostics().parses >= before + 2)
    assert(#spans() > 0)
    H.eq(#vim.api.nvim_list_bufs(), buffers, 'highlighting created source buffers')
    local d = syntax.diagnostics()
    local revision = s.layout_revision
    for _ = 1, 10 do
      p.navigate(s, 1, true)
    end
    settled()
    H.eq(s.layout_revision, revision)
    H.eq(syntax.diagnostics().parses, d.parses)
    H.eq(syntax.diagnostics().extractions, d.extractions)
    vim.cmd('redraw')
    H.eq(vim.api.nvim_buf_get_extmarks(s.buf, syntax.namespace, 0, -1, {}), {})
    for _, mark in
      ipairs(view.decorations(s))
    do
      if
        mark[4].hl_group == 'SearchlightMatch' or mark[4].hl_group == 'SearchlightSelected'
      then
        H.eq(mark[4].priority, 2000)
      end
    end
    bounds()
  end
)

H.test(
  'multiline captures beginning outside a distant viewport use the full snapshot',
  'Syntax,Viewport',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(
      a .. '/one.lua',
      'local text = [[\n' .. string.rep('inside\n', 60) .. 'abc 雪\n]]\nreturn text\n'
    )
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    show_results(s)
    settled()
    local found = false
    for _, span in ipairs(spans()) do
      if span[1] == 62 and span[2] == 0 and span[3] == #'abc 雪' then
        found = true
      end
    end
    assert(found, 'long string was parsed as a fragment')
    -- Only the displayed source line is extracted, not the complete file.
    for _, span in ipairs(spans()) do
      H.eq(span[1], 62)
    end
  end
)

H.test(
  'unsaved snapshots and source filetype metadata drive syntax without another search',
  'Syntax,Snapshot',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.data', 'disk abc\n')
    local buf = H.buffer(a .. '/one.data', { 'local abc = "unsaved"' }, { filetype = 'lua' })
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    assert(#spans() > 0)
    H.eq(vim.api.nvim_buf_get_changedtick(buf), tick)
    H.eq(H.read(a .. '/one.data'), 'disk abc\n')
    local gen = s.generation
    vim.bo[buf].filetype = 'c'
    vim.api.nvim_exec_autocmds('FileType', { buffer = buf })
    settled()
    H.eq(s.generation, gen)
    local langs = {}
    for _, entry in pairs(syntax._test.entries()) do
      langs[entry.lang] = true
    end
    assert(langs.c)
  end
)

H.test(
  'manual panel edits clear colors until authoritative layout returns',
  'Syntax,Layout',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local abc = 42\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    local revision = s.layout_revision
    local position = s.result_positions[s.selected]
    vim.api.nvim_buf_set_lines(
      s.buf,
      position.row - 1,
      position.row,
      false,
      { 'temporary result edit' }
    )
    H.eq(s.layout_invalid, true)
    H.eq(syntax.diagnostics().rows, 0)
    H.eq(vim.api.nvim_buf_get_lines(s.buf, position.row - 1, position.row, false), {
      'temporary result edit',
    })
    assert(vim.wait(1000, function()
      return not s.render_pending and not s.layout_invalid
    end, 5), 'syntax layout was not repaired after the edit')
    assert(s.layout_revision > revision)
    view.render(s)
    assert(s.layout_revision > revision)
    settled()
    assert(syntax.diagnostics().rows > 0)
    H.eq(H.read(a .. '/one.lua'), 'local abc = 42\n')
  end
)

H.test(
  'theme redraws reuse spans and explicit query reload reuses parsing',
  'Syntax,Theme',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local abc = "text"\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    local before = syntax.diagnostics()
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    settled()
    H.eq(syntax.diagnostics().parses, before.parses)
    H.eq(syntax.diagnostics().extractions, before.extractions)
    vim.api.nvim_exec_autocmds('User', { pattern = 'SearchlightHighlightReload' })
    settled()
    H.eq(syntax.diagnostics().parses, before.parses)
    assert(syntax.diagnostics().extractions > before.extractions)
  end
)

H.test(
  'disabled unsupported oversized and long-line sources remain readable',
  'Syntax,Fallback',
  function()
    syntax._test.reset()
    local a = H.fixture()
    local config = p.config.syntax_highlighting
    p.setup({ syntax_highlighting = false })
    H.write(a .. '/one.lua', 'local abc = 42\n')
    local s = H.search(a)
    view.render(s)
    local before = syntax.diagnostics().parses
    settled()
    H.eq(s.config.syntax_highlighting, false)
    H.eq(syntax.diagnostics().parses, before)
    p.setup({ syntax_highlighting = config })
    H.cleanup()
    a = H.fixture()
    H.write(a .. '/one.lua', '-- abc\n' .. string.rep('-- padding\n', 14000))
    H.write(a .. '/two.lua', '-- abc ' .. string.rep('x', 5000) .. '\n')
    H.write(a .. '/three.unsupported', 'abc\n')
    s = H.search(a)
    view.render(s)
    settled()
    H.eq(#s.results, 3)
    -- The oversized group and long source line have no syntax mapping.
    for _, demand in pairs(syntax._test.demands()) do
      for i = 1, #demand.maps, 6 do
        assert(not demand.maps[i + 4]:match('/one.lua$'))
        assert(demand.maps[i + 4] ~= a .. '/two.lua' or demand.maps[i + 1] ~= 1)
      end
    end
    H.eq(s.status, 'complete')
    bounds()
  end
)

H.test(
  'global bounds apply to ten sessions and hidden deleted panels release demand ownership',
  'Syntax,Budgets',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', string.rep('local abc = "text"\n', 150))
    local all = {}
    for i = 1, 10 do
      all[i] = H.search(a)
      view.render(all[i])
      show_results(all[i])
      syntax._test.collect()
      bounds()
    end
    settled()
    H.eq(syntax.diagnostics().parsers, 1, 'identical content should share a parser')
    bounds()
    local before = syntax.diagnostics().parses
    for _ = 1, 20 do
      syntax.request()
    end
    settled()
    H.eq(syntax.diagnostics().parses, before)
    for _, s in ipairs(all) do
      p.close(s)
    end
    settled()
    H.eq(syntax.diagnostics().demands, 0)
    H.eq(syntax.diagnostics().rows, 0)
    H.eq(syntax.diagnostics().spans, 0)
    syntax._test.reset()
    H.eq(syntax.diagnostics().parsers, 0)
    H.eq(syntax.diagnostics().retained_bytes, 0)
    H.eq(syntax.diagnostics().managed_bytes, 0)
  end
)

local function fake(options)
  options = options or {}
  return {
    language = function()
      bounds()
      return 'lua'
    end,
    query = function()
      bounds()
      return {
        captures = { 'string', '_private', 'comment' },
        iter_captures = function()
          bounds()
          local n = 0
          return function()
            bounds()
            n = n + 1
            if n > (options.captures or 3) then
              return
            end
            return n == 2 and 2 or n == 3 and 3 or 1,
              {},
              {
                priority = 50000,
                [1] = { priority = 5 },
                [3] = { conceal = '' },
              }
          end
        end,
      }
    end,
    parser = function(text)
      bounds()
      assert(#text <= syntax.diagnostics().limits.source_bytes)
      return {
        parse = function(_, _, done)
          bounds()
          local tree = {
            root = function()
              return {}
            end,
          }
          if options.parse then
            options.parse(done, tree)
          else
            done(nil, { tree })
          end
        end,
        destroy = function()
          bounds()
          if options.destroy then
            options.destroy()
          end
        end,
      }
    end,
    range = function()
      return 0, 1, 0, 6
    end,
    -- Real timers would retry transient failures inside later tests.
    defer = function() end,
  }
end

H.test(
  'all visible groups draw syntax beyond the parser capacity',
  'Syntax,Viewport,Budgets',
  function()
    local adapter = fake()
    adapter.now = function()
      return 0
    end
    syntax._test.reset(adapter)
    local a = H.fixture()
    for _, name in ipairs({ 'actions', 'highlight', 'init' }) do
      H.write(a .. '/' .. name .. '.lua', 'local abc = "' .. name .. '"\n')
    end
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    show_results(s)
    settled()
    local rows, emitted = {}, {}
    require('searchlight.results').mappings(
      s,
      0,
      vim.api.nvim_buf_line_count(s.buf),
      function(row)
        rows[#rows + 1] = row
      end
    )
    H.eq(#rows, 3)
    local original = vim.api.nvim_buf_set_extmark
    vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, options)
      if buf == s.buf and ns == syntax.namespace then
        emitted[row] = true
      end
      return original(buf, ns, row, col, options)
    end
    local ok, err = xpcall(function()
      vim.cmd('redraw!')
      for _, row in ipairs(rows) do
        assert(emitted[row], 'visible Lua group has no syntax at row ' .. row)
      end
      local before = syntax.diagnostics()
      for _ = 1, 5 do
        emitted = {}
        syntax._test.collect()
        settled()
        vim.cmd('redraw!')
        for _, row in ipairs(rows) do
          assert(emitted[row], 'cached Lua group lost syntax at row ' .. row)
        end
      end
      H.eq(syntax.diagnostics().parses, before.parses, 'warm redraw reparsed visible files')
      H.eq(syntax.diagnostics().extractions, before.extractions)
      H.eq(before.parsers, 2)
      assert(before.destroyed > 0, 'parser capacity was not recycled')
      emitted = {}
      syntax.invalidate(s)
      settled()
      vim.cmd('redraw!')
      for _, row in ipairs(rows) do
        assert(emitted[row], 'rebuilt Lua group has no syntax at row ' .. row)
      end
      bounds()
    end, debug.traceback)
    vim.api.nvim_buf_set_extmark = original
    syntax._test.reset()
    if not ok then
      error(err)
    end
  end
)

H.test(
  'recycled real Lua parsers recolor uncached rows and query reloads',
  'Syntax,Parser,LRU',
  function()
    syntax._test.reset(nil, { parsers = 1 })
    local a = H.fixture()
    for i = 1, 3 do
      H.write(a .. '/' .. i .. '.lua', 'local abc = "text' .. i .. '"\n-- more context\n')
    end
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    show_results(s)
    settled()
    local function colored(context)
      local entries = syntax._test.entries()
      for path, snapshot in pairs(s.snapshots) do
        local entry = assert(entries[snapshot.hash .. ':lua'], 'no cached syntax for ' .. path)
        local lines = {}
        for _, chunk in pairs(entry.chunks) do
          for j = 1, #chunk.spans, 5 do
            lines[chunk.spans[j]] = true
          end
        end
        assert(lines[1], 'Lua code lost colors for ' .. path)
        if context then
          assert(lines[2], 'uncached context was not colored for ' .. path)
        end
      end
      H.eq(syntax.diagnostics().parsers, 1)
      bounds()
    end
    colored(false)
    -- Each cached-only entry must reacquire a parser to extract newly displayed context.
    H.update(s, { context = 1 })
    view.render(s)
    show_results(s)
    settled()
    colored(true)
    syntax.reload()
    settled()
    colored(true)
    p.close(s)
    settled()
    H.eq(syntax.diagnostics().spans, 0)
    syntax._test.reset()
    H.eq(syntax.diagnostics().parsers, 0)
    H.eq(syntax.diagnostics().retained_bytes, 0)
    H.eq(syntax.diagnostics().managed_bytes, 0)
  end
)

H.test(
  'dense chunks publish every capture across several ticks without failures',
  'Syntax,Budgets',
  function()
    local adapter, slices = fake(), 0
    adapter.now = function()
      return 0
    end
    adapter.query = function()
      return {
        captures = { 'string' },
        -- 300 one-byte captures per source line, ordered by position.
        iter_captures = function(_, _, _, start, stop)
          slices = slices + 1
          local row, col = start, -1
          return function()
            col = col + 1
            if col == 300 then
              row, col = row + 1, 0
            end
            if row < stop then
              return 1, { row = row, col = col }, {}
            end
          end
        end,
      }
    end
    adapter.range = function(node)
      return node.row, node.col, node.row, node.col + 1
    end
    syntax._test.reset(adapter)
    local a = H.fixture()
    H.write(a .. '/one.lua', string.rep('abc ' .. string.rep('x', 320) .. '\n', 10))
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    show_results(s)
    settled()
    H.eq(#spans(), 3000)
    H.eq(syntax.diagnostics().failures, 0)
    assert(slices >= 3, 'dense chunk was extracted in one slice')
    bounds()
    syntax._test.reset()
  end
)

H.test('parser callbacks delayed by scheduled work still publish spans', 'Syntax,Parser', function()
  syntax._test.reset(fake({
    parse = function(done, tree)
      vim.schedule(function()
        local started = vim.uv.hrtime()
        while vim.uv.hrtime() - started < 50e6 do
        end
        vim.schedule(function()
          done(nil, { tree })
        end)
      end)
    end,
  }))
  local a = H.fixture()
  H.write(a .. '/one.lua', 'abc abc\n')
  local s = H.search(a)
  view.render(s)
  show_results(s)
  settled()
  assert(#spans() > 0, 'delayed parse lost colors')
  H.eq(syntax.diagnostics().failures, 0)
  syntax._test.reset()
end)

H.test(
  'transient parse failures recolor after backoff without user input',
  'Syntax,Parser,Budgets',
  function()
    local clock, deferred, attempts = 0, {}, 0
    local adapter = fake({
      parse = function(done, tree)
        attempts = attempts + 1
        if attempts <= 2 then
          done('TIMEOUT')
        else
          done(nil, { tree })
        end
      end,
    })
    adapter.now = function()
      return clock
    end
    adapter.defer = function(ms, callback)
      deferred[#deferred + 1] = { ms, callback }
    end
    syntax._test.reset(adapter)
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc abc\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    H.eq(#spans(), 0)
    H.eq(syntax.diagnostics().failures, 1)
    H.eq(#deferred, 1)
    H.eq(deferred[1][1], 1000)
    clock = clock + 1000
    deferred[1][2]()
    assert(vim.wait(1000, function()
      return #deferred == 2
    end, 5))
    H.eq(deferred[2][1], 2000)
    clock = clock + 2000
    deferred[2][2]()
    assert(vim.wait(1000, function()
      return #spans() > 0
    end, 5), 'colors did not return after the backoff expired')
    H.eq(syntax.diagnostics().failures, 0)
    H.eq(attempts, 3)
    syntax._test.reset()
  end
)

H.test('missing parsers still suppress retries', 'Syntax,Parser', function()
  local clock, deferred, loads = 0, 0, 0
  local adapter = fake()
  adapter.now = function()
    return clock
  end
  adapter.defer = function()
    deferred = deferred + 1
  end
  adapter.load = function()
    loads = loads + 1
    return false
  end
  syntax._test.reset(adapter)
  local a = H.fixture()
  H.write(a .. '/one.lua', 'abc abc\n')
  local s = H.search(a)
  view.render(s)
  show_results(s)
  settled()
  H.eq(loads, 1)
  clock = clock + 60000
  syntax.invalidate(s)
  settled()
  H.eq(loads, 1)
  H.eq(deferred, 0)
  H.eq(#spans(), 0)
  syntax._test.reset()
end)

H.test(
  'directives priorities and private conceal captures respect syntax and match layers',
  'Syntax,Captures',
  function()
    syntax._test.reset(fake())
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc abc\n')
    local s = H.search(a, { query = '\\b', regex = true, context = 0 })
    view.render(s)
    show_results(s)
    settled()
    local found = spans()
    H.eq(#found, 1)
    H.eq(vim.list_slice(found[1], 1, 3), { 1, 1, 6 })
    assert(found[1][5] < 2000)
    local overlays = 0
    for _, mark in
      ipairs(view.decorations(s))
    do
      if mark[4].virt_text then
        overlays = overlays + 1
        H.eq(mark[4].priority, 2000)
      end
    end
    H.eq(overlays, #s.results)
    syntax._test.reset()
  end
)

H.test(
  'obsolete asynchronous parsing keeps bounded content and never publishes stale mappings',
  'Syntax,Cancellation',
  function()
    local finish, tree, destroyed
    syntax._test.reset(fake({
      parse = function(done, parsed)
        finish, tree = done, parsed
      end,
      destroy = function()
        destroyed = true
      end,
    }))
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    syntax._test.collect()
    assert(vim.wait(1000, function()
      return finish ~= nil
    end, 5))
    bounds()
    p.close(s)
    H.eq(syntax.diagnostics().demands, 0)
    finish(nil, { tree })
    settled()
    H.eq(syntax.diagnostics().spans, 0)
    syntax._test.reset()
    assert(destroyed)
  end
)

H.test(
  'parent Markdown syntax stays bounded without admitting embedded languages',
  'Syntax,Injections',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.md', '# abc\n\n```python\nabc = "text"\n```\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    H.eq(syntax.diagnostics().languages, 1)
    H.eq(syntax.diagnostics().parsers, 1)
    for _, entry in pairs(syntax._test.entries()) do
      H.eq(entry.lang, 'markdown')
    end
    bounds()
  end
)

H.test('span and bookkeeping admission include in-flight allocations', 'Syntax,Budgets', function()
  local adapter = fake({ captures = 100 })
  adapter.now = function()
    return 0
  end
  syntax._test.reset(adapter, { spans = 4 })
  local a = H.fixture()
  H.write(a .. '/one.lua', 'abc abc\n')
  local s = H.search(a)
  view.render(s)
  settled()
  H.eq(#spans(), 0, 'partial colors must be discarded on exhaustion')
  H.eq(syntax.diagnostics().spans, 0)
  bounds()
  syntax._test.reset(adapter, { managed_bytes = 1024 })
  syntax.invalidate(s)
  settled()
  H.eq(syntax.diagnostics().parsers, 0)
  bounds()
  syntax._test.reset()
end)

H.test(
  'missing language records are bounded and do not consume successful admission slots',
  'Syntax,Budgets',
  function()
    local adapter = fake()
    adapter.language = function(snapshot)
      return vim.fs.basename(snapshot.path):gsub('%.lua$', '')
    end
    adapter.load = function()
      bounds()
      return false
    end
    syntax._test.reset(adapter)
    local a = H.fixture()
    for i = 1, 75 do
      H.write(a .. string.format('/lang%03d.lua', i), 'abc ' .. i .. '\n')
    end
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    for _, result in ipairs(s.results) do
      local position = s.result_positions[result.id]
      vim.api.nvim_win_set_cursor(0, { position.row, 0 })
      vim.api.nvim_win_call(0, function()
        vim.cmd('normal! zt')
      end)
      settled()
      bounds()
    end
    H.eq(syntax.diagnostics().missing, 64)
    H.eq(syntax.diagnostics().languages, 0)
    H.eq(syntax.diagnostics().parsers, 0)
    syntax._test.reset()
  end
)

H.test(
  'off-screen parsers are destroyed and release source references on eviction',
  'Syntax,LRU',
  function()
    local destroyed = 0
    local adapter = fake({
      destroy = function()
        destroyed = destroyed + 1
      end,
    })
    syntax._test.reset(adapter, { parsers = 1 })
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc one\n')
    H.write(a .. '/two.lua', 'abc two\n')
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    show_results(s)
    settled()
    local first = s.snapshots[a .. '/one.lua'].hash .. ':lua'
    assert(syntax._test.entries()[first])
    s.collapsed_paths[a .. '/one.lua'] = true
    view.render(s)
    settled()
    assert(destroyed >= 1)
    H.eq(syntax._test.entries()[first], nil)
    assert(syntax._test.entries()[s.snapshots[a .. '/two.lua'].hash .. ':lua'])
    bounds()
    syntax._test.reset()
  end
)

H.test(
  'multiple windows release hidden demands and replacements and undo recolor snapshots',
  'Syntax,Lifecycle',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local abc = "text"\n')
    local s = H.search(a)
    view.render(s)
    vim.cmd('split')
    settled()
    H.eq(syntax.diagnostics().demands, 2)
    bounds()
    vim.cmd('only')
    settled()
    H.eq(syntax.diagnostics().demands, 1)
    local before = syntax.diagnostics().parses
    H.eq(p.action(s, 'replace_all').applied, 1)
    H.wait(s, 'complete')
    view.render(s)
    settled()
    assert(syntax.diagnostics().parses > before or #s.results == 0)
    local _, buf = H.lines(a .. '/one.lua')
    local generation = s.generation
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('undo')
    end)
    assert(vim.wait(1000, function()
      return s.generation > generation
    end, 5))
    p.refresh(s)
    H.wait(s, 'complete')
    view.render(s)
    settled()
    H.eq(#s.results, 1)
    vim.cmd('tabnew')
    settled()
    H.eq(syntax.diagnostics().demands, 0)
    H.eq(syntax.diagnostics().spans, 0)
  end
)

H.test(
  'real query offsets and overlapping priorities use directive ranges',
  'Syntax,Directives',
  function()
    syntax._test.reset({
      query = function(lang)
        return vim.treesitter.query.parse(
          lang,
          [[
      (string) @string
      ((string) @constant (#offset! @constant 0 1 0 -1) (#set! priority 500))
      (identifier) @_hidden
      ((identifier) @comment (#set! conceal "x"))
    ]]
        )
      end,
    })
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local abc = "雪"\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    local found = spans()
    H.eq(#found, 2)
    table.sort(found, function(left, right)
      return left[2] < right[2]
    end)
    H.eq(vim.list_slice(found[1], 1, 3), { 1, 12, 17 })
    H.eq(vim.list_slice(found[2], 1, 3), { 1, 13, 16 })
    assert(found[2][5] > found[1][5])
    syntax._test.reset()
  end
)

H.test(
  'focused panels reclaim parser capacity from other visible windows',
  'Syntax,Priority',
  function()
    syntax._test.reset()
    local a = H.fixture()
    local panels = {}
    for i = 1, 3 do
      local root = a .. '/root' .. i
      H.write(root .. '/one.lua', 'local abc = ' .. i .. '\n')
      panels[i] = H.search(root)
      view.render(panels[i])
      show_results(panels[i])
      settled()
      bounds()
    end
    local latest = panels[3].snapshots[a .. '/root3/one.lua'].hash .. ':lua'
    assert(syntax._test.entries()[latest], 'focused panel could not reclaim cache capacity')
    p.focus(panels[1].id)
    settled()
    local first = panels[1].snapshots[a .. '/root1/one.lua'].hash .. ':lua'
    assert(syntax._test.entries()[first], 'focus change did not retry plain demand')
    H.eq(syntax.diagnostics().parsers, 2)
  end
)

H.test(
  'runtimepath query changes invalidate spans after Neovim clears its query cache',
  'Syntax,Queries',
  function()
    syntax._test.reset()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'local abc = "text"\n')
    local s = H.search(a)
    view.render(s)
    show_results(s)
    settled()
    local before = syntax.diagnostics()
    local runtime = a .. '/runtime'
    H.write(runtime .. '/queries/lua/highlights.scm', '(string) @constant\n')
    local previous = vim.o.runtimepath
    local ok, err = xpcall(function()
      vim.opt.runtimepath:prepend(runtime)
      vim.wait(60)
      settled()
      H.eq(syntax.diagnostics().parses, before.parses)
      assert(syntax.diagnostics().query_revision > before.query_revision)
      H.eq(#spans(), 1)
    end, debug.traceback)
    vim.o.runtimepath = previous
    vim.wait(60)
    if not ok then
      error(err)
    end
  end
)

H.test(
  'hiding a panel disposes a yielded mapper and its in-flight allocations',
  'Syntax,Cancellation,Budgets',
  function()
    syntax._test.reset(fake())
    local a = H.fixture()
    H.write(a .. '/one.lua', string.rep('local abc = 42\n', 100))
    local s = H.search(a)
    view.render(s)
    show_results(s)
    local results = require('searchlight.results')
    syntax._test.reset(fake())
    local original = results.mappings
    local interrupted, resumed, closed = false, false, false
    results.mappings = function(session, first, last, emit, checkpoint)
      return original(session, first, last, emit, function()
        if not interrupted then
          interrupted = true
          local d = syntax.diagnostics()
          assert(d.managed_bytes > 512, 'mapper scratch was not reserved before mapping')
          bounds()
          vim.schedule(function()
            p.close(s)
            closed = true
          end)
          coroutine.yield()
          resumed = true
        end
        checkpoint()
      end)
    end
    local ok, err = xpcall(function()
      syntax._test.collect()
      assert(vim.wait(1000, function()
        return closed
      end, 5))
      settled()
      assert(interrupted and not resumed, 'obsolete mapper resumed after its panel was hidden')
      local d = syntax.diagnostics()
      H.eq(d.demands, 0)
      H.eq(d.rows, 0)
      H.eq(d.blocks, 0)
      H.eq(d.managed_bytes, 0)
      H.eq(H.read(a .. '/one.lua'), string.rep('local abc = 42\n', 100))
      bounds()
    end, debug.traceback)
    results.mappings = original
    syntax._test.reset()
    if not ok then
      error(err)
    end
  end
)

H.test(
  'failed parsing and missing languages release capacity and honor suppression and reload',
  'Syntax,Parser,Budgets,Queries',
  function()
    local adapter = fake()
    local parser = adapter.parser
    local failed_attempts, missing_attempts = 0, 0
    adapter.now = function()
      return 0
    end
    adapter.language = function(snapshot)
      return snapshot.path:match('/missing.lua$') and 'unavailable' or 'lua'
    end
    adapter.load = function(lang)
      bounds()
      if lang == 'unavailable' then
        missing_attempts = missing_attempts + 1
      end
      return lang == 'lua'
    end
    adapter.parser = function(text, lang)
      local created = parser(text, lang)
      if text:find('failed', 1, true) then
        created.parse = function()
          failed_attempts = failed_attempts + 1
          error('injected parse failure')
        end
      end
      return created
    end
    syntax._test.reset(adapter)
    local a = H.fixture()
    H.write(a .. '/failed.lua', 'abc failed\n')
    H.write(a .. '/good.lua', 'abc good\n')
    H.write(a .. '/missing.lua', 'abc missing\n')
    local s = H.search(a, { query = 'abc', context = 0 })
    view.render(s)
    show_results(s)
    settled()
    local before = syntax.diagnostics()
    H.eq(before.failures, 1)
    H.eq(before.missing, 1)
    H.eq(before.parsers, 1)
    H.eq(before.languages, 1)
    assert(#spans() > 0, 'failed admission prevented the valid source from being colored')
    syntax.invalidate(s)
    settled()
    H.eq(syntax.diagnostics().parses, before.parses)
    H.eq(failed_attempts, 1)
    H.eq(missing_attempts, 1)
    local refreshed = syntax.diagnostics()
    syntax.reload()
    settled()
    H.eq(syntax.diagnostics().parses, before.parses + 1)
    H.eq(syntax.diagnostics().extractions, refreshed.extractions + 1)
    H.eq(syntax.diagnostics().destroyed, before.destroyed + 1)
    H.eq(failed_attempts, 2)
    H.eq(missing_attempts, 2)
    bounds()
    syntax._test.reset()
    local clean = syntax.diagnostics()
    for _, name in ipairs({
      'parsers',
      'retained_bytes',
      'managed_bytes',
      'spans',
      'blocks',
      'rows',
      'demands',
      'languages',
      'failures',
      'missing',
      'groups',
      'chunks',
    }) do
      H.eq(clean[name], 0, 'cleanup retained ' .. name)
    end
  end
)
