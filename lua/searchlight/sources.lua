local scope = require('searchlight.scope')
local M = {}

function M.disk(path, max_bytes)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return { exists = false }
  end
  if stat.type ~= 'file' then
    return nil, 'not a regular file'
  end
  if max_bytes and stat.size > max_bytes then
    return nil, 'source exceeds snapshot byte limit'
  end
  local fd, err = io.open(path, 'rb')
  if not fd then
    return nil, err
  end
  local raw = fd:read('*a')
  fd:close()
  local after = vim.uv.fs_stat(path)
  if
    not after
    or after.ino ~= stat.ino
    or after.size ~= stat.size
    or after.mtime.sec ~= stat.mtime.sec
    or after.mtime.nsec ~= stat.mtime.nsec
  then
    return nil, 'source changed during snapshot capture'
  end
  return {
    exists = true,
    hash = vim.fn.sha256(raw),
    raw = raw,
    ino = stat.ino,
    dev = stat.dev,
    size = stat.size,
  }
end

function M.text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

local function valid_utf8(text)
  local i = 1
  while i <= #text do
    local a = text:byte(i)
    if a < 128 then
      i = i + 1
    else
      local length = a >= 194 and a <= 223 and 2
        or a >= 224 and a <= 239 and 3
        or a >= 240 and a <= 244 and 4
        or nil
      if not length or i + length - 1 > #text then
        return false
      end
      for j = i + 1, i + length - 1 do
        local b = text:byte(j)
        if b < 128 or b > 191 then
          return false
        end
      end
      local b = text:byte(i + 1)
      if
        a == 224 and b < 160
        or a == 237 and b > 159
        or a == 240 and b < 144
        or a == 244 and b > 143
      then
        return false
      end
      i = i + length
    end
  end
  return true
end

local function decode(raw)
  local encoding = 'utf-8'
  if raw:sub(1, 3) == '\239\187\191' then
    raw = raw:sub(4)
  elseif raw:sub(1, 2) == '\255\254' then
    encoding = 'utf-16le'
    raw = raw:sub(3)
  elseif raw:sub(1, 2) == '\254\255' then
    encoding = 'utf-16be'
    raw = raw:sub(3)
  elseif not valid_utf8(raw) then
    encoding = 'latin1'
  end
  if encoding ~= 'utf-8' then
    local ok, decoded = pcall(vim.iconv, raw, encoding, 'utf-8')
    if not ok or not decoded or decoded == '' and raw ~= '' then
      return nil, 'unsupported source encoding'
    end
    raw = decoded
  end
  if raw:find('\0', 1, true) then
    return nil, 'binary source (NUL bytes)'
  end
  -- A mixed newline file cannot be mapped safely to native buffer lines.
  local text = raw:gsub('\r\n', '\n')
  if text:find('\r', 1, true) then
    return nil, 'mixed or unsupported source line endings'
  end
  return text
end

function M.capture(path, buf, max_bytes, prefer_disk)
  local disk, err = M.disk(path, max_bytes)
  if not disk then
    return nil, err
  end
  local text, tick
  if prefer_disk and buf and not vim.api.nvim_buf_is_loaded(buf) then
    buf = nil
  end
  if buf then
    if not prefer_disk then
      vim.fn.bufload(buf)
    end
    if
      not vim.api.nvim_buf_is_loaded(buf) or scope.path(vim.api.nvim_buf_get_name(buf)) ~= path
    then
      return nil, 'source was renamed or failed to load'
    end
    tick = vim.api.nvim_buf_get_changedtick(buf)
    if not prefer_disk then
      text = M.text(buf)
    end
  end
  if not text then
    if not disk.exists then
      return nil, 'source disappeared'
    end
    text, err = decode(disk.raw)
    if not text then
      return nil, err
    end
  end
  if #text > max_bytes then
    return nil, 'source exceeds snapshot byte limit'
  end
  disk.raw = nil
  local lines = vim.split(text, '\n', { plain = true })
  if text:sub(-1) == '\n' then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { '' }
  end
  local snap = {
    path = path,
    buf = buf,
    text = text,
    lines = lines,
    tick = tick,
    disk = disk,
    hash = vim.fn.sha256(text),
    endofline = text:sub(-1) == '\n',
  }
  if buf then
    snap.write_options = {}
    for _, key in ipairs({
      'fileformat',
      'fileencoding',
      'bomb',
      'endofline',
      'fixendofline',
      'binary',
    }) do
      snap.write_options[key] = vim.bo[buf][key]
    end
  end
  return snap
end

function M.validate(snap, load)
  local disk, err = M.disk(snap.path, snap.disk.size or 0)
  if not disk then
    return nil, err
  end
  if
    disk.exists ~= snap.disk.exists
    or disk.hash ~= snap.disk.hash
    or disk.ino ~= snap.disk.ino
    or disk.dev ~= snap.disk.dev
  then
    return nil, 'disk changed, deleted, or replaced since search'
  end
  local buf = snap.buf
  if
    buf
    and (
      not vim.api.nvim_buf_is_valid(buf)
      or not vim.api.nvim_buf_is_loaded(buf)
      or scope.path(vim.api.nvim_buf_get_name(buf)) ~= snap.path
    )
  then
    return nil, 'buffer deleted or renamed'
  end
  if not buf then
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.bo[candidate].buftype == ''
        and vim.api.nvim_buf_get_name(candidate) ~= ''
        and scope.path(vim.api.nvim_buf_get_name(candidate)) == snap.path
      then
        buf = candidate
        break
      end
    end
    if not buf and load then
      buf = vim.fn.bufadd(snap.path)
    end
    if buf and load then
      vim.fn.bufload(buf)
    end
  end
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    if snap.tick and vim.api.nvim_buf_get_changedtick(buf) ~= snap.tick then
      return nil, 'buffer changed since search'
    end
    if M.text(buf) ~= snap.text then
      return nil, 'buffer differs from search snapshot'
    end
    if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
      return nil, 'source buffer is not writable'
    end
    if snap.write_options then
      for key, value in pairs(snap.write_options) do
        if vim.bo[buf][key] ~= value then
          return nil, 'source write options changed since search'
        end
      end
    end
    -- Loading can invoke user autocmds; revalidate its disk baseline afterwards.
    local current = M.disk(snap.path, snap.disk.size or 0)
    if
      not current
      or current.exists ~= disk.exists
      or current.hash ~= disk.hash
      or current.ino ~= disk.ino
    then
      return nil, 'disk changed while loading source'
    end
    return buf
  end
  if load then
    return nil, 'source could not be loaded'
  end
  return true
end
return M
