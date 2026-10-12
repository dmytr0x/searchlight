local H = require('tests.helpers')
local p = require('searchlight')
local driver = require('searchlight.process')
local function fake(run)
  local original, calls = driver.start, {}
  driver.start = function(argv, opts, done)
    if opts.stdin == '' then
      assert(argv[#argv - 1] ~= '', 'an empty query process was launched')
      vim.schedule(function()
        done({ code = 1 })
      end)
      return { kill = function() end }
    end
    if vim.tbl_contains(argv, '--files-with-matches') then
      -- Report every path as a candidate, so tests drive only inventory and matching.
      local paths = vim.list_slice(argv, vim.fn.index(argv, '--') + 2)
      vim.schedule(function()
        opts.stdout(nil, table.concat(paths, '\0') .. '\0')
        done({ code = 0 })
      end)
      return { kill = function() end }
    end
    local call = { argv = argv, opts = opts, done = done, killed = false }
    table.insert(calls, call)
    return {
      kill = function()
        call.killed = true
      end,
    }
  end
  local ok, err = xpcall(function()
    run(calls)
  end, debug.traceback)
  driver.start = original
  if not ok then
    error(err)
  end
end
local function flush()
  vim.wait(20)
end

H.test('running searches keep their captured result budget', 'Async,Q-08', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  fake(function(calls)
    local s = p.new(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    s.config.max_results = 1
    calls[1].opts.stdout(nil, './one\0')
    calls[1].done({ code = 0 })
    flush()
    calls[2].opts.stdout(nil, vim.json.encode({
      type = 'match',
      data = { line_number = 1, submatches = {
        { start = 0, ['end'] = 3, match = { text = 'abc' } },
        { start = 4, ['end'] = 7, match = { text = 'abc' } },
      } },
    }) .. '\n')
    calls[2].done({ code = 0 })
    H.wait(s, 'complete')
    H.eq(#s.results, 2)
    H.eq(s.incomplete, false)
  end)
end)

for _, phase in ipairs({ 'inventory', 'shadow', 'matching' }) do
  H.test('process start errors settle handles and clean ' .. phase, 'Async', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    H.buffer(a .. '/new', { 'abc' })
    local original = driver.start
    local scope = require('searchlight.scope')
    local shadow, original_shadow = nil, scope.shadow
    scope.shadow = function(...)
      shadow = original_shadow(...)
      return shadow
    end
    local calls = 0
    driver.start = function(_, opts, done)
      calls = calls + 1
      -- Calls 3 and 4 are the tolerant prefilter passes.
      local fail_at = ({ inventory = 1, shadow = 2, matching = 5 })[phase]
      if calls == fail_at then
        error('injected start failure')
      end
      opts.stdout(nil, './one\0')
      done({ code = 0 })
      return { kill = function() end }
    end
    local ok, err = xpcall(function()
      local s = p.new(a)
      p.set(s, { query = 'abc' })
      p.refresh(s)
      H.wait(s, 'error')
      assert(s.message:find('injected start failure', 1, true))
      H.eq(next(s.jobs), nil)
      H.eq(next(s.pending_jobs), nil)
      if shadow then
        H.eq(vim.uv.fs_stat(shadow.cwd), nil)
      end
    end, debug.traceback)
    driver.start, scope.shadow = original, original_shadow
    assert(ok, err)
  end)
end
H.test('source edits cancel searches without automatically restarting', 'Async,S-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local buf = H.buffer(a .. '/one')
  fake(function(calls)
    local s = p.new(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    H.eq(#calls, 1)
    local old = calls[1]
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc edited' })
    flush()
    H.eq(old.killed, true)
    H.eq(s.status, 'stale')
    H.eq(s.timer, nil)
    old.opts.stdout(nil, './one\0')
    old.done({ code = 0 })
    flush()
    H.eq(#calls, 1)
    H.eq(#s.results, 0)
    H.eq(next(s.pending_jobs), nil)
  end)
end)

H.test('queued source edits cannot cancel a later explicit search', 'Async,S-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local buf = H.buffer(a .. '/one')
  fake(function(calls)
    local s = p.new(a)
    p.set(s, { query = 'abc' })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc edited' })
    p.refresh(s)
    local active = calls[1]
    flush()
    H.eq(active.killed, false)
    H.eq(s.status, 'searching')
    active.done({ code = 1 })
    flush()
    H.eq(s.status, 'complete')
    H.eq(#calls, 1)
  end)
end)

H.test(
  'modifier edits cancel running searches and reject their late output',
  'Q-09,Async',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc ABC\n')
    fake(function(calls)
      local s = p.new(a)
      p.set(s, { query = 'abc' })
      p.refresh(s)
      local generation = s.generation
      local heading = '[Search]    Aa[yes]  wd[ ]  .*[ ]  󰥩[ ]  [ ]  ↕[2]'
      vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
      flush()
      assert(s.generation > generation)
      H.eq(s.options.case, true)
      H.eq(calls[1].killed, true)
      calls[1].opts.stdout(nil, './one\0')
      calls[1].done({ code = 0 })
      flush()
      H.eq(#s.results, 0)
      H.eq(#calls, 1)
      H.eq(s.status, 'stale')
      p.refresh(s)
      H.eq(#calls, 2)
      H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, 1, false), { heading })
      calls[2].opts.stdout(nil, './one\0')
      calls[2].done({ code = 0 })
      flush()
      assert(vim.tbl_contains(calls[3].argv, '--case-sensitive'))
      calls[3].done({ code = 1 })
      flush()
      H.eq(s.status, 'complete')
    end)
  end
)
H.test(
  'overlapping generations cancel old jobs and reject late chunks and completion',
  'Async,Q-01',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    fake(function(calls)
      local s = p.new(a)
      p.set(s, { query = 'abc' })
      p.refresh(s)
      H.eq(#calls, 1)
      local old = calls[1]
      p.set(s, { query = 'xyz' })
      p.refresh(s)
      H.eq(old.killed, true)
      old.opts.stdout(nil, './one\0')
      old.done({ code = 0 })
      flush()
      H.eq(#s.results, 0)
      H.eq(#calls, 2)
      calls[2].done({ code = 1 })
      flush()
      H.eq(s.status, 'complete')
      H.eq(#s.results, 0)
    end)
  end
)
H.test('context edits cancel match jobs and reject late context records', 'Q-10,Async', function()
  local a = H.fixture()
  H.write(a .. '/one', 'above\nabc\nbelow\n')
  fake(function(calls)
    local s = p.new(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    calls[1].opts.stdout(nil, './one\0')
    calls[1].done({ code = 0 })
    flush()
    local function match()
      return vim.json.encode({
        type = 'match',
        data = {
          line_number = 2,
          submatches = {
            { start = 0, ['end'] = 3, match = { text = 'abc' }, replacement = { text = 'X' } },
          },
        },
      }) .. '\n'
    end
    calls[2].opts.stdout(nil, match())
    flush()
    H.eq(#s.results, 1)
    local generation = s.generation
    local heading = vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:gsub('↕%[2%]', '↕[0]')
    vim.api.nvim_buf_set_lines(s.buf, 0, 1, false, { heading })
    flush()
    assert(s.generation > generation)
    H.eq(s.options.context, 0)
    H.eq(calls[2].killed, true)
    calls[2].opts.stdout(nil, vim.json.encode({
      type = 'context',
      data = { line_number = 3, lines = { text = 'late context\n' } },
    }) .. '\n')
    calls[2].done({ code = 0 })
    flush()
    H.eq(#calls, 2)
    H.eq(s.status, 'stale')
    p.refresh(s)
    calls[3].opts.stdout(nil, './one\0')
    calls[3].done({ code = 0 })
    flush()
    assert(vim.tbl_contains(calls[4].argv, '--context=0'))
    calls[4].opts.stdout(nil, match())
    calls[4].done({ code = 0 })
    flush()
    H.eq(s.status, 'complete')
    H.eq(#s.results, 1)
    H.eq(s.results[1].generation, s.generation)
    H.eq(s.results[1].snapshot.context_lines, {})
  end)
end)
H.test(
  'deleting during work rejects late callbacks while another session finishes',
  'S-04,Async',
  function()
    local a, b = H.fixture()
    fake(function(calls)
      local sa = p.new(a)
      p.set(sa, { query = 'abc' })
      p.refresh(sa)
      local sb = p.new(b)
      p.set(sb, { query = 'xyz' })
      p.refresh(sb)
      p.close(sa)
      H.eq(calls[1].killed, true)
      H.eq(calls[2].killed, false)
      calls[1].opts.stdout(nil, './bogus\0')
      calls[1].done({ code = 0 })
      calls[2].done({ code = 1 })
      flush()
      H.eq(sb.status, 'complete')
      H.eq(next(sb.jobs), nil)
    end)
  end
)
H.test(
  'clearing query cancels debounce and processes without an empty search',
  'Q-01,Async',
  function()
    local a = H.fixture()
    fake(function(calls)
      local s = p.new(a)
      p.set(s, { query = 'abc' })
      p.set(s, { query = '' })
      vim.wait(30)
      H.eq(#calls, 0)
      H.eq(s.timer, nil)
      p.set(s, { query = 'abc' })
      p.refresh(s)
      H.eq(#calls, 1)
      p.set(s, { query = '' })
      calls[1].done({ code = 0 })
      flush()
      H.eq(s.status, 'empty')
      H.eq(#calls, 1)
      H.eq(next(s.jobs), nil)
    end)
  end
)
H.test('each search-affecting field supersedes queued output', 'Q-05,Q-08,R-02,Async', function()
  local a, b = H.fixture()
  fake(function(calls)
    local s = p.new(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    for _, change in ipairs({
      { replacement = 'Y' },
      { include = { '*.lua' } },
      { exclude = { 'skip*' } },
      { case = true },
      { word = true },
      { regex = true },
      { open = true },
      { ignored = true },
      { context = 3 },
      { root = b },
    }) do
      local old = calls[#calls]
      old.opts.stdout(nil, './one\0')
      p.set(s, change)
      p.refresh(s)
      old.done({ code = 0 })
      flush()
      H.eq(s.status, 'searching')
      H.eq(#s.results, 0)
      H.eq(old.killed, true)
    end
    calls[#calls].done({ code = 1 })
    flush()
    H.eq(s.status, 'complete')
  end)
end)
H.test(
  'stderr and error exit cannot enable partial matches for replacement',
  'Async,R-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    fake(function(calls)
      local s = p.new(a)
      p.set(s, { query = 'abc' })
      p.refresh(s)
      calls[1].opts.stdout(nil, './one\0')
      calls[1].done({ code = 0 })
      flush()
      H.eq(#calls, 2)
      local payload = {
        type = 'match',
        data = {
          line_number = 1,
          submatches = {
            { start = 0, ['end'] = 3, match = { text = 'abc' }, replacement = { text = 'X' } },
          },
        },
      }
      calls[2].opts.stdout(nil, vim.json.encode(payload) .. '\n')
      flush()
      H.eq(#s.results, 1)
      calls[2].opts.stderr(nil, 'test process failure')
      calls[2].done({ code = 2 })
      flush()
      H.eq(s.status, 'error')
      assert(s.results[1].stale)
      H.eq(p.action(s, 'replace_all'), nil)
    end)
  end
)
H.test(
  'bounded process queue rejects oversized output and cancellation settles handles',
  'Async',
  function()
    local a = H.fixture()
    fake(function(calls)
      local s = p.new(a)
      s.config.max_output_bytes = 64
      p.set(s, { query = 'abc' })
      p.refresh(s)
      calls[1].opts.stdout(nil, string.rep('x', 65))
      flush()
      H.eq(calls[1].killed, true)
      H.eq(s.status, 'error')
      calls[1].done({ code = 143 })
      flush()
      H.eq(next(s.jobs), nil)
    end)
  end
)
H.test(
  'disk edit during search cannot turn a post-search fingerprint into a valid edit',
  'R-05,Async',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc old\n')
    fake(function(calls)
      local s = p.new(a)
      p.set(s, { query = 'abc', replacement = 'X' })
      p.refresh(s)
      calls[1].opts.stdout(nil, './one\0')
      calls[1].done({ code = 0 })
      flush()
      H.eq(calls[2].opts.stdin, 'abc old\n')
      H.write(a .. '/one', 'abc new\n')
      calls[2].opts.stdout(nil, vim.json.encode({
        type = 'match',
        data = {
          line_number = 1,
          submatches = {
            { start = 0, ['end'] = 3, match = { text = 'abc' }, replacement = { text = 'X' } },
          },
        },
      }) .. '\n')
      calls[2].done({ code = 0 })
      flush()
      H.eq(s.status, 'complete')
      H.eq(p.action(s, 'replace_all').stale, 1)
      H.eq(H.read(a .. '/one'), 'abc new\n')
    end)
  end
)
H.test('buffer job concurrency stays bounded', 'Async,B-01', function()
  local a = H.fixture()
  for i = 1, 8 do
    H.write(a .. '/file' .. i, 'abc\n')
  end
  fake(function(calls)
    local s = p.new(a)
    s.config.concurrency = 2
    p.set(s, { query = 'abc' })
    p.refresh(s)
    local paths = ''
    for i = 1, 8 do
      paths = paths .. './file' .. i .. '\0'
    end
    calls[1].opts.stdout(nil, paths)
    calls[1].done({ code = 0 })
    flush()
    H.eq(#calls, 3)
    for i = 2, 9 do
      calls[i].done({ code = 1 })
      flush()
      assert(#calls <= math.min(9, i + 2))
    end
    H.eq(s.status, 'complete')
    H.eq(next(s.jobs), nil)
  end)
end)
H.test(
  'a capped generation cannot apply while cancelled child handles are unsettled',
  'Async,R-03',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    fake(function(calls)
      local s = p.new(a)
      s.config.max_results = 1
      p.set(s, { query = 'abc', replacement = 'X' })
      p.refresh(s)
      calls[1].opts.stdout(nil, './one\0')
      calls[1].done({ code = 0 })
      flush()
      calls[2].opts.stdout(nil, vim.json.encode({
        type = 'match',
        data = {
          line_number = 1,
          submatches = {
            { start = 0, ['end'] = 3, match = { text = 'abc' }, replacement = { text = 'X' } },
            { start = 4, ['end'] = 7, match = { text = 'abc' }, replacement = { text = 'X' } },
          },
        },
      }) .. '\n')
      flush()
      H.eq(s.status, 'truncated')
      H.eq(calls[2].killed, true)
      H.eq(p.action(s, 'replace_next'), nil)
      assert(s.message:find('handles'))
      calls[2].done({ code = 143 })
      flush()
      H.eq(next(s.pending_jobs), nil)
      H.eq(p.action(s, 'replace_next').applied, 1)
      -- Complete the inventory started by the applying session's refresh.
      calls[#calls].done({ code = 1 })
      flush()
    end)
  end
)
H.test('buffer edits during snapshot jobs invalidate old matches', 'R-05,B-01,Async', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local buf = H.buffer(a .. '/one')
  fake(function(calls)
    local s = p.new(a)
    p.set(s, { query = 'abc' })
    p.refresh(s)
    calls[1].opts.stdout(nil, './one\0')
    calls[1].done({ code = 0 })
    flush()
    require('searchlight.sources').mutating = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc changed' })
    require('searchlight.sources').mutating = false
    calls[2].done({ code = 1 })
    flush()
    H.eq(s.status, 'stale')
    H.eq(p.action(s, 'replace_all'), nil)
  end)
end)
