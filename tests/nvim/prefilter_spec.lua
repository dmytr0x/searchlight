local H = require('tests.helpers')
local p = require('searchlight')
local process = require('searchlight.process')
local rg = require('searchlight.rg')

local function prefiltering(argv)
  return vim.tbl_contains(argv, '--files-with-matches')
end

-- Runs `run` while counting stdin match processes; `disabled` makes prefilter spawns fail.
local function with_driver(disabled, run)
  local original, counts = process.start, { prefilter = 0, match = 0 }
  process.start = function(argv, opts, done)
    if prefiltering(argv) then
      counts.prefilter = counts.prefilter + 1
      if disabled then
        error('injected prefilter spawn failure')
      end
    elseif argv[#argv] == '-' then
      counts.match = counts.match + 1
    end
    return original(argv, opts, done)
  end
  local ok, err = xpcall(run, debug.traceback, counts)
  process.start = original
  assert(ok, err)
  return counts
end

local function hits(s)
  local list = {}
  for _, r in ipairs(s.results) do
    table.insert(list, { r.path, r.line, r.start, r.finish, r.match })
  end
  table.sort(list, function(x, y)
    return table.concat(x, ':') < table.concat(y, ':')
  end)
  return list
end

H.test('prefilter keeps Latin-1 sources whose decoded text matches', 'Prefilter', function()
  local a = H.fixture()
  H.write(a .. '/latin', 'caf\233\n')
  H.write(a .. '/other', 'nothing\n')
  local counts = with_driver(false, function()
    local s = H.search(a, { query = 'caf.', regex = true })
    H.eq(s.status, 'complete')
    H.eq(hits(s), { { a .. '/latin', 1, 0, 5, 'café' } })
  end)
  H.eq(counts.match, 1)
end)

H.test('prefilter keeps CRLF sources for end-of-line anchors', 'Prefilter', function()
  local a = H.fixture()
  H.write(a .. '/crlf', 'abc\r\nxyz\r\n')
  local s = H.search(a, { query = 'abc$', regex = true })
  H.eq(s.status, 'complete')
  H.eq(hits(s), { { a .. '/crlf', 1, 0, 3, 'abc' } })
end)

H.test('prefilter keeps UTF-16 BOM sources', 'Prefilter', function()
  local a = H.fixture()
  H.write(a .. '/wide', vim.iconv('\239\187\191abc\n', 'utf-8', 'utf-16le'))
  local s = H.search(a, { query = '^abc', regex = true })
  H.eq(s.status, 'complete')
  H.eq(hits(s), { { a .. '/wide', 1, 0, 3, 'abc' } })
end)

H.test('prefilter keeps modified buffers whose disk copy has no match', 'Prefilter', function()
  local a = H.fixture()
  H.write(a .. '/one', 'old\n')
  local buf = H.buffer(a .. '/one', { 'abc' })
  H.eq(vim.bo[buf].modified, true)
  local s = H.search(a)
  H.eq(s.status, 'complete')
  H.eq(hits(s), { { a .. '/one', 1, 0, 3, 'abc' } })
end)

H.test('mixed line endings only make a search incomplete when they match on disk', 'Prefilter', function()
  local a = H.fixture()
  H.write(a .. '/mixed', 'xyz\r\nxyz\rxyz\n')
  H.write(a .. '/one', 'abc\n')
  local s = H.search(a)
  H.eq(s.status, 'complete')
  H.eq(s.incomplete, false)
  H.eq(#s.results, 1)
  H.update(s, { query = 'xyz' }, 'truncated')
  H.eq(s.incomplete, true)
end)

H.test('prefilter spawn failure falls back to every source', 'Prefilter', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  H.write(a .. '/two', 'none\n')
  local counts = with_driver(true, function()
    local s = H.search(a)
    H.eq(s.status, 'complete')
    H.eq(hits(s), { { a .. '/one', 1, 0, 3, 'abc' } })
  end)
  assert(counts.prefilter > 0, 'prefilter was not attempted')
  H.eq(counts.match, 2)
end)

H.test('prefilter results equal unfiltered results', 'Prefilter', function()
  local a = H.fixture()
  local bodies = {
    'abc\n',
    'ABC abc_ xabc\n',
    'abc\r\nabc\r\n',
    'abc\r\nabc\rabc\n',
    'caf\233 abc\n',
    '\239\187\191abc\n',
    'nothing here\n',
    'ab\nc\n',
  }
  for i = 1, 60 do
    H.write(a .. string.format('/d%d/f%02d', i % 4, i), bodies[i % #bodies + 1])
  end
  H.buffer(a .. '/d0/f04', { 'abc modified' })
  H.buffer(a .. '/new', { 'abc new' })
  for _, query in ipairs({
    { query = 'abc' },
    { query = 'abc', word = true, case = true },
    { query = 'abc$', regex = true },
    { query = 'caf.', regex = true },
    { query = '-abc' },
    { query = 'zzz' },
  }) do
    local unfiltered, filtered
    with_driver(true, function()
      unfiltered = H.search(a, query)
    end)
    local counts = with_driver(false, function()
      filtered = H.search(a, query)
    end)
    -- Only a mixed-ending file without a disk hit may stop truncating the run.
    if filtered.status ~= unfiltered.status then
      H.eq({ filtered.status, unfiltered.status }, { 'complete', 'truncated' }, vim.inspect(query))
    end
    H.eq(hits(filtered), hits(unfiltered), vim.inspect(query))
    p.close(unfiltered)
    p.close(filtered)
    assert(counts.match < 62, 'prefilter did not reduce sources for ' .. vim.inspect(query))
  end
end)

H.test('prefilter splits long path lists into bounded batches', 'Prefilter', function()
  local paths = {}
  for i = 1, 3000 do
    paths[i] = string.format('%04d', i) .. string.rep('x', 196)
  end
  local request = { fields = { query = 'abc' }, options = { case = false } }
  for _, batches in ipairs({ rg.prefilter(request, paths), rg.decode_sensitive(paths) }) do
    H.eq(#batches, 3)
    local seen = {}
    for _, argv in ipairs(batches) do
      local size = 0
      for _, arg in ipairs(argv) do
        size = size + #arg + 1
      end
      assert(size <= 256 * 1024, 'batch exceeds argv budget: ' .. size)
      vim.list_extend(seen, vim.list_slice(argv, vim.fn.index(argv, '--') + 2))
    end
    H.eq(seen, paths)
  end
end)
