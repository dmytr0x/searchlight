local M = {}
local capability

function M.value(value)
  if not value or value == vim.NIL then
    return nil
  end
  if value.text then
    return value.text
  end
  if value.bytes then
    return vim.base64.decode(value.bytes)
  end
  error('Malformed ripgrep byte value')
end

function M.probe()
  if capability then
    return capability
  end
  capability = { search = vim.fn.executable('rg') == 1, replacement = false }
  if not capability.search then
    capability.reason = 'ripgrep is not installed'
    return capability
  end
  local out = vim
    .system(
      { 'rg', '--no-config', '--json', '--replace=$1!', '--', '(a)', '-' },
      { stdin = 'a\n', text = true }
    )
    :wait(2000)
  for line in (out.stdout or ''):gmatch('[^\n]+') do
    local ok, item = pcall(vim.json.decode, line)
    if ok and item.type == 'match' then
      capability.replacement = M.value(item.data.submatches[1].replacement) == 'a!'
    end
  end
  if not capability.replacement then
    capability.reason = 'ripgrep JSON capture expansion unavailable; replacement disabled'
  end
  return capability
end

-- Fail closed on unknown configuration: discovery and stdin must agree on their semantics.
-- Match flags are intentionally normalized by the panel's explicit controls.
function M.config_error(ignored)
  if ignored then
    return
  end
  local path = vim.env.RIPGREP_CONFIG_PATH
  if not path or path == '' then
    return
  end
  local fd = io.open(path, 'r')
  if not fd then
    return 'Cannot read RIPGREP_CONFIG_PATH: ' .. path
  end
  local args = fd:read('*a')
  fd:close()
  local with_value = {
    glob = true,
    iglob = true,
    ['ignore-file'] = true,
    type = true,
    ['type-not'] = true,
    ['type-add'] = true,
    ['type-clear'] = true,
    ['max-columns'] = true,
  }
  local simple = {
    hidden = true,
    ['no-hidden'] = true,
    follow = true,
    ['no-follow'] = true,
    ['no-ignore'] = true,
    ['no-ignore-vcs'] = true,
    ['no-ignore-parent'] = true,
    ['no-ignore-global'] = true,
    ['no-ignore-dot'] = true,
    ['no-ignore-exclude'] = true,
    ['require-git'] = true,
    ['no-require-git'] = true,
    ['ignore-case'] = true,
    ['case-sensitive'] = true,
    ['smart-case'] = true,
    ['fixed-strings'] = true,
    ['word-regexp'] = true,
    ['no-heading'] = true,
    ['max-columns-preview'] = true,
  }
  for line in args:gmatch('[^\r\n]+') do
    line = vim.trim(line)
    if line ~= '' and line:sub(1, 1) ~= '#' then
      local key, value = line:match('^%-%-([%w-]+)=(.*)$')
      if not key then
        key = line:match('^%-%-([%w-]+)$')
      end
      if not key or not (simple[key] and not value or with_value[key] and value) then
        return 'Unsupported ripgrep config argument: '
          .. line
          .. ' (use Also ignored or a supported config)'
      end
      if key == 'ignore-file' and value:sub(1, 1) ~= '/' then
        return 'Relative --ignore-file in ripgrep config is unsupported; use an absolute path'
      end
    end
  end
end

-- Split declarations without consuming commas belonging to ripgrep glob syntax.
-- Keep the original lines in the session so refreshes preserve panel editing.
local function filter_globs(lines)
  local globs = {}
  for _, line in ipairs(lines) do
    local first, braces, class_close, escaped = 1, 0, nil, false
    local function add(last)
      local glob = vim.trim(line:sub(first, last))
      if glob ~= '' then
        table.insert(globs, glob)
      end
      first = last + 2
    end
    for i = 1, #line do
      local char = line:sub(i, i)
      if escaped then
        escaped = false
      elseif char == '\\' then
        escaped = true
      elseif class_close then
        if char == ']' and i >= class_close then
          class_close = nil
        end
      elseif char == '[' then
        class_close = i + 1
        if line:sub(class_close, class_close):match('[!^]') then
          class_close = class_close + 1
        end
        if line:sub(class_close, class_close) == ']' then
          class_close = class_close + 1
        end
      elseif char == '{' then
        braces = braces + 1
      elseif char == '}' then
        braces = math.max(0, braces - 1)
      elseif char == ',' and braces == 0 then
        add(i - 1)
      end
    end
    add(#line)
  end
  return globs
end

function M.inventory(s)
  local args = { 'rg' }
  if s.options.ignored then
    vim.list_extend(args, { '--no-config', '--no-ignore' })
  end
  -- Hidden ancestors (for example .config) are ordinary project sources.
  -- This does not disable config globs or ignore files; ignored mode owns that.
  vim.list_extend(args, { '--hidden', '--files', '--null', '--color=never', '--max-columns=0' })
  for _, glob in ipairs(filter_globs(s.fields.include)) do
    if glob:sub(1, 1) == '!' then
      error('Include globs must be positive; use Exclude for negation')
    end
    table.insert(args, '--glob=' .. glob)
  end
  for _, glob in ipairs(filter_globs(s.fields.exclude)) do
    if glob:sub(1, 1) == '!' then
      error('Exclude globs must be positive; each excludes a path')
    end
    table.insert(args, '--glob=!' .. glob)
  end
  -- Mandatory metadata policy comes last, so a positive UI glob cannot override it.
  vim.list_extend(args, { '--glob=!.git', '--glob=!.git/**', '--glob=!**/.git/**', '--', '.' })
  return args
end

function M.match(s)
  local args = {
    'rg',
    '--no-config',
    '--json',
    '--color=never',
    '--max-columns=0',
    '--encoding=utf-8',
    '--context=' .. string.format('%.0f', s.options.context),
    s.options.case and '--case-sensitive' or '--ignore-case',
  }
  if s.options.word then
    table.insert(args, '--word-regexp')
  end
  if not s.options.regex then
    table.insert(args, '--fixed-strings')
  end
  if M.probe().replacement then
    table.insert(args, '--replace=' .. s.fields.replacement)
  end
  vim.list_extend(args, { '--', s.fields.query, '-' })
  return args
end

-- Streaming JSON decoder, bounded even if the child never sends a newline.
function M.decoder(on_item, limit)
  local carry = ''
  return function(chunk, final)
    carry = carry .. (chunk or '')
    if #carry > limit then
      error('ripgrep output exceeds queue byte limit')
    end
    while true do
      local pos = carry:find('\n', 1, true)
      if not pos then
        break
      end
      local line = carry:sub(1, pos - 1)
      carry = carry:sub(pos + 1)
      if line ~= '' then
        on_item(vim.json.decode(line))
      end
    end
    if final and carry ~= '' then
      on_item(vim.json.decode(carry))
      carry = ''
    end
  end
end
return M
