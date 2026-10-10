-- Input rules have no session, job, buffer or window ownership.
local M = {}
local controls = {
  {
    option = 'case',
    setting = 'match_case_sensetivity',
    label = 'Aa',
    key = 'c',
    meaning = 'Match case',
  },
  {
    option = 'word',
    setting = 'match_whole_words',
    label = 'wd',
    key = 'w',
    meaning = 'Match whole words',
  },
  {
    option = 'regex',
    setting = 'use_regular_expressions',
    label = '.*',
    key = 'x',
    meaning = 'Use regular expressions',
  },
  {
    option = 'open',
    setting = 'only_search_open_files',
    label = '󰥩',
    key = 'o',
    meaning = 'Only search open files',
  },
  {
    option = 'ignored',
    setting = 'also_search_ignored_files',
    label = '',
    key = 'g',
    meaning = 'Also search ignored files',
  },
}

M.controls = controls
-- Keep the observable settings map generated from the single control definition.
M.option_settings = {}
M.defaults = { context_size = 2 }
for _, control in ipairs(controls) do
  M.option_settings[control.option] = control.setting
  M.defaults[control.setting] = false
end

function M.valid_context_size(value)
  return type(value) == 'number' and value >= 0 and value < math.huge and value == math.floor(value)
end

function M.options(config)
  local options = { context = config.context_size }
  for _, control in ipairs(controls) do
    options[control.option] = config[control.setting] == true
  end
  return options
end

function M.heading(options)
  local parts = {}
  for _, control in ipairs(controls) do
    table.insert(parts, control.label .. (options[control.option] and '[x]' or '[ ]'))
  end
  table.insert(parts, '↕[' .. string.format('%.0f', options.context) .. ']')
  return '[Search]    ' .. table.concat(parts, '  ')
end

function M.is_heading(line)
  return line:match('^%[Search%]%s+Aa') ~= nil
end

function M.parse_heading(line, previous)
  local options = vim.deepcopy(previous)
  for _, control in ipairs(controls) do
    local value = line:match(vim.pesc(control.label) .. '%[([^%[%]]*)%]')
    -- Enable only when the brackets contain a character other than an ASCII space.
    options[control.option] = value ~= nil and value:find('[^ ]') ~= nil
  end
  local value = line:match('↕%[%s*(%d+)%s*%]')
  local context = value and tonumber(value)
  -- Incomplete or invalid edits keep the last valid size while preserving the text.
  if M.valid_context_size(context) then
    options.context = context
  end
  return options
end

function M.patch_heading(line, changes)
  for _, control in ipairs(controls) do
    if changes[control.option] ~= nil then
      local text = control.label .. (changes[control.option] and '[x]' or '[ ]')
      local count
      line, count = line:gsub(vim.pesc(control.label) .. '%[[^%[%]]*%]', function()
        return text
      end, 1)
      if count == 0 then
        line = line .. '  ' .. text
      end
    end
  end
  if changes.context ~= nil then
    local text = '↕[' .. string.format('%.0f', changes.context) .. ']'
    local count
    line, count = line:gsub('↕%[[^%[%]]*%]', function()
      return text
    end, 1)
    if count == 0 then
      line = line .. '  ' .. text
    end
  end
  return line
end

-- Construct the entire update before committing any values to the owning session.
function M.update(s, changes, path)
  local fields, options, root = vim.deepcopy(s.fields), vim.deepcopy(s.options), s.root
  for key, value in pairs(changes) do
    if fields[key] ~= nil then
      if key == 'include' or key == 'exclude' then
        assert(type(value) == 'table', key .. ' must be a list of globs')
        for _, glob in ipairs(value) do
          assert(
            type(glob) == 'string' and not glob:find('[\r\n]'),
            'filter entries must be single lines of comma-separated globs'
          )
        end
      else
        assert(
          type(value) == 'string' and not value:find('[\r\n]'),
          key .. ' must be one logical line'
        )
      end
      fields[key] = vim.deepcopy(value)
    elseif options[key] ~= nil then
      if key == 'context' then
        assert(M.valid_context_size(value), 'context must be a nonnegative whole number')
      else
        assert(type(value) == 'boolean')
      end
      options[key] = value
    elseif key == 'root' then
      assert(type(value) == 'string', 'root must be a path string')
      root = path(value)
    else
      error('Unknown Searchlight setting: ' .. key)
    end
  end
  return {
    fields = fields,
    options = options,
    root = root,
    heading = M.patch_heading(s.search_heading or M.heading(s.options), changes),
  }
end

function M.valid_setting(key, value, default)
  if key == 'context_size' then
    return M.valid_context_size(value)
  end
  if type(default) == 'boolean' then
    return type(value) == 'boolean'
  end
  return type(default) == 'number' and type(value) == 'number'
    and value == math.floor(value) and value >= (key == 'debounce_ms' and 0 or 1)
end
return M
