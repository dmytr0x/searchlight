-- Input rules have no session, job, buffer or window ownership.
local modes = require('searchlight.modes')
local M = {}
local controls = {
  {
    option = 'case',
    label = 'Aa',
    key = 'c',
    meaning = 'Match case',
  },
  {
    option = 'word',
    label = 'wd',
    key = 'w',
    meaning = 'Match whole words',
  },
  {
    option = 'regex',
    label = '.*',
    key = 'x',
    meaning = 'Use regular expressions',
  },
  {
    option = 'open',
    label = '󰥩',
    key = 'o',
    meaning = 'Only search open files',
  },
  {
    option = 'ignored',
    label = '',
    key = 'g',
    meaning = 'Also search ignored files',
  },
}

M.controls = controls
M.defaults = { context = 2, max_results = 10000, close_on_open = false }
for _, control in ipairs(controls) do
  M.defaults[control.option] = false
end

function M.valid_context_size(value)
  return type(value) == 'number' and value >= 0 and value < math.huge and value == math.floor(value)
end

function M.options(config)
  local options = { context = config.defaults.context }
  for _, control in ipairs(controls) do
    options[control.option] = config.defaults[control.option]
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
  assert(type(changes) == 'table', 'Searchlight changes must be a table')
  local fields, options, root = vim.deepcopy(s.fields), vim.deepcopy(s.options), s.root
  local config, sections = vim.deepcopy(s.config), vim.deepcopy(s.sections)
  for key, value in pairs(changes) do
    assert(key ~= 'mode', 'Searchlight session mode cannot be changed')
    assert(key ~= 'replacement' or modes.can_replace(s), modes.replacement_reason)
    if fields[key] ~= nil then
      if key == 'include' or key == 'exclude' then
        assert(type(value) == 'table', key .. ' must be a list of globs')
        local count = 0
        for index, glob in pairs(value) do
          assert(
            type(index) == 'number'
              and index >= 1
              and index < math.huge
              and index == math.floor(index),
            key .. ' must be a dense list of globs'
          )
          count = count + 1
          assert(
            type(glob) == 'string' and not glob:find('[\r\n]'),
            'filter entries must be single lines of comma-separated globs'
          )
        end
        for index = 1, count do
          assert(value[index] ~= nil, key .. ' must be a dense list of globs')
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
        assert(type(value) == 'boolean', key .. ' must be a boolean')
      end
      options[key] = value
    elseif key == 'root' then
      assert(type(value) == 'string', 'root must be a path string')
      root = path(value)
    elseif key == 'max_results' then
      assert(
        M.valid_context_size(value) and value > 0,
        'max_results must be a positive whole number'
      )
      config.max_results = value
    elseif key == 'close_on_open' then
      assert(type(value) == 'boolean', 'close_on_open must be a boolean')
      config.close_on_open = value
    elseif key == 'sections' then
      assert(type(value) == 'table', 'sections must be a table')
      for name, visible in pairs(value) do
        assert(name ~= 'replace' or modes.can_replace(s), modes.replacement_reason)
        assert(
          name == 'filters' or name == 'help' or name == 'replace',
          'Unknown Searchlight section: ' .. tostring(name)
        )
        assert(type(visible) == 'boolean', 'section visibility must be a boolean')
        sections[name] = visible
      end
    else
      error('Unknown Searchlight setting: ' .. tostring(key))
    end
  end
  return {
    fields = fields,
    options = options,
    root = root,
    config = config,
    sections = sections,
    heading = M.patch_heading(s.search_heading or M.heading(s.options), changes),
    search_changed = not vim.deep_equal(fields, s.fields)
      or not vim.deep_equal(options, s.options)
      or root ~= s.root
      or config.max_results ~= s.config.max_results,
    presentation_changed = not vim.deep_equal(sections, s.sections)
      or config.close_on_open ~= s.config.close_on_open,
  }
end

function M.execution(execution, default)
  assert(execution == nil or type(execution) == 'table', 'Searchlight execution must be a table')
  local policy = default
  for key, value in pairs(execution or {}) do
    assert(key == 'refresh', 'Unknown Searchlight execution setting: ' .. tostring(key))
    assert(
      value == false or value == 'debounced' or value == 'immediate',
      "refresh must be false, 'debounced', or 'immediate'"
    )
    policy = value
  end
  return policy
end

function M.valid_setting(key, value, default)
  if key == 'context' then
    return M.valid_context_size(value)
  end
  if type(default) == 'boolean' then
    return type(value) == 'boolean'
  end
  return type(default) == 'number'
    and type(value) == 'number'
    and value < math.huge
    and value == math.floor(value)
    and value >= (key == 'debounce_ms' and 0 or 1)
end
return M
