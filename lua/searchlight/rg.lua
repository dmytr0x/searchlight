local M = {}
local capability, probing, waiting = nil, false, {}

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

local function probed(out)
  local result = { search = true, replacement = false }
  for line in (out.stdout or ''):gmatch('[^\n]+') do
    local ok, item = pcall(vim.json.decode, line)
    if ok and item.type == 'match' then
      result.replacement = M.value(item.data.submatches[1].replacement) == 'a!'
    end
  end
  if not result.replacement then
    result.reason = 'ripgrep JSON capture expansion unavailable; replacement disabled'
  end
  return result
end

-- Returns the ripgrep capability, or nil while the probe runs; `on_ready` then runs
-- on the main loop once it settles. The first call starts the probe.
function M.probe(on_ready)
  if not capability and not probing then
    if vim.fn.executable('rg') ~= 1 then
      capability = { search = false, replacement = false, reason = 'ripgrep is not installed' }
    else
      probing = true
      local ok = pcall(
        vim.system,
        { 'rg', '--no-config', '--json', '--replace=$1!', '--', '(a)', '-' },
        { stdin = 'a\n', text = true, timeout = 2000 },
        vim.schedule_wrap(function(out)
          -- Always settle, so waiting searches never hang on a malformed probe.
          local parsed, result = pcall(probed, out)
          capability, probing = parsed and result or probed({}), false
          local callbacks = waiting
          waiting = {}
          for _, callback in ipairs(callbacks) do
            callback()
          end
        end)
      )
      if not ok then
        probing = false
        capability = probed({})
      end
    end
  end
  if not capability and on_ready then
    table.insert(waiting, on_ready)
  end
  return capability
end

-- Fail closed on unknown configuration: discovery and stdin must agree on their semantics.
-- Match flags are intentionally normalized by the panel's explicit controls.
-- Returns the inventory-relevant settings ({ follow = boolean }), or nil and an error.
function M.config(ignored)
  local settings = { follow = false }
  if ignored then
    return settings
  end
  local path = vim.env.RIPGREP_CONFIG_PATH
  if not path or path == '' then
    return settings
  end
  local fd = io.open(path, 'r')
  if not fd then
    return nil, 'Cannot read RIPGREP_CONFIG_PATH: ' .. path
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
        return nil,
          'Unsupported ripgrep config argument: '
            .. line
            .. ' (use Also ignored or a supported config)'
      end
      if key == 'ignore-file' and value:sub(1, 1) ~= '/' then
        return nil, 'Relative --ignore-file in ripgrep config is unsupported; use an absolute path'
      end
      if key == 'follow' or key == 'no-follow' then
        settings.follow = key == 'follow'
      end
    end
  end
  return settings
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

local function query_flags(s, args)
  table.insert(args, s.options.case and '--case-sensitive' or '--ignore-case')
  if s.options.word then
    table.insert(args, '--word-regexp')
  end
  if not s.options.regex then
    table.insert(args, '--fixed-strings')
  end
  return args
end

function M.match(s)
  local args = query_flags(s, {
    'rg',
    '--no-config',
    '--json',
    '--color=never',
    '--max-columns=0',
    '--encoding=utf-8',
    '--context=' .. string.format('%.0f', s.options.context),
  })
  if M.probe().replacement then
    table.insert(args, '--replace=' .. s.fields.replacement)
  end
  vim.list_extend(args, { '--', s.fields.query, '-' })
  return args
end

-- macOS ARG_MAX is 1 MiB; stay well below it, environment included.
local batch_bytes = 256 * 1024

local function batches(base, paths)
  local result, args, size = {}, nil, 0
  for _, path in ipairs(paths) do
    if not args or size + #path + 1 > batch_bytes then
      args = vim.list_extend({}, base)
      size = 0
      for _, arg in ipairs(base) do
        size = size + #arg + 1
      end
      table.insert(result, args)
    end
    table.insert(args, path)
    size = size + #path + 1
  end
  return result
end

-- Files on disk whose query hits are a superset of hits in their decoded snapshots,
-- except for files listed by decode_sensitive.
function M.prefilter(s, paths)
  local base = query_flags(s, {
    'rg',
    '--no-config',
    '--files-with-matches',
    '--null',
    '--color=never',
    '--encoding=utf-8',
  })
  return batches(vim.list_extend(base, { '--regexp=' .. s.fields.query, '--' }), paths)
end

-- Files whose decoded snapshot can differ from what ripgrep matches on disk:
-- CR bytes (CRLF or mixed endings) and invalid UTF-8 (decoded as Latin-1).
function M.decode_sensitive(paths)
  return batches({
    'rg',
    '--no-config',
    '--files-with-matches',
    '--null',
    '--color=never',
    '--encoding=utf-8',
    '--regexp=\\r',
    '--regexp=\\x{FFFD}',
    '--',
  }, paths)
end

-- Streaming splitter for `sep`-terminated records, bounded even if the child never
-- sends `sep`. With `final`, returns and clears the unterminated tail.
function M.split(sep, on_record, limit)
  local carry = ''
  return function(chunk, final)
    local buf = carry .. (chunk or '')
    if #buf > limit then
      error('ripgrep output exceeds queue byte limit')
    end
    local start = 1
    while true do
      local pos = buf:find(sep, start, true)
      if not pos then
        break
      end
      on_record(buf:sub(start, pos - 1))
      start = pos + 1
    end
    carry = buf:sub(start)
    if final then
      local tail = carry
      carry = ''
      return tail
    end
  end
end

-- Streaming JSON decoder; the final record may lack a newline.
function M.decoder(on_item, limit)
  local split = M.split('\n', function(line)
    if line ~= '' then
      on_item(vim.json.decode(line))
    end
  end, limit)
  return function(chunk, final)
    local tail = split(chunk, final)
    if tail and tail ~= '' then
      on_item(vim.json.decode(tail))
    end
  end
end
return M
