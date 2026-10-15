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
    mappings = { search = '<leader>sp', replace = '<leader>sr', recent = '<leader>sP' },
    syntax_highlighting = true,
    syntax_injections = false,
    syntax_max_file_bytes = 128 * 1024,
    debounce_ms = 150,
    max_results = 10000,
    concurrency = 4,
    max_files = 100000,
    max_output_bytes = 4 * 1024 * 1024,
    max_source_bytes = 8 * 1024 * 1024,
    max_snapshot_bytes = 64 * 1024 * 1024,
  }),
}

local function create_session(root, mode)
  root = scope.path(root and root ~= '' and root or vim.fn.getcwd())
  local s = sessions.create(root, M.config, mode)
  view.attach(s)
  view.render(s)
  sessions.activate(s)
  view.focus_field(s, 'query')
  return s
end

function M.search(root)
  return create_session(root, 'search')
end

function M.replace(root)
  return create_session(root, 'replace')
end

function M.recent(id)
  local s = sessions.get(id or sessions.last)
  if not s then
    vim.notify('No surviving Searchlight session', vim.log.levels.INFO)
    return
  end
  sessions.activate(s)
  return s
end

M.close = controller.close
M.set = controller.set
M.refresh = controller.refresh
M.navigate = actions.navigate
M.open = actions.open
M.action = controller.action

local entries = {
  search = { command = 'SearchlightNew', description = 'search' },
  replace = { command = 'SearchlightReplaceNew', description = 'search and replace' },
  recent = { command = 'SearchlightFocus', description = 'restore recent session' },
}
local owned_mappings = {}

-- Store expanded keys: changing mapleader later must not orphan an installed map.
local function mapping_lhs(lhs)
  return lhs
    :gsub('<[Ll][Ee][Aa][Dd][Ee][Rr]>', function()
      return vim.g.mapleader or '\\'
    end)
    :gsub('<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>', function()
      return vim.g.maplocalleader or '\\'
    end)
end

local function mapping_key(lhs)
  return vim.api.nvim_replace_termcodes(mapping_lhs(lhs), true, true, true)
end

local function global_mapping(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
    if mapping_key(map.lhs) == lhs then
      return map
    end
  end
end

local function proposed_config(options)
  assert(type(options) == 'table', 'Invalid Searchlight configuration')
  local config = vim.deepcopy(M.config)
  for key, value in pairs(options) do
    if key == 'mappings' then
      assert(type(value) == 'table', 'Invalid Searchlight configuration: mappings')
      for action, lhs in pairs(value) do
        assert(
          entries[action] and (lhs == false or type(lhs) == 'string' and lhs ~= ''),
          'Invalid Searchlight mapping: ' .. tostring(action)
        )
        config.mappings[action] = lhs
      end
    else
      local default = config[key]
      assert(
        default ~= nil and input.valid_setting(key, value, default),
        'Invalid Searchlight configuration: ' .. tostring(key)
      )
      config[key] = value
    end
  end
  local keys = {}
  for action, lhs in pairs(config.mappings) do
    if lhs then
      local key = mapping_key(lhs)
      assert(not keys[key], 'Searchlight mappings must use distinct keys: ' .. action)
      keys[key] = action
    end
  end
  return config
end

local function register_mappings()
  for action, owned in pairs(owned_mappings) do
    local lhs = M.config.mappings[action]
    if not lhs or mapping_key(lhs) ~= owned.lhs then
      local existing = global_mapping(owned.lhs)
      if existing and existing.callback == owned.callback then
        vim.keymap.del('n', existing.lhs)
      end
      owned_mappings[action] = nil
    end
  end
  for action, entry in pairs(entries) do
    local lhs = M.config.mappings[action]
    if lhs then
      local key = mapping_key(lhs)
      local existing = global_mapping(key)
      if not existing then
        local callback = function()
          M[action]()
        end
        vim.keymap.set(
          'n',
          mapping_lhs(lhs),
          callback,
          { desc = 'Searchlight: ' .. entry.description }
        )
        owned_mappings[action] = { lhs = key, callback = callback }
      end
    end
  end
end

function M.setup(options)
  assert(
    vim.system and vim.uv and vim.fs and vim.fs.dir and vim.base64 and vim.json,
    'Searchlight requires Neovim with vim.system, vim.uv, vim.fs.dir, vim.base64 and vim.json'
  )
  local config = proposed_config(options or {})
  M.config = config
  for _, action in ipairs({ 'search', 'replace' }) do
    vim.api.nvim_create_user_command(entries[action].command, function(args)
      M[action](args.fargs[1])
    end, { nargs = '?', complete = 'dir', force = true })
  end
  vim.api.nvim_create_user_command(entries.recent.command, function(args)
    if args.args ~= '' and not tonumber(args.args) then
      vim.notify('SearchlightFocus expects a session id', vim.log.levels.ERROR)
      return
    end
    M.recent(tonumber(args.args))
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
  register_mappings()
  observe.setup()
  rg.probe()
end
return M
