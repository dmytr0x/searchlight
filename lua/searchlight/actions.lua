-- Panel interactions; session creation and global configuration stay in the facade.
local sessions = require('searchlight.sessions')
local view = require('searchlight.view')
local replace = require('searchlight.replace')
local results = require('searchlight.results')
local controller = require('searchlight.controller')
local modes = require('searchlight.modes')
local M = {}

function M.navigate(s, delta, wrap)
  s = sessions.own(s)
  controller.synchronize(s, 'display')
  local _, index = results.selected(s)
  if wrap ~= nil and vim.api.nvim_get_current_buf() == s.buf then
    -- Async results may have arrived since the last scheduled redraw.
    if not view.layout_fresh(s) then
      view.render(s)
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    index = delta > 0 and 0 or #s.results + 1
    for i, result in ipairs(s.results) do
      local position = s.result_positions[result.id]
        or { row = s.file_headers[result.path], col = math.huge }
      local before = position.row < cursor[1]
        or position.row == cursor[1] and position.col <= cursor[2]
      local after = position.row > cursor[1]
        or position.row == cursor[1] and position.col >= cursor[2]
      if delta > 0 and before then
        index = i
      elseif delta < 0 and after then
        index = i
        break
      end
    end
  end
  local target = index and math.max(1, math.min(#s.results, index + delta))
    or (delta < 0 and #s.results or 1)
  if wrap and index and #s.results > 0 then
    target = (index - 1 + delta) % #s.results + 1
  end
  s.navigation_end = false
  if s.results[target] then
    s.collapsed_paths[s.results[target].path] = nil
  end
  -- An expanded file has no rendered positions yet, so select falls back to render.
  if not view.select(s, s.results[target] and s.results[target].id) then
    view.render(s)
  end
  local position = s.result_positions[s.selected]
  if position and vim.api.nvim_get_current_buf() == s.buf then
    vim.api.nvim_win_set_cursor(0, { position.row, position.col })
    view.update_cursor_marker(s)
  end
  return results.selected(s)
end

local function source_pattern(s)
  local query = s.fields.query
  if query == '' then
    return
  end
  -- Rebuild from the controls on every jump, regardless of result status or file.
  -- Native search follows source edits and never needs per-occurrence coordinates.
  local case = s.options.case and '\\C' or '\\c'
  if s.options.regex then
    return case .. '\\v' .. (s.options.word and '<(' .. query .. ')>' or query)
  end
  query = query:gsub('\\', '\\\\')
  return case .. (s.options.word and '\\<\\V' .. query .. '\\>' or '\\V' .. query)
end

local function source_search(pattern)
  if not pattern then
    return
  end
  vim.fn.setreg('/', pattern)
  vim.o.hlsearch = true
  vim.v.hlsearch = 1
end

function M.open(s)
  s = sessions.own(s)
  controller.synchronize(s, 'display')
  local result = results.selected(s)
  if not result then
    return
  end
  local pattern = source_pattern(s)
  sessions.activate(s)
  local options = sessions.editor_options(vim.api.nvim_get_current_win())
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  sessions.restore_editor_options(win, options)
  local path = result.path
  if result.buf and vim.api.nvim_buf_is_valid(result.buf) then
    path = vim.api.nvim_buf_get_name(result.buf)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  if s.config.close_on_open then
    -- Close only after the source opens, before centering in the final layout.
    controller.close(s)
  end
  local line = math.min(result.line, vim.api.nvim_buf_line_count(buf))
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
  vim.api.nvim_win_set_cursor(win, { line, math.min(result.start, #text) })
  vim.cmd('normal! zvzz')
  source_search(pattern)
  return buf, win
end

function M.action(s, name, arg)
  s = sessions.own(s)
  if
    not modes.can_replace(s)
    and (
      name == 'replace_next'
      or name == 'replace_all'
      or name == 'field' and arg == 'replacement'
      or name == 'section' and arg == 'replace'
    )
  then
    return nil, modes.replacement_reason
  end
  controller.synchronize(s, 'display')
  local cursor = vim.api.nvim_get_current_buf() == s.buf and vim.api.nvim_win_get_cursor(0)
  local path = cursor and (s.file_rows or {})[cursor[1]]
  if name == 'enter' then
    if view.field_at_cursor(s) or cursor and cursor[1] == 1 then
      return controller.refresh(s)
    end
    name = 'open'
  end
  if name == 'open' and path then
    s.collapsed_paths[path] = not s.collapsed_paths[path] or nil
    view.render(s)
    return
  end
  -- Cursor selection applies to actions on a result; navigation chooses its own target.
  if name == 'open' or name == 'exclude' or name == 'replace_next' then
    if vim.api.nvim_get_current_buf() == s.buf then
      s.selected = results.at_cursor(s, cursor) or s.selected
    end
  end
  if name == 'toggle' then
    controller.set(s, { [arg] = not s.options[arg] })
  elseif name == 'section' then
    s.sections[arg] = not s.sections[arg]
    view.render(s)
    if arg == 'help' and s.sections.help and vim.api.nvim_get_current_buf() == s.buf then
      vim.api.nvim_win_set_cursor(0, { s.help_row, 0 })
      vim.cmd('normal! zt')
    end
  elseif name == 'field' then
    view.focus_field(s, arg)
  elseif name == 'next_field' then
    local row, selected = vim.api.nvim_win_get_cursor(0)[1], 'query'
    local fields = modes.get(s.mode).fields
    for i, field in ipairs(fields) do
      local region = s.regions[field]
      if region and row > region.start and row <= region.stop then
        selected = fields[i % #fields + 1]
        break
      end
    end
    view.focus_field(s, selected)
  elseif name == 'navigate' then
    return M.navigate(s, arg)
  elseif name == 'search_next' then
    return M.navigate(s, arg, vim.o.wrapscan)
  elseif name == 'open' then
    return M.open(s)
  elseif name == 'exclude' then
    local result = results.selected(s)
    if result then
      result.enabled = not result.enabled
      s.exclusions[result.id] = not result.enabled or nil
      view.render(s)
    end
  elseif name == 'refresh' then
    controller.refresh(s)
  elseif name == 'replace_next' then
    return replace.apply(s, false)
  elseif name == 'replace_all' then
    return replace.apply(s, true)
  elseif name == 'hide' then
    for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
      if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
        vim.api.nvim_win_close(win, false)
      else
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
    end
  elseif name == 'close' then
    controller.close(s)
  elseif name == 'root' then
    vim.ui.input({ prompt = 'Search root: ', default = s.root, completion = 'dir' }, function(value)
      if value and sessions.owns(s) then
        controller.set(s, { root = value })
      end
    end)
  elseif name == 'limit' then
    vim.ui.input(
      { prompt = 'Maximum matches (then refresh): ', default = tostring(s.config.max_results) },
      function(value)
        local limit = tonumber(value)
        if limit and limit > 0 and limit == math.floor(limit) and sessions.owns(s) then
          s.config.max_results = limit
          controller.refresh(s)
        end
      end
    )
  else
    error('Unknown Searchlight action: ' .. name)
  end
end

return M
