local shared = require('tests.helpers')
for _, mode in ipairs({ 'search', 'replace' }) do
  local function test(name, requirements, run)
    shared.test(mode .. ': ' .. name, requirements, run)
  end
  local H = require('tests.helpers')
  local p = require('searchlight')
  local scope = require('searchlight.scope')

  test(
    'project filters traverse hidden ancestors with ignored mode off',
    'Q-05,Q-07,4.5',
    function()
      local a = H.fixture()
      H.write(a .. '/run.sh', 'if\n')
      H.write(a .. '/sources/.config/nvim/main.lua', 'if\n')
      local s = H[mode](a, { query = 'if', include = { '*.lua,*.sh' } })
      H.eq(s.status, 'complete')
      H.eq(s.options.ignored, false)
      H.eq(#s.results, 2, 'hidden ancestors must not hide matching project sources')
    end
  )

  test(
    'hidden disk and new buffer sources share filters and ignore policy',
    'B-01,B-02,Q-05,4.5',
    function()
      local a = H.fixture()
      H.write(a .. '/.gitignore', 'ignored/\n')
      H.write(a .. '/sources/.config/.ignore', 'blocked/\n')
      H.write(a .. '/sources/.config/.rgignore', 'omitted/\n')
      H.write(H.root .. '/extra-ignore', '.venv/\n')
      H.write(H.root .. '/rgconfig', '--ignore-file=' .. H.root .. '/extra-ignore\n')
      local files = {
        'run.sh',
        'sources/.config/main.lua',
        'sources/.config/.script.sh',
        'sources/.config/blocked/skip.lua',
        'sources/.config/omitted/omit.sh',
        'sources/.config/notes.txt',
        'ignored/.config/main.lua',
        '.venv/main.lua',
        '.git/main.lua',
        'nested/.git/main.lua',
      }
      for _, file in ipairs(files) do
        H.write(a .. '/' .. file, 'if IF\n')
      end
      local s = H[mode](a, { query = 'if', include = { '*.lua,*.sh' } })
      local function names()
        local paths = {}
        for _, result in ipairs(s.results) do
          table.insert(paths, scope.relative(s.root, result.path))
        end
        return paths
      end
      local expected = {
        'run.sh',
        'run.sh',
        'sources/.config/.script.sh',
        'sources/.config/.script.sh',
        'sources/.config/main.lua',
        'sources/.config/main.lua',
      }
      H.eq(names(), expected)
      for _, file in ipairs(files) do
        H.buffer(a .. '/' .. file, { 'if IF' })
        assert(vim.uv.fs_unlink(a .. '/' .. file))
      end
      for _, open in ipairs({ true, false }) do
        H.update(s, { open = open, ignored = false, exclude = {} })
        H.eq(names(), expected)
        H.update(s, { exclude = { 'sources/.config/**' } })
        H.eq(names(), { 'run.sh', 'run.sh' })
        H.update(s, { ignored = true, exclude = {} })
        H.eq(#s.results, 14)
        for _, result in ipairs(s.results) do
          assert(not scope.metadata(s.root, result.path))
        end
      end
      H.update(s, { open = false, ignored = false, include = {} })
      H.eq(#s.results, 8)
      p.action(s, 'section', 'help')
      assert(vim.wait(1000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), '\n')
        return text:find('Policy: include hidden; respect config/ignores; exclude .git', 1, true)
          ~= nil
      end, 5))
    end
  )
end
