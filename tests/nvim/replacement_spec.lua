local H = require('tests.helpers')
local p = require('searchlight')
local replace = require('searchlight.replace')
H.test(
  'cross-root hard-link sessions become stale after an alias is edited',
  'R-06,B-02',
  function()
    local a, b = H.fixture()
    H.write(a .. '/one', 'abc\n')
    assert(vim.uv.fs_link(a .. '/one', b .. '/two'))
    local sa, sb = H.search(a), H.search(b)
    H.eq(p.action(sa, 'replace_all').applied, 1)
    H.eq(sb.status, 'stale')
    assert(sb.results[1].stale)
  end
)
H.test(
  'Searchlight uses disk for an externally changed clean buffer and refuses to erase its divergence',
  'B-02,R-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'old abc\n')
    local buf = H.buffer(a .. '/one')
    H.write(a .. '/one', 'external abc\n')
    local s = H.search(a)
    H.eq(s.results[1].context, 'external abc')
    H.eq(p.action(s, 'replace_all').applied, 0)
    H.eq(s.report.stale, 1)
    H.eq(H.read(a .. '/one'), 'external abc\n')
  end
)
H.test('partial edit exceptions report already-applied ranges accurately', 'R-04,R-07', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  H.write(a .. '/two', 'abc\n')
  local s = H.search(a)
  local original, calls = vim.api.nvim_buf_set_text, 0
  vim.api.nvim_buf_set_text = function(...)
    calls = calls + 1
    if calls == 2 then
      error('injected range edit failure')
    end
    return original(...)
  end
  local ok, err = xpcall(function()
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 2)
    H.eq(report.failed, 1)
    H.eq(#report.details, 1)
    H.eq(H.lines(a .. '/one'), { 'abc X' })
    H.eq(H.lines(a .. '/two'), { 'X' })
    H.eq(H.read(a .. '/one'), 'abc abc\n')
    H.eq(next(replace.busy), nil)
    assert(not require('searchlight.sources').mutating)
    local _, buf = H.lines(a .. '/one')
    assert(require('searchlight.observe').watched[buf])
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('undo')
    end)
    H.eq(H.lines(a .. '/one'), { 'abc abc' })
  end, debug.traceback)
  vim.api.nvim_buf_set_text = original
  if not ok then
    error(err)
  end
end)
H.test('loading autocmds cannot change frozen replacement targets', 'R-04,R-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  H.write(a .. '/two', 'abc abc\n')
  local s = H.search(a)
  vim.api.nvim_create_autocmd('BufReadPost', {
    pattern = a .. '/one',
    once = true,
    callback = function()
      for _, result in ipairs(s.results) do
        result.enabled = false
        result.path, result.line = a .. '/elsewhere', 99
        result.start, result.finish = 99, 102
        result.match, result.replacement = 'other', 'Y'
      end
    end,
  })
  local report = p.action(s, 'replace_all')
  H.eq(report.applied, 3)
  H.eq(report.excluded, 0)
  H.eq(H.lines(a .. '/one'), { 'X' })
  H.eq(H.lines(a .. '/two'), { 'X X' })
  H.eq(H.read(a .. '/one'), 'abc\n')
  H.eq(H.read(a .. '/two'), 'abc abc\n')
  H.wait(s, 'complete')
  H.eq(#s.results, 0)
end)
H.test(
  'Replace next freezes successor coordinates and skips excluded results before loading',
  'R-03,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc abc\n')
    local s = H.search(a)
    s.results[2].enabled = false
    vim.api.nvim_create_autocmd('BufReadPost', {
      pattern = a .. '/one',
      once = true,
      callback = function()
        s.results[1].replacement = 'longer replacement'
        s.results[3].start = 99
      end,
    })
    H.eq(p.action(s, 'replace_next').applied, 1)
    H.eq(H.lines(a .. '/one'), { 'X abc abc' })
    H.wait(s, 'complete')
    H.eq(replace.selected(s).start, 6)
  end
)
H.test(
  'loading a later source cannot bypass validation immediately before an earlier source edit',
  'R-04,R-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    H.write(a .. '/two', 'abc\n')
    local s = H.search(a)
    vim.api.nvim_create_autocmd('BufReadPost', {
      pattern = a .. '/two',
      once = true,
      callback = function()
        local _, buf = H.lines(a .. '/one')
        -- The first buffer is still unlisted, so its edit cannot invalidate the session.
        assert(not vim.bo[buf].buflisted)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc changed' })
      end,
    })
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 1)
    H.eq(report.stale, 1)
    H.eq(report.details, {
      { path = a .. '/one', reason = 'buffer differs from search snapshot' },
    })
    H.eq(H.lines(a .. '/one'), { 'abc changed' })
    H.eq(H.lines(a .. '/two'), { 'X' })
    H.eq(H.read(a .. '/one'), 'abc\n')
  end
)
H.test('source disk is revalidated after loading autocmds', 'R-05,R-07', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc old\n')
  local s = H.search(a)
  vim.api.nvim_create_autocmd('BufReadPost', {
    pattern = a .. '/one',
    once = true,
    callback = function()
      H.write(a .. '/one', 'abc new\n')
    end,
  })
  local report = p.action(s, 'replace_all')
  H.eq(report.applied, 0)
  H.eq(report.stale, 1)
  H.eq(report.details, {
    { path = a .. '/one', reason = 'disk changed while loading source' },
  })
  assert(s.message:find(report.details[1].reason, 1, true))
  H.eq(H.lines(a .. '/one'), { 'abc old' })
  H.eq(H.read(a .. '/one'), 'abc new\n')
end)
H.test(
  'replacement invalidates cross-root aliases that previously had no hits',
  'R-06,B-02',
  function()
    local a, b = H.fixture()
    H.write(a .. '/one', 'abc\n')
    assert(vim.uv.fs_link(a .. '/one', b .. '/two'))
    local sa = H.search(a)
    local sb = H.search(b, { query = 'X', replacement = 'Y' })
    H.eq(#sb.results, 0)
    H.eq(p.action(sa, 'replace_all').applied, 1)
    H.eq(sb.status, 'stale')
    H.wait(sa, 'complete')
    H.eq(H.read(b .. '/two'), 'abc\n')
  end
)
H.test('buffer setup errors release replacement ownership and remain retryable', 'R-04,R-07', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc')
  local s = H.search(a)
  local sources = require('searchlight.sources')
  local original, previous_mutating = vim.api.nvim_set_option_value, sources.mutating
  sources.mutating = true
  vim.api.nvim_set_option_value = function(name, value, opts)
    if name == 'fixendofline' and value == false then
      error('injected buffer setup failure')
    end
    return original(name, value, opts)
  end
  local ok, err = xpcall(function()
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 0)
    H.eq(report.failed, 1)
    assert(report.details[1].reason:find('injected buffer setup failure', 1, true))
    H.eq(next(replace.busy), nil)
    H.eq(sources.mutating, true)
    H.eq(H.lines(a .. '/one'), { 'abc' })
    H.eq(H.read(a .. '/one'), 'abc')
  end, debug.traceback)
  vim.api.nvim_set_option_value, sources.mutating = original, previous_mutating
  if not ok then
    error(err)
  end
  H.eq(p.action(s, 'replace_all').applied, 1)
  H.eq(H.lines(a .. '/one'), { 'X' })
  H.eq(H.read(a .. '/one'), 'abc')
end)
for _, fixture in ipairs({
  { name = 'overlapping', start = 2, finish = 5, match = 'c a' },
  { name = 'ambiguous', start = 0, finish = 0, match = '' },
  { name = 'invalid snapshot', start = 4, finish = 7, match = 'xyz' },
}) do
  H.test('replacement rejects ' .. fixture.name .. ' ranges before loading', 'R-04,R-05', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H.search(a)
    local second = s.results[2]
    second.start, second.finish, second.match = fixture.start, fixture.finish, fixture.match
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 0)
    H.eq(report.stale, 2)
    local reason = fixture.name == 'invalid snapshot' and 'invalid snapshot range'
      or 'overlapping or ambiguous edits'
    H.eq(report.details[1].reason, reason)
    assert(s.results[1].stale and s.results[2].stale)
    H.eq(vim.fn.bufnr(a .. '/one'), -1)
    H.eq(H.read(a .. '/one'), 'abc abc\n')
  end)
end
for _, fixture in ipairs({
  {
    name = 'unsupported write encoding',
    change = function(buf)
      vim.bo[buf].fileencoding = 'unsupported-searchlight-encoding'
    end,
    reason = 'source write options changed since search',
  },
  {
    name = 'nonmodifiable buffer',
    change = function(buf)
      vim.bo[buf].modifiable = false
    end,
    reason = 'source buffer is not writable',
  },
  {
    name = 'deleted buffer',
    change = function(buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end,
    reason = 'buffer deleted or renamed',
  },
}) do
  H.test('replacement rejects a ' .. fixture.name .. ' after search', 'R-05,R-07', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local buf = H.buffer(a .. '/one')
    local s = H.search(a)
    local sources = require('searchlight.sources')
    local previous_mutating = sources.mutating
    sources.mutating = true
    local ok, err = pcall(fixture.change, buf)
    sources.mutating = previous_mutating
    assert(ok, err)
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 0)
    H.eq(report.stale, 1)
    H.eq(report.details, { { path = a .. '/one', reason = fixture.reason } })
    H.eq(H.read(a .. '/one'), 'abc\n')
  end)
end
H.test(
  'Replace next changes precisely the second occurrence and selects its original successor',
  'R-03',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc abc\n')
    local s = H.search(a)
    p.navigate(s, 1)
    local report = p.action(s, 'replace_next')
    H.eq(report.applied, 1)
    H.eq(H.lines(a .. '/one'), { 'abc X abc' })
    H.eq(H.read(a .. '/one'), 'abc abc abc\n')
    H.wait(s, 'complete')
    H.eq(replace.selected(s).start, 6)
    p.action(s, 'replace_next')
    H.wait(s, 'complete')
    H.eq(H.lines(a .. '/one'), { 'abc X X' })
    H.eq(s.selected, nil)
    H.eq(s.navigation_end, true)
  end
)
H.test('replacement text which itself matches is not immediately revisited', 'R-03', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc abc\n')
  local s = H.search(a, { query = 'abc', replacement = 'abcabc' })
  p.action(s, 'replace_next')
  H.wait(s, 'complete')
  H.eq(replace.selected(s).start, 7)
  p.action(s, 'replace_next')
  H.wait(s, 'complete')
  H.eq(s.selected, nil)
  H.eq(H.lines(a .. '/one'), { 'abcabc abcabc' })
end)
H.test('zero-width Replace next advances to the original successor and stops', 'R-03', function()
  local a = H.fixture()
  H.write(a .. '/one', 'aa\n')
  local s = H.search(a, { query = '\\b', replacement = 'X', regex = true })
  H.eq(#s.results, 2)
  p.action(s, 'replace_next')
  H.wait(s, 'complete')
  H.eq(replace.selected(s).start, 3)
  p.action(s, 'replace_next')
  H.wait(s, 'complete')
  H.eq(s.selected, nil)
  H.eq(H.lines(a .. '/one'), { 'XaaX' })
end)
H.test(
  'bulk replacement honors individual same-line exclusions and reports counts',
  'R-04,R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    H.write(a .. '/two', 'abc\n')
    local s = H.search(a)
    -- Streaming jobs can first select either file; start from the sorted beginning.
    p.navigate(s, -#s.results)
    p.navigate(s, 1)
    p.action(s, 'exclude')
    H.eq(s.results[2].enabled, false)
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 2)
    H.eq(report.excluded, 1)
    H.eq(H.lines(a .. '/one'), { 'X abc' })
    H.eq(H.lines(a .. '/two'), { 'X' })
    H.eq(H.read(a .. '/one'), 'abc abc\n')
    H.eq(report.stale, 0)
    H.eq(report.failed, 0)
  end
)
H.test(
  'capture preview equals actual applied text and changing replacement invalidates old expansion',
  'R-02,R-04',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H.search(a, { query = 'a(b)c', replacement = '$1!', regex = true })
    p.set(s, { replacement = '${1}?' })
    H.eq(s.status, 'waiting')
    assert(s.results[1].stale)
    H.eq(p.action(s, 'replace_all'), nil)
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(s.results[1].replacement, 'b?')
    H.eq(p.action(s, 'replace_all').applied, 2)
    H.eq(H.lines(a .. '/one'), { 'b? b?' })
  end
)
H.test(
  'dirty buffers preserve surrounding unsaved text, write options and separate native undo',
  'R-07',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'disk abc\n')
    local buf = H.buffer(a .. '/one', { 'unsaved abc abc' })
    local s = H.search(a)
    p.action(s, 'replace_all')
    H.eq(H.lines(a .. '/one'), { 'unsaved X X' })
    H.eq(H.read(a .. '/one'), 'disk abc\n')
    assert(vim.bo[buf].modified)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('undo')
    end)
    H.eq(H.lines(a .. '/one'), { 'unsaved abc abc' })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('undo')
    end)
    H.eq(H.lines(a .. '/one'), { 'disk abc' })
  end
)
H.test(
  'source undo and redo invalidate results in every relevant session',
  'R-05,R-06,R-07',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local sa, sb = H.search(a), H.search(a)
    p.action(sa, 'replace_all')
    assert(sb.status == 'stale')
    assert(sb.results[1].stale)
    H.eq(p.action(sb, 'replace_all'), nil)
    H.wait(sa, 'complete')
    local _, buf = H.lines(a .. '/one')
    p.setup()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('undo')
    end)
    assert(vim.wait(1000, function()
      return sa.status == 'stale' and sb.status == 'stale'
    end, 5))
    p.refresh(sa)
    assert(vim.wait(5000, function()
      return sa.status == 'complete' and #sa.results == 1
    end, 5))
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('redo')
    end)
    assert(vim.wait(1000, function()
      return sa.status == 'stale'
    end, 5))
    p.refresh(sa)
    assert(vim.wait(5000, function()
      return sa.status == 'complete' and #sa.results == 0
    end, 5))
  end
)
H.test(
  'same-size external edits are rejected even when matched bytes remain at the old offset',
  'R-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc old\n')
    local s = H.search(a)
    H.write(a .. '/one', 'abc new\n')
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 0)
    H.eq(report.stale, 1)
    H.eq(H.read(a .. '/one'), 'abc new\n')
    H.eq(s.status, 'stale')
  end
)
H.test('deleted and renamed files cannot receive cached offsets', 'R-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  H.write(a .. '/two', 'abc\n')
  local s = H.search(a)
  assert(vim.uv.fs_unlink(a .. '/one'))
  assert(vim.uv.fs_rename(a .. '/two', a .. '/renamed'))
  local report = p.action(s, 'replace_all')
  H.eq(report.applied, 0)
  H.eq(report.stale, 2)
  H.eq(H.read(a .. '/renamed'), 'abc\n')
end)
H.test('changedtick rejects a buffer edit reverted to identical contents', 'R-05', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local buf = H.buffer(a .. '/one')
  local s = H.search(a)
  require('searchlight.sources').mutating = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'xyz' })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' })
  require('searchlight.sources').mutating = false
  local report = p.action(s, 'replace_all')
  H.eq(report.stale, 1)
  H.eq(report.applied, 0)
end)
H.test(
  'a previously unopened source loads before editing and load autocmd edits are rejected',
  'R-05,R-07',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local s = H.search(a)
    H.eq(s.results[1].buf, nil)
    local event = vim.api.nvim_create_autocmd('BufReadPost', {
      pattern = a .. '/one',
      once = true,
      callback = function(args)
        vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { 'abc other change' })
      end,
    })
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 0)
    H.eq(report.stale, 1)
    H.eq(H.lines(a .. '/one'), { 'abc other change' })
    pcall(vim.api.nvim_del_autocmd, event)
  end
)
H.test(
  'partial bulk success reports stale files and leaves every disk file untouched',
  'R-04,R-05',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    H.write(a .. '/two', 'abc\n')
    local s = H.search(a)
    H.write(a .. '/two', 'abc external\n')
    local report = p.action(s, 'replace_all')
    H.eq(report.applied, 1)
    H.eq(report.stale, 1)
    H.eq(#report.details, 1)
    H.eq(H.lines(a .. '/one'), { 'X' })
    H.eq(H.read(a .. '/one'), 'abc\n')
    H.eq(H.read(a .. '/two'), 'abc external\n')
  end
)
for _, fixture in ipairs({
  { name = 'CRLF', raw = 'abc abc\r\nnext\r\n', expected = 'X X\r\nnext\r\n', format = 'dos' },
  { name = 'missing final newline', raw = 'abc abc', expected = 'X X', eol = false },
  { name = 'final newline', raw = 'abc abc\n', expected = 'X X\n', eol = true },
  { name = 'UTF-8 BOM', raw = '\239\187\191abc\n', expected = '\239\187\191X\n', bom = true },
  { name = 'Latin-1', raw = 'caf\233 abc\n', expected = 'caf\233 X\n', encoding = 'latin1' },
  {
    name = 'UTF-16 BOM',
    raw = '\255\254a\0b\0c\0\n\0',
    expected = '\255\254X\0\n\0',
    encoding = 'utf-16le',
    bom = true,
  },
}) do
  H.test(
    'replacement preserves ' .. fixture.name .. ' bytes when explicitly saved',
    'R-07',
    function()
      local a = H.fixture()
      H.write(a .. '/one', fixture.raw)
      local s = H.search(a)
      H.eq(s.status, 'complete')
      assert(#s.results > 0)
      local count = #s.results
      H.eq(p.action(s, 'replace_all').applied, count)
      local _, buf = H.lines(a .. '/one')
      if fixture.format then
        H.eq(vim.bo[buf].fileformat, fixture.format)
      end
      if fixture.encoding then
        H.eq(vim.bo[buf].fileencoding, fixture.encoding)
      end
      if fixture.eol ~= nil then
        H.eq(vim.bo[buf].endofline, fixture.eol)
      end
      if fixture.bom then
        H.eq(vim.bo[buf].bomb, true)
      end
      H.eq(H.read(a .. '/one'), fixture.raw)
      vim.api.nvim_buf_call(buf, function()
        vim.cmd('write')
      end)
      H.eq(H.read(a .. '/one'), fixture.expected)
    end
  )
end
H.test('read-only sources are skipped without mutation', 'R-04,R-07', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local buf = H.buffer(a .. '/one', nil, { readonly = true })
  local s = H.search(a)
  local report = p.action(s, 'replace_all')
  H.eq(report.stale, 1)
  H.eq(report.applied, 0)
  H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'abc' })
end)
H.test('source buffer rename blocks old path results', 'R-05,B-03', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc\n')
  local buf = H.buffer(a .. '/one')
  local s = H.search(a)
  require('searchlight.sources').mutating = true
  vim.api.nvim_buf_set_name(buf, a .. '/renamed')
  require('searchlight.sources').mutating = false
  H.eq(p.action(s, 'replace_all').stale, 1)
  H.eq(H.read(a .. '/one'), 'abc\n')
end)
H.test(
  'exclusions survive identical snapshots and visibly reset after a changed snapshot',
  'R-08',
  function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    local s = H.search(a)
    p.action(s, 'exclude')
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(s.results[1].enabled, false)
    H.write(a .. '/one', 'abc abc abc\n')
    p.refresh(s)
    H.wait(s, 'complete')
    H.eq(s.results[1].enabled, true)
    assert(s.message:find('Exclusions reset'))
  end
)
