local input = require('searchlight.input')
local sessions = require('searchlight.sessions')
local scope = require('searchlight.scope')
local rg = require('searchlight.rg')
local view = require('searchlight.view')
local actions = require('searchlight.actions')
local observe = require('searchlight.observe')
local controller = require('searchlight.controller')
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

M.close = controller.close
M.set = controller.set
M.refresh = controller.refresh
M.navigate = actions.navigate
M.open = actions.open
M.action = controller.action

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
  rg.probe()
end
return M
