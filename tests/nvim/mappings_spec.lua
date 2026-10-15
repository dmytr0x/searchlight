local H = require('tests.helpers')
local p = require('searchlight')
local defaults = { search = '<leader>sp', replace = '<leader>sr', recent = '<leader>sP' }
local custom = { search = '<F13>', replace = '<F14>', recent = '<F15>' }
local function map(key)
  return vim.fn.maparg(key, 'n', false, true)
end
local function isolated(run)
  local config, leader = vim.deepcopy(p.config), vim.g.mapleader
  local saved = {}
  local keys =
    { '<leader>sp', '<leader>sr', '<leader>sP', '<F13>', '<F14>', '<F15>', '<F16>', '<F17>' }
  -- Disabling first leaves only user mappings to preserve, regardless of description.
  p.setup({ mappings = { search = false, replace = false, recent = false } })
  for _, key in ipairs(keys) do
    saved[key] = map(key)
  end
  p.setup(config)
  local ok, err = xpcall(run, debug.traceback)
  p.setup({ mappings = { search = false, replace = false, recent = false } })
  vim.g.mapleader = leader
  for _, key in ipairs(keys) do
    pcall(vim.keymap.del, 'n', key)
  end
  for _, value in pairs(saved) do
    if next(value) then
      vim.fn.mapset('n', false, value)
    end
  end
  p.setup(config)
  assert(ok, err)
end

H.test(
  'search replace and recent defaults call their matching entry points',
  'Mappings,Entries',
  function()
    isolated(function()
      p.setup({ mappings = defaults })
      local original = { search = p.search, replace = p.replace, recent = p.recent }
      local calls = {}
      local ok, err = xpcall(function()
        for _, action in ipairs({ 'search', 'replace', 'recent' }) do
          p[action] = function()
            calls[#calls + 1] = action
          end
        end
        for _, action in ipairs({ 'search', 'replace', 'recent' }) do
          local mapping = map(defaults[action])
          assert(mapping.callback)
          mapping.callback()
          H.eq(calls[#calls], action)
        end
        H.eq(map(defaults.search).desc, 'Searchlight: search')
        H.eq(map(defaults.replace).desc, 'Searchlight: search and replace')
        H.eq(map(defaults.recent).desc, 'Searchlight: restore recent session')
      end, debug.traceback)
      for action, operation in pairs(original) do
        p[action] = operation
      end
      assert(ok, err)
    end)
  end
)

H.test(
  'partial mapping config remaps disables and retains omitted values',
  'Mappings,Setup',
  function()
    isolated(function()
      p.setup({ mappings = custom })
      for _, action in ipairs({ 'search', 'replace', 'recent' }) do
        H.eq(map(defaults[action]), {})
        assert(map(custom[action]).callback)
      end
      local callback = map(custom.search).callback
      local observers = #vim.api.nvim_get_autocmds({ group = 'SearchlightSources' })
      for _ = 1, 3 do
        p.setup()
      end
      H.eq(map(custom.search).callback, callback)
      H.eq(#vim.api.nvim_get_autocmds({ group = 'SearchlightSources' }), observers)
      p.setup({ mappings = { search = '<F16>', replace = false } })
      H.eq(map(custom.search), {})
      H.eq(map(custom.replace), {})
      assert(map('<F16>').callback)
      assert(map(custom.recent).callback)
      H.eq(p.config.mappings, { search = '<F16>', replace = false, recent = '<F15>' })
      p.setup({ mappings = { search = false, recent = false } })
      H.eq(map('<F16>'), {})
      H.eq(map(custom.recent), {})
      for _, name in ipairs({ 'SearchlightNew', 'SearchlightReplaceNew', 'SearchlightFocus' }) do
        assert(vim.api.nvim_get_commands({})[name])
      end
      local a = H.fixture()
      H.eq(p.search(a).mode, 'search')
      H.eq(p.replace(a).mode, 'replace')
    end)
  end
)

H.test(
  'invalid mappings and effective key collisions leave config and registration unchanged',
  'Mappings,Validation',
  function()
    isolated(function()
      p.setup({ mappings = custom })
      local before = vim.deepcopy(p.config)
      local callbacks = { map('<F13>').callback, map('<F14>').callback, map('<F15>').callback }
      local commands = vim.api.nvim_get_commands({})
      for _, options in ipairs({
        { mappings = false },
        { mappings = 'abc' },
        { mappings = { search = '' } },
        { mappings = { replace = true } },
        { mappings = { recent = 2 } },
        { mappings = { search = {} } },
        { mappings = { other = '<F16>' } },
        { mappings = { new = '<F16>' } },
        { mappings = { focus = '<F16>' } },
        { mappings = { replace_new = '<F16>' } },
        { mappings = { replace = '<F13>' } },
        { mappings = { search = '<Tab>', replace = '<C-I>' } },
        { mappings = { search = '<leader>sp', replace = (vim.g.mapleader or '\\') .. 'sp' } },
        { debounce_ms = 99, mappings = { search = '<F14>' } },
        { defaults = { context = -1 }, mappings = { search = '<F16>' } },
      }) do
        H.eq(pcall(p.setup, options), false)
        H.eq(p.config, before)
        H.eq({ map('<F13>').callback, map('<F14>').callback, map('<F15>').callback }, callbacks)
        H.eq(vim.api.nvim_get_commands({}), commands)
      end
    end)
  end
)

H.test(
  'user mappings including Searchlight descriptions survive setup and remapping',
  'Mappings,Ownership',
  function()
    isolated(function()
      p.setup({ mappings = { search = false, replace = false, recent = false } })
      local user = function() end
      vim.keymap.set('n', '<F13>', user, { desc = 'Searchlight: user search' })
      vim.keymap.set('n', '<F14>', ':echo "user"<CR>', { desc = 'Other plugin' })
      p.setup({ mappings = custom })
      H.eq(map('<F13>').callback, user)
      H.eq(map('<F14>').rhs, ':echo "user"<CR>')
      local recent = function() end
      vim.keymap.set('n', '<F15>', recent, { desc = 'Searchlight: restore recent session' })
      p.setup()
      H.eq(map('<F15>').callback, recent)
      p.setup({ mappings = { search = '<F16>', replace = false, recent = false } })
      H.eq(map('<F13>').callback, user)
      H.eq(map('<F14>').rhs, ':echo "user"<CR>')
      H.eq(map('<F15>').callback, recent)
      assert(map('<F16>').callback)
      local replacement = function() end
      vim.keymap.set('n', '<F16>', replacement, { desc = 'Searchlight: search' })
      p.setup({ mappings = { search = '<F17>' } })
      H.eq(map('<F16>').callback, replacement)
      assert(map('<F17>').callback)
    end)
  end
)

H.test(
  'leader changes remove mappings using their original expanded keys',
  'Mappings,Ownership',
  function()
    isolated(function()
      p.setup({ mappings = { search = false, replace = false, recent = false } })
      vim.g.mapleader = '<F13>'
      p.setup({ mappings = { search = '<leader>s' } })
      assert(map('<F13>s').callback)
      vim.g.mapleader = '<F14>'
      local ok, err = xpcall(function()
        p.setup()
        H.eq(map('<F13>s'), {})
        assert(map('<F14>s').callback)
        p.setup({ mappings = { search = false } })
        H.eq(map('<F14>s'), {})
      end, debug.traceback)
      pcall(vim.keymap.del, 'n', '<F13>s')
      pcall(vim.keymap.del, 'n', '<F14>s')
      assert(ok, err)
    end)
  end
)
