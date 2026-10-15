local H = { cases = {} }
function H.test(name, requirements, run)
  table.insert(H.cases, { name = name, requirements = requirements, run = run })
end
function H.eq(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    (message or 'values differ')
      .. '\nexpected: '
      .. vim.inspect(expected)
      .. '\nactual: '
      .. vim.inspect(actual)
  )
end
function H.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local fd = assert(io.open(path, 'wb'))
  fd:write(text)
  fd:close()
end
function H.read(path)
  local fd = assert(io.open(path, 'rb'))
  local text = fd:read('*a')
  fd:close()
  return text
end
function H.fixture()
  local root = require('searchlight.scope').path(vim.fn.tempname())
  vim.fn.mkdir(root .. '/a/.git/info', 'p')
  vim.fn.mkdir(root .. '/b/.git/info', 'p')
  H.write(
    root .. '/rgconfig',
    '--max-columns=100\n--max-columns-preview\n--glob=!.git/*\n--glob=!.venv/*\n--no-heading\n'
  )
  vim.env.RIPGREP_CONFIG_PATH = root .. '/rgconfig'
  H.root = root
  return root .. '/a', root .. '/b'
end
function H.buffer(path, lines, options)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  for key, value in pairs(options or {}) do
    vim.bo[buf][key] = value
  end
  require('searchlight').setup()
  return buf
end
function H.wait(s, status)
  local ok = vim.wait(8000, function()
    return not next(s.pending_jobs)
      and not s.render_pending
      and (
        s.status == 'complete'
        or s.status == 'error'
        or s.status == 'truncated'
        or s.status == 'stale'
      )
  end, 5)
  assert(ok, 'search timed out: ' .. s.status .. ' ' .. tostring(s.message))
  if status then
    H.eq(s.status, status, s.message)
  end
  return s
end
local function submit(s, changes)
  local p = require('searchlight')
  p.set(s, changes)
  p.refresh(s)
  return H.wait(s)
end
function H.search(root, changes)
  return submit(require('searchlight').search(root), changes or { query = 'abc' })
end
function H.replace(root, changes)
  return submit(
    require('searchlight').replace(root),
    changes or { query = 'abc', replacement = 'X' }
  )
end
function H.update(s, changes, expected)
  require('searchlight').set(s, changes)
  require('searchlight').refresh(s)
  H.wait(s, expected or 'complete')
  return s
end
function H.lines(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == path then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
    end
  end
  error('No source buffer for ' .. path)
end
-- Returns { [byte_col] = { [group] = true } } for 0-based buffer `row` as last drawn in `win`.
-- Groups are reported after link resolution; off-screen columns are absent. Redraw first.
function H.cell_groups(win, row)
  local buf = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
  local groups = {}
  for col = 0, #line - 1 do
    local position = vim.fn.screenpos(win, row + 1, col + 1)
    if position.row > 0 then
      groups[col] = {}
      local cell = vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)
      for _, item in ipairs(cell[3]) do
        groups[col][item.hi_name] = true
      end
    end
  end
  return groups
end
-- The group that `name` resolves to in the global namespace, as H.cell_groups reports it.
-- Undefined dotted groups such as `@string.lua` fall back to their parent, as when drawn.
function H.resolved_group(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, create = false })
  if hl.link then
    return H.resolved_group(hl.link)
  end
  local parent = next(hl) == nil and name:match('^(.+)%.[^.]+$')
  return parent and H.resolved_group(parent) or name
end
-- Code rows from the render-time source map, in panel order.
function H.code_rows(s)
  local rows = {}
  for index, line in pairs(s.row_lines or {}) do
    local snapshot = s.row_snapshots[index]
    rows[#rows + 1] = {
      row = index - 1,
      snapshot = snapshot,
      line = line,
      col = s.result_gutters[index],
      length = #snapshot.lines[line],
    }
  end
  table.sort(rows, function(a, b)
    return a.row < b.row
  end)
  return rows
end
function H.cleanup()
  local registry = require('searchlight.sessions')
  local existing = {}
  for _, s in pairs(registry.by_id) do
    table.insert(existing, s)
  end
  for _, s in ipairs(existing) do
    registry.dispose(s)
  end
  local placeholder = vim.api.nvim_create_buf(false, true)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    vim.api.nvim_win_set_buf(win, placeholder)
  end
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= placeholder then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.wait(20)
  if H.root then
    vim.fn.delete(H.root, 'rf')
    H.root = nil
  end
end
return H
