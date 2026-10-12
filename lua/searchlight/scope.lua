local uv = vim.uv
local M = {}

function M.path(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p')):gsub('/+$', '')
  if path == '' then
    path = '/'
  end
  local real = uv.fs_realpath(path)
  if real then
    return real
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    return M.path(parent) .. '/' .. vim.fs.basename(path)
  end
  return path
end

function M.contains(root, path)
  return path == root or root == '/' or path:sub(1, #root + 1) == root .. '/'
end

function M.relative(root, path)
  return root == '/' and path:sub(2) or path:sub(#root + 2)
end

function M.identity_of(stat)
  return 'file:' .. stat.dev .. ':' .. stat.ino
end

function M.identity(path)
  local stat = uv.fs_stat(path)
  return stat and M.identity_of(stat) or ('path:' .. path)
end

function M.metadata(root, path)
  local rel = M.relative(root, path)
  return rel == '.git'
    or rel:match('^%.git/') ~= nil
    or rel:match('/%.git/') ~= nil
    or rel:match('/%.git$') ~= nil
end

function M.buffers(root)
  local buffers, identities = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.bo[buf].buftype == '' then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' then
        local path = M.path(name)
        if M.contains(root, path) and not M.metadata(root, path) then
          local identity = M.identity(path)
          if identities[identity] then
            error('Multiple listed buffers refer to the same source: ' .. path)
          end
          identities[identity] = true
          table.insert(buffers, { path = path, buf = buf })
        end
      end
    end
  end
  return buffers
end

local function copy(from, to)
  local fd = io.open(from, 'rb')
  if not fd then
    return
  end
  local data = fd:read('*a')
  fd:close()
  vim.fn.mkdir(vim.fs.dirname(to), 'p')
  local out = assert(io.open(to, 'wb'))
  out:write(data)
  out:close()
end

-- Delegate new-file eligibility to ripgrep itself, in a disposable tree containing
-- only candidate names and their ancestor ignore policy. No Lua glob approximation,
-- and no placeholder files in the user's project. Parent rules stay in parent dirs.
function M.shadow(root, candidates)
  local temp = vim.fn.tempname()
  local mirror = temp .. '/tree'
  local seen = {}
  local function directory(dir)
    if seen[dir] then
      return
    end
    seen[dir] = true
    local target = mirror .. dir
    vim.fn.mkdir(target, 'p')
    for _, file in ipairs({ '.gitignore', '.ignore', '.rgignore' }) do
      copy(dir .. '/' .. file, target .. '/' .. file)
    end
    local git = dir .. '/.git'
    local stat = uv.fs_stat(git)
    if stat then
      vim.fn.mkdir(target .. '/.git/info', 'p')
      if stat.type == 'file' then
        local f = io.open(git, 'r')
        local location = f and f:read('*a'):match('gitdir:%s*([^\r\n]+)')
        if f then
          f:close()
        end
        if location then
          git = location:sub(1, 1) == '/' and location or dir .. '/' .. location
        end
      end
      copy(git .. '/info/exclude', target .. '/.git/info/exclude')
      copy(git .. '/config', target .. '/.git/config')
    end
    local parent = vim.fs.dirname(dir)
    if parent and parent ~= dir then
      directory(parent)
    end
  end
  directory(root)
  for _, candidate in ipairs(candidates) do
    directory(vim.fs.dirname(candidate.path))
    local target = mirror .. candidate.path
    local fd = assert(io.open(target, 'wb'))
    fd:close()
  end
  return { cwd = mirror .. root, temp = temp }
end

function M.cleanup(shadow)
  if shadow then
    vim.fn.delete(shadow.temp, 'rf')
  end
end
return M
