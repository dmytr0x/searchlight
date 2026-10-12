local H = require('tests.helpers')
local p = require('searchlight')
local rg = require('searchlight.rg')
H.test('invalid regex is reported even in an empty or open-only scope', 'Q-04', function()
  local a = H.fixture()
  local s = H.search(a, { query = '[', regex = true })
  H.eq(s.status, 'error')
  assert(s.message:find('regex'))
  H.update(s, { query = 'abc', open = true })
  H.eq(#s.results, 0)
  H.update(s, { query = '[' }, 'error')
end)
H.test(
  'rejected API updates leave completed fields and edit plans coherent',
  'Q-08,R-02',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local s = H.search(a)
    local before = vim.deepcopy(s.fields)
    local gen = s.generation
    H.eq(pcall(p.set, s, { query = 'xyz', replacement = 'Y', unknown = true }), false)
    H.eq(s.fields, before)
    H.eq(s.generation, gen)
    H.eq(s.status, 'complete')
  end
)
H.test(
  'aggregate snapshot memory is bounded and no-hit contents are released',
  'Async,R-04',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    H.write(a .. '/two', 'abc abc\n')
    local s = p.new(a)
    s.config.max_snapshot_bytes = 8
    H.update(s, { query = 'abc' }, 'truncated')
    H.eq(#s.results, 2)
    assert(s.message:find('snapshot byte budget'))
    H.eq(p.action(s, 'replace_all'), nil)
    H.update(s, { query = 'nomatch' })
    H.eq(s.snapshot_bytes, 0)
    for _, snap in pairs(s.snapshots) do
      H.eq(snap.text, nil)
      H.eq(snap.lines, nil)
    end
  end
)
H.test('empty query is idle and one character searches', 'Q-01', function()
  local a = H.fixture()
  H.write(a .. '/one', 'a\n')
  local s = p.new(a)
  H.eq(s.status, 'empty')
  H.eq(next(s.jobs), nil)
  H.update(s, { query = 'a' })
  H.eq(#s.results, 1)
  p.set(s, { query = '' })
  H.eq(s.status, 'empty')
  H.eq(#s.results, 0)
  H.eq(next(s.jobs), nil)
end)
H.test(
  'case control overrides smart-case and whole word respects boundaries',
  'Q-02,Q-03',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc ABC abcd abc_ abc.\n')
    local s = H.search(a)
    H.eq(#s.results, 5)
    H.update(s, { case = true })
    H.eq(#s.results, 4)
    H.update(s, { word = true })
    H.eq(#s.results, 2)
    H.update(s, { case = false })
    H.eq(#s.results, 3)
  end
)
H.test('literal punctuation, leading dash query and invalid regex', 'Q-04', function()
  local a = H.fixture()
  H.write(a .. '/-file name.txt', 'a.b axb -n\n')
  local s = H.search(a, { query = 'a.b', replacement = '-X', regex = false })
  H.eq(#s.results, 1)
  H.update(s, { regex = true })
  H.eq(#s.results, 2)
  H.update(s, { query = '-n', regex = false })
  H.eq(#s.results, 1)
  H.update(s, { query = '[', regex = true }, 'error')
  assert(s.message:find('regex'))
  assert(not p.action(s, 'replace_all'))
end)
H.test('includes are a union, exclusions win, multiple filter lines', 'Q-05', function()
  local a = H.fixture()
  for _, file in ipairs({ 'one.lua', 'two.txt', 'three.md', 'skip.lua', 'nested/four.lua' }) do
    H.write(a .. '/' .. file, 'abc\n')
  end
  local s = H.search(
    a,
    { query = 'abc', include = { '*.lua', '*.txt' }, exclude = { 'skip.*', 'nested/**' } }
  )
  H.eq(#s.results, 2)
  assert(s.results[1].path:match('one.lua$'))
  assert(s.results[2].path:match('two.txt$'))
  H.update(s, { include = { '!*.lua' } }, 'error')
end)
H.test('comma-separated filters share disk and unsaved open-buffer policy', 'Q-05,B-01', function()
  local a = H.fixture()
  local files = {
    'doc.md',
    'main.py',
    'myproject/src/keep.lua',
    'notes.txt',
    'other.lua',
    'skip.md',
    'generated/doc.md',
    'vendor/main.py',
    'myproject/src/skip.lua',
  }
  for _, file in ipairs(files) do
    H.write(a .. '/' .. file, 'abc\n')
  end
  local s = H.search(a, {
    query = 'abc',
    include = { ' , *.md, *.py, *project*/**/*.lua, ', '*.txt' },
    exclude = { ' skip.*, generated/** ', 'vendor/**, *project*/**/skip.lua, ,' },
  })
  local function names()
    local paths = {}
    for _, result in ipairs(s.results) do
      table.insert(paths, require('searchlight.scope').relative(s.root, result.path))
    end
    table.sort(paths)
    return paths
  end
  local expected = { 'doc.md', 'main.py', 'myproject/src/keep.lua', 'notes.txt' }
  H.eq(names(), expected)
  for _, file in ipairs(files) do
    H.buffer(a .. '/' .. file, { 'abc' })
    assert(vim.uv.fs_unlink(a .. '/' .. file))
  end
  H.update(s, { open = true })
  H.eq(names(), expected)
  H.update(s, { open = false })
  H.eq(names(), expected)
end)
H.test('filter separators preserve brace, character-class and escaped commas', 'Q-05', function()
  local a = H.fixture()
  for _, file in ipairs({
    'one.md',
    'two.py',
    'three.lua',
    'notes,draft.txt',
    'file,txt',
    'file.txt',
    'skip,a.md',
    'skip,b.py',
    'other.txt',
  }) do
    H.write(a .. '/' .. file, 'abc\n')
  end
  local s = H.search(a, {
    query = 'abc',
    include = { '*.{md,py}, file[,.]txt, notes\\,draft.txt, *.lua' },
    exclude = { '*.lua, skip\\,*.{md,py}' },
  })
  local names = {}
  for _, result in ipairs(s.results) do
    table.insert(names, vim.fs.basename(result.path))
  end
  table.sort(names)
  H.eq(names, { 'file,txt', 'file.txt', 'notes,draft.txt', 'one.md', 'two.py' })
end)
H.test(
  'empty filter declarations are ignored and every declaration is validated',
  'Q-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one.lua', 'abc\n')
    local s = H.search(a, { query = 'abc', include = { ', ,', ' ' }, exclude = { ', ,' } })
    H.eq(#s.results, 1)
    H.update(s, { include = { '*.lua, !*.md' } }, 'error')
    assert(s.message:find('Include globs must be positive', 1, true))
    H.update(s, { include = { '*.lua' }, exclude = { '*.md, !*.lua' } }, 'error')
    assert(s.message:find('Exclude globs must be positive', 1, true))
  end
)
H.test('root and controls belong to their own session', 'Q-08,S-02', function()
  local a, b = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  H.write(b .. '/two', 'ABC\n')
  local sa, sb = H.search(a), H.search(b)
  local generation = sb.generation
  p.navigate(sa, 1)
  H.update(sa, { root = b, case = true })
  H.eq(#sa.results, 0)
  H.eq(sb.generation, generation)
  H.eq(#sb.results, 1)
  H.eq(sb.fields.query, 'abc')
end)
H.test('long lines and Unicode use byte columns', 'R-01,Q-01', function()
  local a = H.fixture()
  H.write(a .. '/one', 'λ雪 ' .. string.rep('z', 200) .. ' abc abc\n')
  local s = H.search(a)
  H.eq(#s.results, 2)
  H.eq(s.results[1].start, 207)
  H.eq(s.results[2].start, 211)
  assert(#s.results[1].context > 100)
end)
H.test('expanded capture preview and dollar semantics use real ripgrep', 'R-02', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  local s = H.search(a, { query = 'a(?P<mid>b)c', replacement = '$1-${mid}-$$', regex = true })
  H.eq(s.results[1].replacement, 'b-b-$')
  H.eq(require('searchlight.replace').preview(s.results[1]), 'b-b-$ abc')
  H.update(s, { replacement = '' })
  H.eq(s.results[1].replacement, '')
  H.update(s, { replacement = '-new' })
  H.eq(s.results[1].replacement, '-new')
end)
H.test('fragmented JSON and base64 byte values decode losslessly', 'Async,R-01', function()
  local records = {}
  local decode = rg.decoder(function(record)
    table.insert(records, record)
  end, 1024)
  local text = vim.json.encode({
    type = 'match',
    data = { lines = { bytes = vim.base64.encode('\255abc') } },
  }) .. '\n'
  for i = 1, #text do
    decode(text:sub(i, i), false)
  end
  decode('', true)
  H.eq(#records, 1)
  H.eq(rg.value(records[1].data.lines), '\255abc')
  H.eq(pcall(decode, string.rep('x', 1025), false), false)
end)
H.test('split keeps records cut across chunk boundaries at every offset', 'Async', function()
  local text = 'one\0two\0three\0'
  for i = 0, #text do
    for j = i, #text do
      local records = {}
      local split = rg.split('\0', function(record)
        table.insert(records, record)
      end, 1024)
      split(text:sub(1, i), false)
      split(text:sub(i + 1, j), false)
      split(text:sub(j + 1), false)
      H.eq(split(nil, true), '')
      H.eq(records, { 'one', 'two', 'three' }, 'cut at ' .. i .. ',' .. j)
    end
  end
  local split = rg.split('\0', function() end, 1024)
  split('one\0tw', false)
  H.eq(split(nil, true), 'tw')
end)
H.test('capped results block Replace all but allow validated Replace next', 'R-04,Async', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc abc abc\n')
  local s = p.new(a)
  s.config.max_results = 2
  H.update(s, { query = 'abc', replacement = 'X' }, 'truncated')
  H.eq(#s.results, 2)
  local report = p.action(s, 'replace_all')
  H.eq(report, nil)
  assert(p.action(s, 'replace_next'))
  H.eq(H.lines(a .. '/one'), { 'X abc abc abc' })
  s.config.max_results = 10
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(#s.results, 3)
end)
H.test('exactly the cap is a complete result set', 'Async,R-04', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  local s = p.new(a)
  s.config.max_results = 2
  H.update(s, { query = 'abc' })
  H.eq(s.incomplete, false)
  H.eq(#s.results, 2)
end)
H.test('unsupported inherited output and engine flags are a visible error', 'Q-04,Async', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  H.write(H.root .. '/rgconfig', '--pcre2\n')
  local s = H.search(a)
  H.eq(s.status, 'error')
  assert(s.message:find('Unsupported'))
  H.update(s, { ignored = true })
  H.eq(#s.results, 1)
end)
H.test('snapshot limit and inventory limit cannot claim complete coverage', 'Async,R-04', function()
  local a = H.fixture()
  H.write(a .. '/one', string.rep('abc', 100))
  H.write(a .. '/two', 'abc')
  local s = p.new(a)
  s.config.max_source_bytes = 20
  H.update(s, { query = 'abc' }, 'truncated')
  assert(s.message:find('Skipped'))
  H.eq(p.action(s, 'replace_all'), nil)
  s.config.max_source_bytes, s.config.max_files = 1000, 1
  p.refresh(s)
  H.wait(s, 'error')
  assert(s.message:find('inventory cap'))
end)
H.test('older ripgrep can search but cannot guess replacement expansion', 'R-02,R-07', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local original = rg.probe
  rg.probe = function()
    return { search = true, replacement = false, reason = 'capture expansion unavailable' }
  end
  local ok, err = xpcall(function()
    local s = H.search(a)
    H.eq(#s.results, 1)
    H.eq(s.results[1].replacement, nil)
    H.eq(p.action(s, 'replace_all'), nil)
    assert(s.message:find('unavailable'))
    H.eq(H.read(a .. '/one'), 'abc\n')
  end, debug.traceback)
  rg.probe = original
  if not ok then
    error(err)
  end
end)
