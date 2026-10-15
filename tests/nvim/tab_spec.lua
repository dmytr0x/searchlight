local H = require('tests.helpers')
local p = require('searchlight')
local sessions = require('searchlight.sessions')

local function configured(run)
  local config = vim.deepcopy(p.config)
  local ok, err = xpcall(run, debug.traceback)
  p.setup(config)
  assert(ok, err)
end

for _, mode in ipairs({ 'search', 'replace' }) do
  local command = mode == 'search' and 'SearchlightNew' or 'SearchlightReplaceNew'

  H.test(mode .. ': new panels default to independent tabs', 'Tabs,Entries', function()
    local a = H.fixture()
    H.eq(p.config.open_in_new_tab, true)
    -- Even an untouched startup window belongs to the original tab.
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)
    local tab, editor = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
    local count = #vim.api.nvim_list_tabpages()
    local s = p[mode](a)
    local panel_tab = vim.api.nvim_get_current_tabpage()
    assert(panel_tab ~= tab)
    H.eq(#vim.api.nvim_list_tabpages(), count + 1)
    H.eq(#vim.api.nvim_tabpage_list_wins(panel_tab), 1)
    H.eq(vim.api.nvim_get_current_buf(), s.buf)
    H.eq(vim.api.nvim_tabpage_list_wins(tab), { editor })
    H.eq(vim.api.nvim_win_get_buf(editor), buf)
    vim.cmd(command .. ' ' .. vim.fn.fnameescape(a))
    local another = sessions.get()
    assert(another.id ~= s.id)
    assert(vim.api.nvim_get_current_tabpage() ~= panel_tab)
    H.eq(#vim.api.nvim_list_tabpages(), count + 2)
    p.recent(s.id)
    H.eq(vim.api.nvim_get_current_tabpage(), panel_tab)
    H.eq(#vim.api.nvim_list_tabpages(), count + 2)
    p.action(s, 'hide')
    H.eq(p.reopen(), s)
    H.eq(vim.api.nvim_get_current_tabpage(), panel_tab)
    H.eq(#vim.api.nvim_list_tabpages(), count + 2)
  end)

  H.test(mode .. ': new tabs preserve editor layout and source options', 'Tabs,Open', function()
    local a = H.fixture()
    H.write(a .. '/one', 'abc\n')
    local buf = H.buffer(a .. '/unsaved', { 'unsaved text' })
    vim.api.nvim_win_set_buf(0, buf)
    vim.cmd('vsplit')
    vim.wo.number, vim.wo.wrap = true, true
    local tab = vim.api.nvim_get_current_tabpage()
    local editors = vim.api.nvim_tabpage_list_wins(tab)
    local s = H[mode](a)
    local panel_tab = vim.api.nvim_get_current_tabpage()
    H.eq(vim.api.nvim_tabpage_list_wins(tab), editors)
    for _, win in ipairs(editors) do
      H.eq(vim.api.nvim_win_get_buf(win), buf)
    end
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'unsaved text' })
    H.eq(vim.bo[buf].modified, true)
    local _, source = p.open(s)
    H.eq(vim.api.nvim_win_get_tabpage(source), panel_tab)
    H.eq(#vim.api.nvim_tabpage_list_wins(panel_tab), 2)
    H.eq(vim.wo[source].number, true)
    H.eq(vim.wo[source].wrap, true)
    H.eq(vim.api.nvim_tabpage_list_wins(tab), editors)
  end)

  for _, new_tab in ipairs({ true, false }) do
    H.test(
      mode .. ': commands honor open_in_new_tab = ' .. tostring(new_tab),
      'Tabs,Configuration,Entries',
      function()
        configured(function()
          local a = H.fixture()
          p.setup({ open_in_new_tab = new_tab })
          local buf = H.buffer(a .. '/source', { 'unsaved text' })
          vim.api.nvim_win_set_buf(0, buf)
          local tab, editor = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
          local count = #vim.api.nvim_list_tabpages()
          vim.cmd(command .. ' ' .. vim.fn.fnameescape(a))
          local s = sessions.get()
          H.eq(s.mode, mode)
          H.eq(s.config.open_in_new_tab, new_tab)
          H.eq(#vim.api.nvim_list_tabpages(), count + (new_tab and 1 or 0))
          H.eq(vim.api.nvim_get_current_tabpage() ~= tab, new_tab)
          H.eq(vim.api.nvim_win_get_buf(editor), buf)
          if not new_tab then
            H.eq(#vim.api.nvim_tabpage_list_wins(tab), 2)
            H.eq(vim.api.nvim_win_get_position(0), { 0, 0 })
          end
          p.close(s)
          -- Recreating a disposed panel uses its captured setting.
          p.setup({ open_in_new_tab = not new_tab })
          local reopen_tab = vim.api.nvim_get_current_tabpage()
          count = #vim.api.nvim_list_tabpages()
          local reopened = p.reopen()
          H.eq(reopened.config.open_in_new_tab, new_tab)
          H.eq(#vim.api.nvim_list_tabpages(), count + (new_tab and 1 or 0))
          H.eq(vim.api.nvim_get_current_tabpage() ~= reopen_tab, new_tab)
        end)
      end
    )
  end
end

H.test('open_in_new_tab rejects non-boolean settings atomically', 'Tabs,Validation', function()
  local config = vim.deepcopy(p.config)
  local tabs, win = vim.api.nvim_list_tabpages(), vim.api.nvim_get_current_win()
  for _, value in ipairs({ 'true', 'current', 0, 1, {} }) do
    H.eq(pcall(p.setup, { open_in_new_tab = value }), false)
    H.eq(p.config, config)
    H.eq(vim.api.nvim_list_tabpages(), tabs)
    H.eq(vim.api.nvim_get_current_win(), win)
  end
end)
