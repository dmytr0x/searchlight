-- Fresh-process enabled/disabled runs are compared by syntax_benchmark.py.
local H = dofile('tests/nvim/helpers.lua')
local p = require('searchlight')
local view = require('searchlight.view')
local syntax = require('searchlight.highlight')
local enabled = vim.env.SEARCHLIGHT_SYNTAX == '1'
p.setup({ debounce_ms = 10, syntax_highlighting = enabled, syntax_injections = enabled })
-- Launches below expect the startup ripgrep probe to have settled.
assert(vim.wait(5000, function()
  return require('searchlight.rg').probe() ~= nil
end))
local root = H.fixture()
local samples, first_results, navigation, drawing, scrolling, memory = {}, {}, {}, {}, {}, {}
local heartbeat_gaps = {}
local peak_heap, peak_rss, largest_gap, last, phase = 0, 0, 0, vim.uv.hrtime(), 'fixtures'
local timer = vim.uv.new_timer()
local function rss()
  return vim.uv.resident_set_memory()
end
local function measure_memory()
  peak_heap = math.max(peak_heap, collectgarbage('count') * 1024)
  peak_rss = math.max(peak_rss, rss())
  local d = syntax.diagnostics()
  for name, value in pairs(d.high_water) do
    assert(not d.limits[name] or value <= d.limits[name], 'in-flight budget exceeded: ' .. name)
    samples[name] = math.max(samples[name] or 0, value)
  end
  for _, name in ipairs({
    'parsers',
    'retained_bytes',
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
    assert(d[name] >= 0 and d[name] <= d.limits[name], 'budget exceeded: ' .. name)
    samples[name] = math.max(samples[name] or 0, d[name])
  end
end
timer:start(
  0,
  1,
  vim.schedule_wrap(function()
    local time = vim.uv.hrtime()
    local gap = (time - last) / 1e6
    if phase == 'worker' then
      largest_gap = math.max(largest_gap, gap)
      heartbeat_gaps[#heartbeat_gaps + 1] = gap
    end
    last = time
    measure_memory()
  end)
)

local function settled()
  phase, last = 'worker', vim.uv.hrtime()
  syntax._test.collect()
  assert(
    vim.wait(5000, function()
      if syntax.diagnostics().busy then
        return false
      end
      for _, d in pairs(syntax._test.demands()) do
        if not d.done then
          return false
        end
      end
      return true
    end, 1),
    'syntax timed out'
  )
  local final_gap = (vim.uv.hrtime() - last) / 1e6
  largest_gap = math.max(largest_gap, final_gap)
  heartbeat_gaps[#heartbeat_gaps + 1] = final_gap
  measure_memory()
  phase = 'interaction'
end
local function search(path, options)
  local s = p.new(path)
  local first, parses = nil, syntax.diagnostics().parses
  local start = vim.uv.hrtime()
  local observer = vim.uv.new_timer()
  observer:start(
    0,
    1,
    vim.schedule_wrap(function()
      if not first and #s.results > 0 then
        first = (vim.uv.hrtime() - start) / 1e6
        assert(syntax.diagnostics().parses == parses, 'syntax ran before first results')
      end
    end)
  )
  phase = 'search'
  p.set(s, options or { query = 'abc', context = 0 })
  p.refresh(s)
  H.wait(s)
  observer:stop()
  observer:close()
  view.render(s)
  first_results[#first_results + 1] = first or (vim.uv.hrtime() - start) / 1e6
  settled()
  return s
end
local function timed(array, fn)
  local started = vim.uv.hrtime()
  fn()
  array[#array + 1] = (vim.uv.hrtime() - started) / 1e6
end

local ok, err = xpcall(function()
  for _, density in ipairs({ 'dense', 'sparse' }) do
    local dir = root .. '/' .. density
    for i = 1, 200 do
      local line = i % 2 == 0 and ('local abc = ' .. i .. ' -- abc\n')
        or ('int abc = ' .. i .. '; /* abc */\n')
      local text = string.rep(line, 25)
      if density == 'sparse' then
        text = string.rep(line .. string.rep('-- padding\n', 10), 25)
      end
      H.write(dir .. string.format('/file%03d.%s', i, i % 2 == 0 and 'lua' or 'c'), text)
    end
    local s = search(dir)
    H.eq(#s.results, 10000)
    p.navigate(s, -10000)
    settled()
    local before = syntax.diagnostics()
    for i = 1, 60 do
      timed(navigation, function()
        p.navigate(s, i % 2 == 0 and -1 or 1)
      end)
    end
    H.eq(syntax.diagnostics().parses, before.parses)
    H.eq(syntax.diagnostics().extractions, before.extractions)
    for _ = 1, 60 do
      timed(drawing, function()
        vim.cmd('redraw!')
      end)
    end
    for i = 1, 30 do
      local position = s.result_positions[s.results[1 + (i * 299) % #s.results].id]
      timed(scrolling, function()
        vim.api.nvim_win_set_cursor(0, { position.row, position.col })
        vim.cmd('normal! zt')
        vim.cmd('redraw!')
      end)
      settled()
    end
    p.close(s)
    settled()
  end

  local stress = root .. '/stress'
  local dense_line = 'local abc = 42 -- abc abc abc\n'
  H.write(
    stress .. '/dense.lua',
    string.rep(dense_line, math.floor((128 * 1024 - 32) / #dense_line))
  )
  H.write(stress .. '/large.lua', string.rep(dense_line, math.floor((240 * 1024) / #dense_line)))
  H.write(stress .. '/oversized.lua', string.rep('-- abc\n', 40000))
  H.write(stress .. '/long.lua', 'local abc = "' .. string.rep('x', 5000) .. '"\n')
  H.write(stress .. '/embedded.md', '# abc\n\n```lua\nlocal abc = "abc"\n```\n')
  local s = search(stress)
  if enabled then
    assert(syntax.diagnostics().spans > 0, 'source just below the default cap was not exercised')
  end
  for _ = 1, 20 do
    p.set(s, { query = '42' })
    p.refresh(s)
    p.set(s, { query = 'abc' })
    p.refresh(s)
  end
  H.wait(s)
  view.render(s)
  settled()
  p.close(s)

  for _, name in ipairs({ 'large.lua', 'oversized.lua', 'long.lua', 'embedded.md' }) do
    local parses = syntax.diagnostics().parses
    local panel = search(stress, { query = 'abc', include = { name } })
    if name == 'large.lua' then
      -- String parses do not honor Neovim's async timeout. Above-cap snapshots
      -- must stay plain so the default workload still meets the heartbeat gate.
      H.eq(syntax.diagnostics().rows, 0)
      H.eq(syntax.diagnostics().parses, parses)
    end
    if enabled and name == 'embedded.md' then
      assert(syntax.diagnostics().rows > 0, 'embedded parent syntax was not exercised')
    end
    p.close(panel)
    settled()
  end

  -- Embedded languages: Lua blocks in help buffers and fenced code in Markdown.
  local docs = root .. '/docs'
  for _, name in ipairs({
    'change.txt',
    'autocmd.txt',
    'treesitter.txt',
    'diagnostic.txt',
    'api-ui-events.txt',
  }) do
    H.write(docs .. '/' .. name, H.read(vim.env.VIMRUNTIME .. '/doc/' .. name))
    H.buffer(docs .. '/' .. name, nil, { filetype = 'help' })
  end
  H.write(
    docs .. '/fences.md',
    string.rep('# vim\n\n```lua\nlocal vim = vim.api\n```\n\n```c\nint vim = 1;\n```\n\n', 400)
  )
  local panel = search(docs, { query = 'vim', context = 2 })
  for i = 1, 30 do
    local position = panel.result_positions[panel.results[1 + (i * 97) % #panel.results].id]
    vim.api.nvim_win_set_cursor(0, { position.row, position.col })
    vim.cmd('normal! zt')
    vim.cmd('redraw!')
    settled()
  end
  if enabled then
    assert(syntax.diagnostics().languages > 3, 'injected languages were not exercised')
  end
  p.close(panel)
  settled()

  local cycles = root .. '/cycles'
  H.write(cycles .. '/one.lua', 'local abc = "abc"\nreturn abc\n')
  for i = 1, 100 do
    local panel = p.new(cycles)
    p.set(panel, { query = 'abc', replacement = 'abc' .. i, context = 1 })
    p.refresh(panel)
    H.wait(panel, 'complete')
    view.render(panel)
    settled()
    if i % 10 == 0 then
      H.eq(p.action(panel, 'replace_all').applied, 3)
      H.wait(panel, 'complete')
      view.render(panel)
      settled()
    end
    if i % 25 == 0 then
      memory[#memory + 1] = { cycle = i, rss = rss(), heap = collectgarbage('count') * 1024 }
    end
    p.close(panel)
    -- Use the same window lifecycle in both runs.
    vim.cmd('silent! only!')
    settled()
  end
  local panels = {}
  for i = 1, 10 do
    panels[i] = p.new(cycles)
    p.set(panels[i], { query = 'abc' })
    p.refresh(panels[i])
    H.wait(panels[i])
    view.render(panels[i])
  end
  settled()
  vim.cmd('tabnew')
  settled()
  H.eq(syntax.diagnostics().demands, 0)
  vim.cmd('tabprevious')
  settled()
  for _, panel in ipairs(panels) do
    p.close(panel)
  end
  settled()
  local working_set = syntax.diagnostics()
  H.cleanup()
  settled()
  syntax._test.reset()
  collectgarbage('collect') -- Acceptance cleanup only; never done by the runtime manager.
  collectgarbage('collect')
  local clean = syntax.diagnostics()
  H.eq(clean.parsers, 0)
  H.eq(clean.spans, 0)
  local output = {
    enabled = enabled,
    first_results_ms = first_results,
    navigation_ms = navigation,
    drawing_ms = drawing,
    scroll_ms = scrolling,
    longest_worker_heartbeat_gap_ms = largest_gap,
    worker_heartbeat_gaps_ms = heartbeat_gaps,
    sampled_peak_rss = peak_rss,
    peak_lua_heap = peak_heap,
    recovered_rss = rss(),
    recovered_lua_heap = collectgarbage('count') * 1024,
    cycles = memory,
    peaks = samples,
    working_set = working_set,
  }
  H.write(assert(vim.env.SEARCHLIGHT_BENCH_OUTPUT), vim.json.encode(output))
end, debug.traceback)
timer:stop()
timer:close()
H.cleanup()
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit(1)
else
  vim.cmd.qa({ bang = true })
end
