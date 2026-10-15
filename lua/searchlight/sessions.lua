local input = require('searchlight.input')
local modes = require('searchlight.modes')
local M = {
  by_id = {},
  by_buf = {},
  next_id = 0,
  last = nil,
}
function M.touch(s)
  M.activation = (M.activation or 0) + 1
  s.activated_at, M.last = M.activation, s.id
  M.previous = { id = s.id }
end
local panel_options = {
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = 'no',
  foldmethod = 'manual',
  -- Zero-width matches at end of line need a cursor position after the last byte.
  virtualedit = 'onemore',
}
local editor_options = {}
local closing_panel = false
local departing_panel

function M.editor_options(win)
  win = win == 0 and vim.api.nvim_get_current_win() or win
  if editor_options[win] then
    return vim.deepcopy(editor_options[win])
  end
  local options = {}
  for name in pairs(panel_options) do
    options[name] = vim.api.nvim_get_option_value(name, { win = win, scope = 'local' })
  end
  return options
end

function M.restore_editor_options(win, options)
  for name, value in pairs(options or editor_options[win] or {}) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' })
  end
  editor_options[win] = nil
end

local window_group = vim.api.nvim_create_augroup('SearchlightPanelOptions', { clear = true })
vim.api.nvim_create_autocmd('BufEnter', {
  group = window_group,
  callback = function(event)
    -- Deleting the current panel can automatically enter an older panel. Keep
    -- the deleted panel as the reopen target until the next intentional visit.
    if closing_panel then
      closing_panel = false
      return
    end
    local s = M.by_buf[event.buf]
    if M.owns(s) then
      M.touch(s)
    end
  end,
})
vim.api.nvim_create_autocmd('BufLeave', {
  group = window_group,
  callback = function(event)
    -- :bdelete can enter a fallback buffer before emitting BufDelete. Remember
    -- the panel being left until that command's events have finished.
    local s = M.by_buf[event.buf]
    departing_panel = s and M.previous and M.previous.id == s.id and s or nil
    if departing_panel then
      local departed = departing_panel
      vim.schedule(function()
        if departing_panel == departed then
          departing_panel = nil
        end
      end)
    end
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == event.buf then
      M.restore_editor_options(win)
    end
  end,
})
vim.api.nvim_create_autocmd('WinClosed', {
  group = window_group,
  callback = function(event)
    editor_options[tonumber(event.match)] = nil
  end,
})

local function panel_name(id, query)
  local label = (query or ''):gsub('[%c/\\#%%|"]', '_')
  if vim.fn.strchars(label) > 40 then
    label = vim.fn.strcharpart(label, 0, 40) .. '…'
  end
  if label == '' then
    return 'searchlight://' .. id
  end
  return 'searchlight://' .. id .. '/' .. label
end

local function wipe_panel_name(name, keep)
  if name == '' then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      buf ~= keep
      and vim.api.nvim_buf_is_valid(buf)
      and not vim.bo[buf].buflisted
      and vim.api.nvim_buf_get_name(buf) == name
    then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.sync_name(s)
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return
  end
  local name = panel_name(s.id, s.fields.query)
  local current = vim.api.nvim_buf_get_name(s.buf)
  if current == name then
    return
  end
  wipe_panel_name(name, s.buf)
  if pcall(vim.api.nvim_buf_set_name, s.buf, name) then
    wipe_panel_name(current, s.buf)
  end
end

function M.owns(s)
  return s and M.by_id[s.id] == s and not s.disposed and vim.api.nvim_buf_is_valid(s.buf)
end
function M.get(id)
  if type(id) == 'table' then
    return M.owns(id) and id or nil
  end
  if id then
    return M.by_id[tonumber(id)]
  end
  return M.by_buf[vim.api.nvim_get_current_buf()]
end
function M.own(s)
  s = M.get(s)
  assert(s, 'No owning Searchlight session')
  return s
end
-- Plain initial state allows validation before allocating any editor resources.
function M.initial(root, config, mode)
  local capability = modes.get(mode)
  local initial = {
    root = root,
    mode = mode,
    fields = { query = '', include = {}, exclude = {} },
    options = input.options(config),
    sections = { filters = true },
    config = vim.deepcopy(config),
  }
  initial.config.mappings = nil
  if capability.replacement then
    initial.fields.replacement, initial.sections.replace = '', true
  end
  return initial
end

function M.create(root, config, mode, initial)
  initial = initial or M.initial(root, config, mode)
  M.next_id = M.next_id + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'nofile', 'hide'
  vim.bo[buf].swapfile, vim.bo[buf].filetype = false, 'searchlight'
  local s = {
    id = M.next_id,
    buf = buf,
    root = initial.root,
    mode = mode,
    fields = initial.fields,
    options = initial.options,
    sections = initial.sections,
    search_heading = initial.heading,
    results = {},
    selected = nil,
    generation = 0,
    jobs = {},
    pending_jobs = {},
    status = 'empty',
    config = initial.config,
    exclusions = {},
    regions = {},
    result_rows = {},
    collapsed_paths = {},
    snapshots = {},
    identities = {},
    report = nil,
  }
  M.by_id[s.id], M.by_buf[buf] = s, s
  M.touch(s)
  M.sync_name(s)
  return s
end
function M.dispose(s)
  if not s or s.disposed then
    return
  end
  if vim.api.nvim_get_current_buf() == s.buf then
    closing_panel = true
  end
  if M.previous and M.previous.id == s.id or departing_panel == s then
    departing_panel = nil
    require('searchlight.controller').synchronize(s, 'capture')
    -- Keep only inputs and configuration, never jobs, results or source snapshots.
    M.previous = {
      initial = vim.deepcopy({
        root = s.root,
        mode = s.mode,
        fields = s.fields,
        options = s.options,
        sections = s.sections,
        heading = s.search_heading,
        config = s.config,
      }),
    }
  end
  s.disposed = true
  M.by_id[s.id], M.by_buf[s.buf] = nil, nil
  require('searchlight.highlight').detach(s)
  require('searchlight.search').cancel(s)
  if M.last == s.id then
    M.last = nil
    for id in pairs(M.by_id) do
      if not M.last or M.by_id[id].activated_at > M.by_id[M.last].activated_at then
        M.last = id
      end
    end
  end
end
function M.activate(s, new_tab)
  if not M.owns(s) then
    return
  end
  local current_tab = vim.api.nvim_get_current_tabpage()
  local chosen
  for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
    chosen = win
    if vim.api.nvim_win_get_tabpage(win) == current_tab then
      break
    end
  end
  if chosen then
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(chosen))
    vim.api.nvim_set_current_win(chosen)
  else
    local options = M.editor_options(vim.api.nvim_get_current_win())
    local buf = vim.api.nvim_get_current_buf()
    -- Current-tab panels can reuse an untouched startup editor.
    local empty_editor = #vim.api.nvim_tabpage_list_wins(current_tab) == 1
      and vim.api.nvim_win_get_config(0).relative == ''
      and vim.bo[buf].buftype == ''
      and vim.api.nvim_buf_get_name(buf) == ''
      and not vim.bo[buf].modified
      and vim.api.nvim_buf_line_count(buf) == 1
      and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
    if new_tab then
      vim.cmd('tab split')
    elseif not empty_editor then
      vim.cmd('topleft split')
    end
    vim.api.nvim_win_set_buf(0, s.buf)
    editor_options[vim.api.nvim_get_current_win()] = options
  end
  local win = vim.api.nvim_get_current_win()
  editor_options[win] = editor_options[win] or M.editor_options(win)
  for name, value in pairs(panel_options) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' })
  end
  -- An intentional visit supersedes the panel left during the buffer switch.
  departing_panel = nil
  M.touch(s)
  require('searchlight.highlight').request()
end
return M
