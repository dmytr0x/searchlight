-- Evaluation adapter only. Not loaded by the shipped runtime.
local M = { sessions = {}, next_id = 0 }
function M.new(root, values)
  M.next_id = M.next_id + 1
  local name = 'searchlight-prototype-' .. M.next_id
  require('grug-far').open({
    instanceName = name,
    transient = false,
    minSearchChars = 1,
    debounceMs = 10,
    normalModeSearch = true,
    icons = { enabled = false },
    prefills = values,
  })
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd.lcd(vim.fn.fnameescape(root))
  vim.wait(100)
  local s =
    { name = name, buf = buf, root = root, instance = require('grug-far').get_instance(name) }
  M.sessions[M.next_id] = s
  return s
end
function M.controls(s, opts, includes, excludes)
  local flags = { opts.case and '--case-sensitive' or '--ignore-case' }
  if opts.word then
    table.insert(flags, '--word-regexp')
  end
  if not opts.regex then
    table.insert(flags, '--fixed-strings')
  end
  if opts.ignored then
    vim.list_extend(flags, { '--no-config', '--no-ignore', '--hidden' })
  end
  local globs = vim.deepcopy(includes or {})
  for _, p in ipairs(excludes or {}) do
    table.insert(globs, '!' .. p)
  end
  table.insert(globs, '!.git/**')
  s.instance:update_input_values({
    flags = table.concat(flags, ' '),
    filesFilter = table.concat(globs, '\n'),
    paths = opts.open and '<buflist-cwd>' or s.root,
  }, false)
end
function M.focus(s)
  s.instance:open()
end
return M
