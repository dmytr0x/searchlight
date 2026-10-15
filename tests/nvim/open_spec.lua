local shared = require('tests.helpers')
for _, mode in ipairs({ 'search', 'replace' }) do
  local function test(name, requirements, run)
    shared.test(mode .. ': ' .. name, requirements, run)
  end
  local H = require('tests.helpers')
  local p = require('searchlight')
  local editor_options = {
    number = true,
    relativenumber = true,
    wrap = true,
    signcolumn = 'yes:2',
    foldmethod = 'marker',
    virtualedit = '',
    colorcolumn = '',
  }

  local function window_options(scope)
    local options = {}
    for name in pairs(editor_options) do
      options[name] = vim.api.nvim_get_option_value(name, { win = 0, scope = scope or 'local' })
    end
    return options
  end

  local function set_options(options, scope)
    for name, value in pairs(options) do
      vim.api.nvim_set_option_value(name, value, { win = 0, scope = scope })
    end
  end

  local function with_editor_state(run)
    local options = window_options()
    local defaults = window_options('global')
    local pattern, active, enabled = vim.fn.getreg('/'), vim.v.hlsearch, vim.o.hlsearch
    local group = vim.api.nvim_create_augroup('SearchlightOpenTest', { clear = true })
    local ok, err = xpcall(function()
      set_options(editor_options)
      run(group)
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    H.cleanup()
    set_options(defaults, 'global')
    set_options(options, 'local')
    vim.fn.setreg('/', pattern)
    vim.o.hlsearch, vim.v.hlsearch = enabled, active
    if not ok then
      error(err)
    end
  end

  test('opening an unchanged source preserves fresh circle markers', 'S-05,R-01', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\nabc again\n')
    local s = H[mode](a)
    local function circles()
      require('searchlight.view').render(s)
      for _, result in ipairs(s.results) do
        local row = s.result_positions[result.id].row
        local line = vim.api.nvim_buf_get_lines(s.buf, row - 1, row, false)[1]
        H.eq(line:sub(3, 2 + #'○'), '○', 'opening a source changed its match marker')
      end
    end
    circles()
    local generation = s.generation
    for _ = 1, 2 do
      p.open(s)
      vim.wait(30)
      circles()
      H.eq(s.generation, generation, 'opening unchanged text invalidated the search')
      H.eq(s.status, 'complete')
      for _, result in ipairs(s.results) do
        H.eq(result.stale, false)
      end
      p.recent(s.id)
    end
  end)

  test(
    'adding an existing source only invalidates the open-file search scope',
    'S-05,B-01',
    function()
      local a = H.fixture()
      H.write(a .. '/one', 'abc\n')
      local disk = H[mode](a)
      local open = H[mode](a, { query = 'abc', open = true })
      H.eq(#open.results, 0)
      p.open(disk)
      vim.wait(30)
      H.eq(disk.status, 'complete')
      H.eq(open.status, 'stale')
      p.refresh(open)
      H.wait(open, 'complete')
      H.eq(#open.results, 1)
    end
  )

  test(
    'Enter opens results with native edit settings, centering and highlights',
    'S-05,R-10',
    function()
      with_editor_state(function(group)
        local a = H.fixture()
        local path = a .. '/file with spaces.fixture'
        local lines = {}
        for i = 1, 240 do
          lines[i] = 'source line ' .. i
        end
        lines[120] = '雪 abc abc'
        H.write(path, table.concat(lines, '\n') .. '\n')
        vim.api.nvim_create_autocmd('BufReadPost', {
          group = group,
          pattern = '*.fixture',
          callback = function()
            H.eq(vim.wo.number, true, 'file setup ran with panel settings')
            vim.bo.filetype = 'searchlight_fixture'
          end,
        })
        vim.api.nvim_create_autocmd('FileType', {
          group = group,
          pattern = 'searchlight_fixture',
          callback = function()
            vim.wo.foldmethod, vim.wo.colorcolumn = 'indent', '31'
            vim.bo.tabstop, vim.bo.shiftwidth = 3, 3
          end,
        })
        -- Compare both an unloaded file and a subsequent jump to the loaded buffer.
        vim.cmd.edit(vim.fn.fnameescape(path))
        local expected = window_options()
        vim.api.nvim_buf_delete(0, { force = true })
        set_options(editor_options)
        local defaults = window_options('global')
        local s = H[mode](a)
        for _ = 1, 2 do
          p.recent(s.id)
          H.eq(vim.wo.number, false)
          H.eq(vim.wo.wrap, false)
          H.eq(window_options('global'), defaults, 'panel changed the editor window defaults')
          p.navigate(s, -#s.results)
          p.navigate(s, 1)
          vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes('<CR>', true, false, true),
            'xt',
            false
          )
          local win = vim.api.nvim_get_current_win()
          H.eq(vim.api.nvim_buf_get_name(0), path)
          H.eq(window_options(), expected, 'source settings differ from native :edit')
          H.eq(vim.bo.filetype, 'searchlight_fixture')
          H.eq(vim.bo.tabstop, 3)
          H.eq(vim.bo.shiftwidth, 3)
          H.eq(vim.bo.buftype, '')
          H.eq(vim.api.nvim_win_get_cursor(win), { 120, 8 })
          vim.cmd('redraw!')
          H.eq(vim.fn.winline(), math.floor(vim.api.nvim_win_get_height(win) / 2) + 1)
          H.eq(vim.fn.getreg('/'), '\\c\\Vabc')
          H.eq(vim.o.hlsearch, true)
          H.eq(vim.v.hlsearch, 1)
          H.eq(vim.fn.searchcount({ recompute = true }).total, 2)
        end
      end)
    end
  )

  test(
    'peeker opens the selected occurrence and centers after closing its panel',
    'Open,Configuration',
    function()
      with_editor_state(function()
        local a = H.fixture()
        local path = a .. '/file with spaces.fixture'
        local lines = {}
        for i = 1, 240 do
          lines[i] = 'source line ' .. i
        end
        lines[120] = '雪 abc abc'
        H.write(path, table.concat(lines, '\n') .. '\n')
        local expected = window_options()
        local surviving = p[mode](a)
        local s = p[mode](a, { close_on_open = true })
        H.update(s, { query = 'abc' })
        p.navigate(s, 1)
        local selected = s.results[2].id
        local buf, win = p.open(s)
        H.eq(vim.api.nvim_get_current_win(), win)
        H.eq(vim.api.nvim_buf_get_name(buf), path)
        H.eq(vim.api.nvim_win_get_cursor(win), { 120, 8 })
        H.eq(window_options(), expected)
        vim.cmd('redraw!')
        H.eq(vim.fn.winline(), math.floor(vim.api.nvim_win_get_height(win) / 2) + 1)
        H.eq(vim.fn.getreg('/'), '\\c\\Vabc')
        H.eq(vim.v.hlsearch, 1)
        H.eq(s.selected, selected)
        H.eq(require('searchlight.sessions').get(s.id), nil)
        H.eq(vim.fn.win_findbuf(s.buf), {})
        H.eq(p.recent(), surviving)
      end)
    end
  )

  test(
    'opening a loaded modified result preserves its buffer and editor settings',
    'S-05,B-01',
    function()
      with_editor_state(function()
        local a = H.fixture()
        local path = a .. '/one'
        H.write(path, 'disk contents\n')
        vim.cmd.edit(vim.fn.fnameescape(path))
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '雪 abc abc' })
        local expected = window_options()
        local s = H[mode](a)
        p.navigate(s, 1)
        local source, win = p.open(s)
        H.eq(source, buf)
        H.eq(vim.bo[buf].modified, true)
        H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '雪 abc abc' })
        H.eq(vim.api.nvim_win_get_cursor(win), { 1, 8 })
        H.eq(window_options(), expected)
        H.eq(H.read(path), 'disk contents\n')
      end)
    end
  )

  test(
    'editing in the startup panel restores editor options before file setup',
    'S-01,S-05',
    function()
      with_editor_state(function(group)
        local a = H.fixture()
        H.write(a .. '/one', 'abc\n')
        vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
        set_options(editor_options)
        local expected = window_options()
        local win = vim.api.nvim_get_current_win()
        local s = p[mode](a)
        H.eq(vim.api.nvim_get_current_win(), win)
        H.eq(vim.wo.number, false)
        vim.api.nvim_create_autocmd('BufReadPost', {
          group = group,
          pattern = a .. '/one',
          callback = function()
            H.eq(window_options(), expected)
            vim.wo.foldmethod = 'indent'
          end,
        })
        vim.cmd.edit(vim.fn.fnameescape(a .. '/one'))
        expected.foldmethod = 'indent'
        H.eq(window_options(), expected)
        H.eq(vim.api.nvim_get_current_win(), win)
        assert(require('searchlight.sessions').owns(s))
      end)
    end
  )

  test(
    'nested search panels preserve the original editor settings on source jumps',
    'S-02,S-05',
    function()
      with_editor_state(function()
        local a = H.fixture()
        H.write(a .. '/one', 'abc\n')
        local expected = window_options()
        local first, second = H[mode](a), H[mode](a)
        local _, win = p.open(second)
        H.eq(window_options(), expected)
        p.recent(first.id)
        local panel = vim.api.nvim_get_current_win()
        H.eq(vim.wo.number, false)
        -- Removing another window must not restore this panel's options.
        vim.api.nvim_win_close(win, true)
        H.eq(vim.wo.number, false)
        p.open(first)
        H.eq(window_options(), expected)
        H.eq(vim.wo[panel].number, false)
      end)
    end
  )
end
