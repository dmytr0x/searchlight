local H = require('tests.helpers')
local p = require('searchlight')
local sessions = require('searchlight.sessions')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function configured(run)
  local config = vim.deepcopy(p.config)
  local ok, err = xpcall(run, debug.traceback)
  p.setup(config)
  assert(ok, err)
end

for _, mode in ipairs({ 'search', 'replace' }) do
  H.test(
    mode .. ': close_on_open defaults, commands and session overrides stay independent',
    'Configuration,Entries',
    function()
      configured(function()
        local a = H.fixture()
        H.eq(p.config.close_on_open, false)
        local persistent = p[mode](a)
        p.setup({ close_on_open = true })
        local command = mode == 'search' and 'SearchlightNew' or 'SearchlightReplaceNew'
        vim.cmd(command .. ' ' .. vim.fn.fnameescape(a))
        local peeker = sessions.get()
        H.eq(peeker.config.close_on_open, true)
        H.eq(persistent.config.close_on_open, false)
        local override = { close_on_open = false }
        local another = p[mode](a, override)
        override.close_on_open = true
        H.eq(another.config.close_on_open, false)
        H.eq(p.config.close_on_open, true)
        p.setup({ close_on_open = false })
        H.eq(peeker.config.close_on_open, true)
        H.eq(p[mode](a).config.close_on_open, false)
      end)
    end
  )

  H.test(
    mode .. ': a custom mapping creates a peeker in the current directory',
    'Mappings,Entries,Open',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc\n')
      local previous = vim.fn.getcwd()
      vim.cmd('lcd ' .. vim.fn.fnameescape(a))
      local buf = vim.api.nvim_get_current_buf()
      local s
      -- Keep the mapping buffer-local so existing global user mappings survive.
      vim.keymap.set('n', '<F18>', function()
        s = p[mode]({ close_on_open = true })
      end, { buffer = buf })
      local ok, err = xpcall(function()
        keys('<F18>')
        H.eq({ s.root, s.mode, s.config.close_on_open }, { a, mode, true })
        H.eq(p.config.close_on_open, false)
        H.update(s, { query = 'abc' })
        p.navigate(s, 1)
        keys('<CR>')
        H.eq(vim.api.nvim_buf_get_name(0), a .. '/one')
        H.eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
        H.eq(sessions.get(s.id), nil)
        H.eq(vim.fn.win_findbuf(s.buf), {})
        H.eq(vim.fn.buflisted(s.buf), 0)
      end, debug.traceback)
      vim.api.nvim_buf_del_keymap(buf, 'n', '<F18>')
      vim.cmd('lcd ' .. vim.fn.fnameescape(previous))
      assert(ok, err)
    end
  )

  H.test(
    mode .. ': peeker Enter still submits fields, toggles file headers and keeps empty results',
    'Open,Input',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc\n')
      local s = p[mode](a, { close_on_open = true })
      H.update(s, { query = 'abc' })
      for _, insert in ipairs({ false, true }) do
        p.action(s, 'field', 'query')
        local generation = s.generation
        keys(insert and 'i<CR><Esc>' or '<CR>')
        H.wait(s, 'complete')
        assert(s.generation > generation)
        assert(sessions.owns(s))
      end
      local path = s.results[1].path
      vim.api.nvim_win_set_cursor(0, { s.file_headers[path], 0 })
      keys('<CR>')
      H.eq(s.collapsed_paths[path], true)
      assert(sessions.owns(s))
      keys('<CR>')
      H.eq(s.collapsed_paths[path], nil)
      H.update(s, { query = 'no matches' })
      H.eq(#s.results, 0)
      p.open(s)
      assert(sessions.owns(s))
      H.eq(vim.api.nvim_get_current_buf(), s.buf)
    end
  )
end

H.test(
  'invalid close_on_open options fail before creating sessions or changing config',
  'Validation',
  function()
    local a = H.fixture()
    local config = vim.deepcopy(p.config)
    local id, buf, win =
      sessions.next_id, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    for _, value in ipairs({ 'true', 1, {} }) do
      H.eq(pcall(p.setup, { close_on_open = value }), false)
    end
    for _, mode in ipairs({ 'search', 'replace' }) do
      for _, options in ipairs({
        false,
        1,
        'true',
        { close_on_open = 'true' },
        { close_on_open = 1 },
        { unknown = true },
      }) do
        H.eq(pcall(p[mode], a, options), false)
      end
      H.eq(pcall(p[mode], { close_on_open = 'true' }), false)
    end
    H.eq(p.config, config)
    H.eq(sessions.next_id, id)
    H.eq(vim.api.nvim_get_current_buf(), buf)
    H.eq(vim.api.nvim_get_current_win(), win)
  end
)
