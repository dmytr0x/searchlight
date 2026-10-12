local input = require('searchlight.input')
local sessions = require('searchlight.sessions')
local search = require('searchlight.search')
local scope = require('searchlight.scope')
local view = require('searchlight.view')
local actions = require('searchlight.actions')
local observe = require('searchlight.observe')
local M = {
  config = vim.tbl_extend('force', input.defaults, {
    syntax_highlighting = true,
    syntax_injections = false,
    syntax_max_file_bytes = 256 * 1024,
    debounce_ms = 150,
    max_results = 10000,
    concurrency = 4,
    max_files = 100000,
    max_output_bytes = 4 * 1024 * 1024,
    max_source_bytes = 8 * 1024 * 1024,
    max_snapshot_bytes = 64 * 1024 * 1024,
  }),
}

local function own(s)
  s = sessions.get(s)
  assert(s, 'No owning Searchlight session')
  return s
end

function M.new(root)
  root = scope.path(root and root ~= '' and root or vim.fn.getcwd())
  local s = sessions.create(root, M.config)
  view.attach(s)
  view.render(s)
  sessions.focus(s)
  view.focus_field(s, 'query')
  return s
end

function M.focus(id)
  local s = sessions.get(id or sessions.last)
  if not s then
    vim.notify('No surviving Searchlight session', vim.log.levels.INFO)
    return
  end
  sessions.focus(s)
  return s
end

function M.close(s)
  s = own(s)
  sessions.dispose(s)
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
end

-- Every input origin comes through this coordinator. Reading regions reports changes;
-- only the coordinator chooses whether they invalidate, debounce or submit immediately.
function M._synchronize(s, origin, changes)
  local read = view.read(s)
  if read then
    for name, value in pairs(read.fields) do
      s.fields[name] = value
    end
    s.options, s.search_heading = read.options, read.heading
  end
  local changed = s.input_changed or read and read.changed or false
  if origin == 'capture' then
    s.input_changed = changed or nil
    return changed
  end
  s.input_changed = nil
  if origin == 'set' then
    local next_input = input.update(s, changes, scope.path)
    s.fields, s.options, s.root = next_input.fields, next_input.options, next_input.root
    s.search_heading = next_input.heading
    s.fields_dirty, s.navigation_end, s.selection_after = true, false, nil
    search.invalidate(s)
  elseif origin == 'refresh' then
    search.refresh(s)
  elseif changed then
    search.invalidate(s, '', false)
  end
  sessions.sync_name(s)
  return changed
end

function M.set(s, changes)
  s = own(s)
  M._synchronize(s, 'set', changes)
  view.render(s)
end

function M.refresh(s)
  s = own(s)
  M._synchronize(s, 'refresh')
end

M.navigate = actions.navigate
M.open = actions.open
M.action = actions.action

function M.setup(options)
  assert(
    vim.system and vim.uv and vim.fs and vim.fs.dir and vim.base64 and vim.json,
    'Searchlight requires Neovim with vim.system, vim.uv, vim.fs.dir, vim.base64 and vim.json'
  )
  options = options or {}
  for key, value in pairs(options) do
    local default = M.config[key]
    assert(
      default ~= nil and input.valid_setting(key, value, default),
      'Invalid Searchlight configuration: ' .. key
    )
    M.config[key] = value
  end
  vim.api.nvim_create_user_command('SearchlightNew', function(args)
    M.new(args.fargs[1])
  end, { nargs = '?', complete = 'dir', force = true })
  vim.api.nvim_create_user_command('SearchlightFocus', function(args)
    if args.args ~= '' and not tonumber(args.args) then
      vim.notify('SearchlightFocus expects a session id', vim.log.levels.ERROR)
      return
    end
    M.focus(tonumber(args.args))
  end, {
    nargs = '?',
    force = true,
    complete = function()
      local ids = {}
      for id in pairs(sessions.by_id) do
        table.insert(ids, tostring(id))
      end
      table.sort(ids)
      return ids
    end,
  })
  vim.api.nvim_create_user_command('SearchlightClose', function()
    M.close()
  end, { force = true })
  for key, operation in pairs({ ['<leader>sp'] = M.new, ['<leader>sP'] = M.focus }) do
    local existing = vim.fn.maparg(key, 'n', false, true)
    if vim.tbl_isempty(existing) or (existing.desc or ''):match('^Searchlight:') then
      vim.keymap.set('n', key, function()
        operation()
      end, { desc = 'Searchlight: ' .. (key == '<leader>sp' and 'new' or 'focus') })
    end
  end
  observe.setup()
end
return M
