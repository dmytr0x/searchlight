local shared = require('tests.helpers')
for _, mode in ipairs({ 'search', 'replace' }) do
  local function test(name, requirements, run)
    shared.test(mode .. ': ' .. name, requirements, run)
  end
  local H = require('tests.helpers')
  local p = require('searchlight')
  test(
    'new buffers honor Git worktree metadata without exposing .git content',
    'B-01,4.5',
    function()
      local a = H.fixture()
      vim.fn.delete(a .. '/.git', 'rf')
      H.write(H.root .. '/gitdir/info/exclude', 'blocked\n')
      H.write(a .. '/.git', 'gitdir: ' .. H.root .. '/gitdir\n')
      H.buffer(a .. '/blocked', { 'abc' })
      H.buffer(a .. '/allowed', { 'abc' })
      H.eq(#H[mode](a).results, 1)
    end
  )
  test(
    'ignored mode overrides config and normal ignores; .git always excluded',
    '4.5,Q-07',
    function()
      local a = H.fixture()
      H.write(a .. '/.gitignore', 'ignored/\n')
      for _, file in ipairs({ 'normal', '.hidden', '.venv/lib', 'ignored/file', '.git/secret' }) do
        H.write(a .. '/' .. file, 'abc\n')
      end
      local s = H[mode](a)
      H.eq(#s.results, 2)
      H.update(s, { ignored = true })
      H.eq(#s.results, 4)
      for _, r in ipairs(s.results) do
        assert(not r.path:find('/.git/'))
      end
      H.update(s, { include = { '**' }, exclude = { '.venv/**' } })
      H.eq(#s.results, 3)
      H.update(s, { ignored = false, include = {}, exclude = {} })
      H.eq(#s.results, 2)
    end
  )
  test('hidden sources are included even with configured --no-hidden', '4.5', function()
    local a = H.fixture()
    H.write(a .. '/.secret', 'abc\n')
    for _, config in ipairs({ '', '--hidden\n', '--no-hidden\n' }) do
      H.write(H.root .. '/rgconfig', config)
      H.eq(#H[mode](a).results, 1)
    end
  end)
  test('Searchlight overlays dirty buffers without duplicate disk hits', 'B-02,B-03', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc abc\n')
    H.write(a .. '/two', 'abc\n')
    local buf = H.buffer(a .. '/one', { 'unsaved abc' })
    local s = H[mode](a)
    H.eq(#s.results, 2)
    H.eq(s.results[1].buf, buf)
    H.eq(s.results[1].start, 8)
    H.eq(s.results[1].snapshot.text, 'unsaved abc\n')
    H.update(s, { open = true })
    H.eq(#s.results, 1)
    H.eq(s.results[1].buf, buf)
    H.eq(H.read(a .. '/one'), 'abc abc\n')
  end)
  test(
    'dirty buffer with zero matches suppresses disk matches and zero-hit changes invalidate',
    'B-01,B-02',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc\n')
      local buf = H.buffer(a .. '/one', { 'nothing' })
      local s = H[mode](a)
      H.eq(#s.results, 0)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' })
      assert(vim.wait(1000, function()
        return s.status == 'stale'
      end, 5))
      H.eq(#s.results, 0)
      p.refresh(s)
      assert(vim.wait(5000, function()
        return s.status == 'complete' and #s.results == 1
      end, 5))
      H.update(s, { open = true })
      H.eq(#s.results, 1)
    end
  )
  test(
    'new unsaved buffers share real ignore and glob semantics in both modes',
    'B-01,B-02,Q-05',
    function()
      local a = H.fixture()
      H.write(a .. '/.gitignore', 'build/\n*.tmp\n!keep.tmp\n')
      H.write(a .. '/nested/.ignore', '*.log\n!keep.log\n')
      for _, file in ipairs({
        'one.lua',
        'build/file.lua',
        'skip.tmp',
        'keep.tmp',
        'nested/skip.log',
        'nested/keep.log',
        '.hidden',
      }) do
        H.buffer(a .. '/' .. file, { 'abc' })
      end
      local s = H[mode](a)
      H.eq(#s.results, 4)
      H.update(s, { open = true })
      H.eq(#s.results, 4)
      H.update(s, { include = { '**/*.lua', 'nested/keep.*' }, exclude = { 'build/**' } })
      H.eq(#s.results, 2)
      H.update(s, { ignored = true, include = {}, exclude = {} })
      H.eq(#s.results, 7)
      for _, r in ipairs(s.results) do
        assert(r.buf and not vim.uv.fs_stat(r.path))
      end
    end
  )
  test(
    'new-file policy matches disk discovery for globstar, rooted and directory rules',
    'B-01,Q-05,4.5',
    function()
      local a = H.fixture()
      H.write(a .. '/.gitignore', '/rooted.txt\ncache/\n**/deep/*.tmp\n!**/deep/keep.tmp\n')
      H.write(a .. '/.git/info/exclude', 'excluded.txt\n')
      H.write(a .. '/nested/.rgignore', '*.secret\n!yes.secret\n')
      local candidates = {
        'rooted.txt',
        'nested/rooted.txt',
        'cache/a',
        'deep/a.tmp',
        'deep/keep.tmp',
        'nested/deep/a.tmp',
        'nested/deep/keep.tmp',
        'excluded.txt',
        'nested/no.secret',
        'nested/yes.secret',
        'plain',
      }
      for _, name in ipairs(candidates) do
        H.write(a .. '/' .. name, 'abc\n')
      end
      local s = H[mode](a)
      local disk = {}
      for _, r in ipairs(s.results) do
        disk[require('searchlight.scope').relative(s.root, r.path)] = true
      end
      for _, name in ipairs(candidates) do
        H.buffer(a .. '/' .. name, { 'abc' })
        assert(vim.uv.fs_unlink(a .. '/' .. name))
      end
      H.update(s, { open = true })
      local current = {}
      for _, r in ipairs(s.results) do
        current[require('searchlight.scope').relative(s.root, r.path)] = true
      end
      H.eq(current, disk)
    end
  )
  test(
    'new buffers honor parent ignore files and absolute extra ignore files',
    'B-01,4.5',
    function()
      local a = H.fixture()
      H.write(H.root .. '/.ignore', 'parent-blocked\n')
      H.write(H.root .. '/extra-ignore', 'extra-blocked\n')
      H.write(H.root .. '/rgconfig', '--ignore-file=' .. H.root .. '/extra-ignore\n')
      H.buffer(a .. '/parent-blocked', { 'abc' })
      H.buffer(a .. '/extra-blocked', { 'abc' })
      H.buffer(a .. '/allowed', { 'abc' })
      H.eq(#H[mode](a).results, 1)
    end
  )
  test('ignored open file remains excluded until ignored mode is enabled', 'B-01,Q-07', function()
    local a = H.fixture()
    H.write(a .. '/.ignore', 'ignored\n')
    H.write(a .. '/ignored', 'abc\n')
    H.buffer(a .. '/ignored', { 'abc abc' })
    local s = H[mode](a, { query = 'abc', open = true })
    H.eq(#s.results, 0)
    H.update(s, { ignored = true })
    H.eq(#s.results, 2)
  end)
  test('listed unloaded buffers load without searching special buffers', 'B-01', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local buf = vim.fn.bufadd(a .. '/one')
    vim.bo[buf].buflisted = true
    assert(not vim.api.nvim_buf_is_loaded(buf))
    local ui = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(ui, a .. '/fake')
    vim.api.nvim_buf_set_lines(ui, 0, -1, false, { 'abc' })
    local s = H[mode](a, { query = 'abc', open = true })
    H.eq(#s.results, 1)
    H.eq(s.results[1].buf, buf)
  end)
  test(
    'containment respects components and symlink aliases are never searched twice',
    'B-02,R-05',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc\n')
      H.write(a .. '-other/two', 'abc\n')
      H.buffer(a .. '-other/two', { 'abc' })
      assert(vim.uv.fs_symlink(a .. '/one', a .. '/alias'))
      H.write(H.root .. '/rgconfig', '--follow\n')
      local s = H[mode](a)
      H.eq(#s.results, 1)
      H.update(s, { open = true })
      H.eq(#s.results, 0)
    end
  )
  test(
    'hard-linked sources are deduplicated and a dirty alias overlays their shared identity',
    'B-02,R-05',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc\n')
      assert(vim.uv.fs_link(a .. '/one', a .. '/two'))
      H.eq(#H[mode](a).results, 1)
      local buf = H.buffer(a .. '/two', { 'abc abc' })
      local s = H[mode](a)
      H.eq(#s.results, 2)
      H.eq(s.results[1].buf, buf)
      -- Neovim also coalesces bufnr identities for hard links on this platform.
      local other = H.buffer(a .. '/one', { 'abc' })
      H.eq(other, buf)
      p.refresh(s)
      H.wait(s, 'complete')
      H.eq(#s.results, 1)
    end
  )
  test('symlink aliases into metadata and outside the root are excluded', '4.5,B-02', function()
    local a = H.fixture()
    H.write(a .. '/.git/secret', 'abc\n')
    H.write(H.root .. '/outside', 'abc\n')
    assert(vim.uv.fs_symlink(a .. '/.git/secret', a .. '/leak'))
    assert(vim.uv.fs_symlink(H.root .. '/outside', a .. '/external'))
    H.write(H.root .. '/rgconfig', '--follow\n--hidden\n')
    H.eq(#H[mode](a).results, 0)
  end)
  test(
    'open unsaved buffers without a final newline send no synthetic newline',
    'B-01,R-07',
    function()
      local a = H.fixture()
      local buf = H.buffer(a .. '/new', { 'abc' }, { endofline = false, fixendofline = false })
      local s = H.replace(a, { query = 'abc', replacement = '', open = true })
      H.eq(s.results[1].snapshot.text, 'abc')
      H.eq(p.action(s, 'replace_all').applied, 1)
      H.eq(vim.bo[buf].endofline, false)
      H.eq(vim.bo[buf].fixendofline, false)
      assert(not vim.uv.fs_stat(a .. '/new'))
    end
  )
  test(
    'symlinked files and directories are listed only with --follow, under canonical paths',
    '4.5,B-02',
    function()
      local a = H.fixture()
      H.write(a .. '/.ignore', 'target/\n')
      H.write(a .. '/target/one', 'abc\n')
      H.write(a .. '/target/dir/two', 'abc\n')
      assert(vim.uv.fs_symlink(a .. '/target/one', a .. '/link_one'))
      assert(vim.uv.fs_symlink(a .. '/target/dir', a .. '/link_dir'))
      local s = H[mode](a)
      H.eq(#s.results, 0)
      H.write(H.root .. '/rgconfig', '--follow\n')
      H.update(s, {})
      local paths = vim.tbl_map(function(r)
        return r.path
      end, s.results)
      table.sort(paths)
      H.eq(paths, { a .. '/target/dir/two', a .. '/target/one' })
    end
  )
  test('a symlinked root reports sources under its canonical path', '4.5', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    assert(vim.uv.fs_symlink(a, H.root .. '/alias'))
    H.eq(H[mode](H.root .. '/alias').results[1].path, a .. '/one')
    -- On macOS /tmp is itself a symlink to /private/tmp.
    local tmp = vim.uv.fs_mkdtemp('/tmp/searchlight-XXXXXX')
    if tmp then
      local canonical = assert(vim.uv.fs_realpath(tmp))
      H.write(tmp .. '/one', 'abc\n')
      local ok, s = pcall(H[mode], tmp)
      vim.fn.delete(tmp, 'rf')
      assert(ok, s)
      H.eq(s.results[1].path, canonical .. '/one')
    end
  end)
end
