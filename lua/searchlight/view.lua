local sessions = require('searchlight.sessions')
local results = require('searchlight.results')
local replace = require('searchlight.replace')
local controller = require('searchlight.controller')
local syntax = require('searchlight.highlight')
local M = { namespace = vim.api.nvim_create_namespace('searchlight') }
local panel_colors = vim.api.nvim_create_namespace('searchlight_panel_colors')
local cursor_marker = vim.api.nvim_create_namespace('searchlight_cursor_marker')
local decorations = vim.api.nvim_create_namespace('searchlight_results')
local global_colors = {
  SearchlightMarker = 'DiagnosticOk',
  SearchlightControl = 'Title',
  SearchlightPath = 'Directory',
}
-- `default` keeps user definitions; `:colorscheme` clears global groups, so rerun on ColorScheme.
local function register_global_colors()
  for group, target in pairs(global_colors) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end
local function register_panel_colors()
  -- Native hlsearch belongs to source navigation; panel matches come from result ranges.
  for _, group in ipairs({ 'Search', 'CurSearch', 'IncSearch' }) do
    vim.api.nvim_set_hl(panel_colors, group, {})
  end
  vim.api.nvim_set_hl(panel_colors, 'SearchlightMatch', { link_global = 'Search' })
  vim.api.nvim_set_hl(panel_colors, 'SearchlightSelected', { link_global = 'IncSearch' })
  for group in pairs(global_colors) do
    vim.api.nvim_set_hl(panel_colors, group, { link_global = group })
  end
  register_global_colors()
  local window_colors = {}
  local color_group = vim.api.nvim_create_augroup('SearchlightPanelColors', { clear = true })
  vim.api.nvim_create_autocmd(
    'ColorScheme',
    { group = color_group, callback = register_global_colors }
  )
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'WinEnter' }, {
    group = color_group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local colors = vim.api.nvim_get_hl_ns({ winid = win })
      if sessions.owns(sessions.by_buf[vim.api.nvim_get_current_buf()]) then
        if window_colors[win] == nil then
          -- A split may inherit the panel namespace before its first enter event.
          window_colors[win] = colors == panel_colors and -1 or colors
        end
        vim.api.nvim_win_set_hl_ns(win, panel_colors)
      elseif window_colors[win] ~= nil then
        if colors == panel_colors then
          vim.api.nvim_win_set_hl_ns(win, window_colors[win])
        end
        window_colors[win] = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = color_group,
    callback = function(event)
      window_colors[tonumber(event.match)] = nil
    end,
  })
end
register_panel_colors()

local reserved = {
  ['[Search]'] = true,
  ['[Replace]'] = true,
  ['[Include]'] = true,
  ['[Exclude]'] = true,
}
local input = require('searchlight.input')
local controls = input.controls

local function mark(s, id)
  return vim.api.nvim_buf_get_extmark_by_id(s.buf, M.namespace, id, {})
end

local function read_heading(s)
  local heading = s.heading and mark(s, s.heading) or {}
  if #heading > 0 then
    return vim.api.nvim_buf_get_lines(s.buf, heading[1], heading[1] + 1, false)[1]
  end
  return s.search_heading or input.heading(s.options)
end

function M.read_options(s)
  return input.parse_heading(read_heading(s), s.options)
end

function M.set_options(s, changes)
  s.search_heading = input.patch_heading(s.search_heading or input.heading(s.options), changes)
end

local function region_bounds(s, region)
  local first, last = mark(s, region.first), mark(s, region.last)
  if #first > 0 and #last > 0 then
    return first[1], math.max(first[1], last[1])
  end
end

local function input_region_at(s, row)
  for name, region in pairs(s.regions) do
    local first, last = region_bounds(s, region)
    if first and row > first and row <= last then
      return name, first
    end
  end
end

local function read_region(s, region)
  local first, last = region_bounds(s, region)
  if not first then
    return
  end
  local body = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(s.buf, first, last, false)) do
    if not reserved[line] and not input.is_heading(line) then
      table.insert(body, line)
    end
  end
  return body
end

function M.read(s)
  if s.rendering or s.fields_dirty or not sessions.owns(s) then
    return nil
  end
  local heading = read_heading(s)
  local options = input.parse_heading(heading, s.options)
  local changes = {}
  for name, region in pairs(s.regions) do
    local body = read_region(s, region)
    if body then
      if name == 'include' or name == 'exclude' then
        -- Preserve editable lines verbatim; rg parses and trims declarations separately.
        -- An empty list already renders as one blank editable line.
        local empty_placeholder = #s.fields[name] == 0 and #body == 1 and body[1] == ''
        if not empty_placeholder and not vim.deep_equal(body, s.fields[name]) then
          changes[name] = body
        end
      else
        local value = table.concat(body, '\n')
        if value ~= s.fields[name] then
          changes[name] = value
        end
      end
    end
  end
  return {
    fields = changes,
    options = options,
    heading = heading,
    changed = next(changes) ~= nil or not vim.deep_equal(options, s.options),
  }
end

local function cursor_state(s, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local name, first = input_region_at(s, cursor[1])
  if name then
    return { name = name, offset = cursor[1] - first - 1, col = cursor[2] }
  end
  local path = (s.file_rows or {})[cursor[1]]
  if path then
    return { file_path = path, col = cursor[2] }
  end
  local id = results.at_cursor(s, cursor)
  local saved = (s.result_cursors or {})[win]
  if id then
    return { result_id = id, col = cursor[2], offset = cursor[2] - s.result_positions[id].col }
  end
  if saved and vim.deep_equal(saved.cursor, cursor) then
    return { result_id = saved.id, col = cursor[2], offset = saved.offset }
  end
  return { cursor = cursor }
end

function M.update_cursor_marker(s)
  vim.api.nvim_buf_clear_namespace(s.buf, cursor_marker, 0, -1)
  if vim.api.nvim_get_current_buf() ~= s.buf then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = (s.result_markers or {})[row]
  if col then
    vim.api.nvim_buf_set_extmark(s.buf, cursor_marker, row - 1, col, {
      virt_text = { { '●', 'SearchlightMarker' } },
      virt_text_pos = 'overlay',
      priority = 2002,
    })
  end
end

local function capture_windows(s)
  local cursors, views = {}, {}
  for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
    cursors[win] = cursor_state(s, win)
    vim.api.nvim_win_call(win, function()
      views[win] = vim.fn.winsaveview()
    end)
  end
  return cursors, views
end

local function add_help(s, add)
  local function key(label)
    if label == '?' then
      return label
    end
    return (vim.g.maplocalleader or '\\') .. label
  end
  add('')
  s.help_row = add(
    '[Help] Edit modifier brackets: non-space enables; empty or spaces disable. Tab cycles fields.'
  ) + 1
  add(
    'Typing never searches. Press Enter in an input line or the controls to refresh search/previews.'
  )
  add('[Search controls]')
  for _, control in ipairs(controls) do
    add(control.label .. '  ' .. key(control.key) .. '  ' .. control.meaning)
  end
  add(
    '↕  Edit brackets: context lines above and below each match (default 2; 0 hides context).'
  )
  add('Use a nonnegative whole number; incomplete or invalid context keeps the last valid size.')
  add(
    s.options.ignored and 'Policy: include hidden + config/normal ignored; exclude .git'
      or 'Policy: include hidden; respect config/ignores; exclude .git'
  )
  add('[Fields]')
  add(key('/') .. ' Search | ' .. key('r') .. ' Replace')
  add(key('I') .. ' Include | ' .. key('E') .. ' Exclude')
  add('Positive globs separated by commas or lines; includes form a union, exclusions win.')
  add(key('f') .. ' Hide/show filters | ' .. key('v') .. ' Hide/show Replace')
  add('[Results and replacement] Positions use byte columns.')
  add('[ / ] Previous / next | <Enter> Open | <Space> Enable/exclude')
  add('n / N Next / previous match; counts supported, wrapping follows wrapscan.')
  add('Opening a result highlights its file matches for native n / N; :nohlsearch clears them.')
  add('Literal searches follow edits; regex/word/capped ranges need refresh and reopen.')
  add('One header per file; <Enter> on a header collapses/expands its matches.')
  add('Each source line appears once. Move onto a highlight to act on that occurrence.')
  add(
    '○ Match line | ● Cursor line; excluded hits are dimmed; refresh stale results before replacing.'
  )
  add(key('n') .. ' Replace next | ' .. key('A') .. ' Replace all')
  add('Empty replacement deletes. Edit input fields and Search modifier brackets.')
  add(
    'Regex captures: $1, ${name}; $$ is a literal dollar. Edits stay unsaved: review, :write/:wall, u/C-r in source.'
  )
  add(
    'Only open files uses current listed normal buffers. Roots are captured; :cd does not retarget a session.'
  )
  add(
    'Replace all needs complete uncapped results. '
      .. key('L')
      .. ' raises the limit; '
      .. key('R')
      .. ' refreshes. Undo is per file.'
  )
  add(
    'Use :SearchlightNew [root], :SearchlightFocus [id], :SearchlightClose. Sections keep hidden values.'
  )
  add('[Session]')
  add(key('d') .. ' Root | ' .. key('L') .. ' Limit | ' .. key('R') .. ' Refresh')
  add(key('R') .. ' in normal mode reruns the current query, options and filters after files change.')
  add(key('q') .. ' Hide | ' .. key('D') .. ' Close | ? Hide/show help')
end

local function build_layout(s)
  local lines, regions, highlights = {}, {}, {}
  local function add(line)
    table.insert(lines, line)
    return #lines - 1
  end
  local function field(name, label, value)
    local row = add(label)
    table.insert(highlights, {
      row = row,
      start = 0,
      stop = #(name == 'query' and '[Search]' or label),
      group = 'Title',
    })
    local first = #lines
    local body = type(value) == 'table' and value or vim.split(value, '\n', { plain = true })
    if #body == 0 then
      body = { '' }
    end
    for _, line in ipairs(body) do
      add(line)
    end
    regions[name] = { start = first, stop = #lines }
  end
  s.search_heading = s.search_heading or input.heading(s.options)
  field('query', s.search_heading, s.fields.query)
  for _, control in ipairs(controls) do
    local first, last = s.search_heading:find(vim.pesc(control.label) .. '%[[^%[%]]*%]')
    if first then
      table.insert(highlights, {
        row = 0,
        start = first - 1,
        stop = last,
        group = 'SearchlightControl',
      })
    end
  end
  local context_first, context_last = s.search_heading:find('↕%[[^%[%]]*%]')
  if context_first then
    table.insert(highlights, {
      row = 0,
      start = context_first - 1,
      stop = context_last,
      group = 'SearchlightControl',
    })
  end
  if s.sections.replace then
    field('replacement', '[Replace]', s.fields.replacement)
  end
  if s.sections.filters then
    field('include', '[Include]', s.fields.include)
    field('exclude', '[Exclude]', s.fields.exclude)
  end
  if not s.sections.replace and s.fields.replacement ~= '' then
    add('[Replace hidden; active value: ' .. vim.inspect(s.fields.replacement) .. ']')
  end
  if not s.sections.filters and (#s.fields.include > 0 or #s.fields.exclude > 0) then
    add(
      '[Filters hidden; Include: '
        .. table.concat(s.fields.include, ', ')
        .. '; Exclude: '
        .. table.concat(s.fields.exclude, ', ')
        .. ']'
    )
  end
  if s.message and s.message ~= '' then
    add(s.message:gsub('[\r\n]', ' '))
  end
  if s.report then
    add('Last apply: ' .. replace.summary(s.report))
  end
  add('')
  s.results_header_row = add(results.header(s))
  results.render(s, add)
  if s.sections.help then
    add_help(s, add)
  end
  return { lines = lines, regions = regions, highlights = highlights }
end

local function patch_buffer(s, lines)
  -- Leave unchanged input and result text in place, joining repair to the user's edit.
  local old = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local prefix, suffix = 0, 0
  while prefix < math.min(#old, #lines) and old[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end
  while suffix < math.min(#old, #lines) - prefix and old[#old - suffix] == lines[#lines - suffix] do
    suffix = suffix + 1
  end
  if prefix ~= #old or #old ~= #lines then
    local replacement = {}
    for i = prefix + 1, #lines - suffix do
      table.insert(replacement, lines[i])
    end
    vim.api.nvim_buf_call(s.buf, function()
      pcall(vim.cmd, 'undojoin')
      vim.api.nvim_buf_set_lines(s.buf, prefix, #old - suffix, false, replacement)
    end)
  end
end

local function decorate(s, layout)
  local regions, highlights = layout.regions, layout.highlights
  vim.api.nvim_buf_clear_namespace(s.buf, M.namespace, 0, -1)
  s.heading = vim.api.nvim_buf_set_extmark(s.buf, M.namespace, 0, 0, { right_gravity = false })
  s.regions = {}
  for name, region in pairs(regions) do
    s.regions[name] = {
      first = vim.api.nvim_buf_set_extmark(
        s.buf,
        M.namespace,
        region.start,
        0,
        { right_gravity = false }
      ),
      last = vim.api.nvim_buf_set_extmark(
        s.buf,
        M.namespace,
        region.stop,
        0,
        { right_gravity = true }
      ),
      start = region.start,
      stop = region.stop,
    }
  end
  for _, hl in ipairs(highlights) do
    local group = hl.group or 'Search'
    if group == 'Search' then
      group = 'SearchlightMatch'
    elseif group == 'IncSearch' then
      group = 'SearchlightSelected'
    end
    local opts = {
      end_col = hl.stop,
      hl_group = group,
      hl_eol = hl.hl_eol,
      priority = hl.priority or 2000,
      strict = false,
    }
    if hl.stop == hl.start and not hl.hl_eol then
      opts.virt_text = { { '│', group } }
      opts.virt_text_pos = 'overlay'
    end
    vim.api.nvim_buf_set_extmark(s.buf, M.namespace, hl.row, hl.start, opts)
  end
end

local function restore_windows(s, layout, cursors, views)
  local lines, regions = layout.lines, layout.regions
  for win, state in pairs(cursors) do
    local cursor = state.cursor
    if state.name and regions[state.name] then
      local region = regions[state.name]
      cursor = { math.min(region.stop, region.start + state.offset + 1), state.col }
    end
    if state.file_path and s.file_headers[state.file_path] then
      cursor = { s.file_headers[state.file_path], state.col }
    end
    s.result_cursors = s.result_cursors or {}
    if state.result_id then
      local position = s.result_positions[state.result_id]
      if position then
        cursor = { position.row, math.max(0, position.col + (state.offset or 0)) }
      end
      if not cursor and s.status ~= 'waiting' and s.status ~= 'searching' then
        position = s.result_positions[s.selected]
        cursor = position and { position.row, position.col }
      end
      cursor = cursor or vim.api.nvim_win_get_cursor(win)
      s.result_cursors[win] = { id = state.result_id, cursor = cursor, offset = state.offset }
    else
      s.result_cursors[win] = nil
    end
    if cursor then
      cursor[1] = math.min(#lines, math.max(1, cursor[1]))
      cursor[2] = math.min(cursor[2], #lines[cursor[1]])
      vim.api.nvim_win_set_cursor(win, cursor)
      views[win].lnum, views[win].col = cursor[1], cursor[2]
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(views[win])
      end)
      if s.result_cursors[win] then
        s.result_cursors[win].cursor = vim.api.nvim_win_get_cursor(win)
      end
    end
  end
end

-- Calls emit(row, col, opts) for each result-area decoration on a zero-based row.
-- Work is bounded by the matches on that row; drawing runs on every redraw.
local function row_decorations(s, row, emit)
  local header = s.file_header_spans[row + 1]
  if header then
    emit(row, 0, { end_col = header[1], hl_group = 'CursorLine', hl_eol = true, priority = 90 })
    emit(row, 0, { end_col = header[2], hl_group = 'Title', priority = 2000 })
    if header[3] > 0 then
      emit(row, header[2] + 2, {
        end_col = header[2] + 2 + header[3],
        hl_group = 'SearchlightPath',
        priority = 2000,
      })
    end
    return
  end
  local gutter = s.result_gutters[row + 1]
  if not gutter then
    return
  end
  emit(row, 0, { end_col = gutter, hl_group = 'LineNr', priority = 2000 })
  local marker = s.result_markers[row + 1]
  if marker then
    emit(row, marker, { end_col = marker + #'○', hl_group = 'SearchlightMarker', priority = 2001 })
  end
  for _, occurrence in ipairs(s.result_occurrences[row + 1] or {}) do
    local group = occurrence.disabled and 'Comment'
      or occurrence.id == s.selected and 'SearchlightSelected'
      or 'SearchlightMatch'
    local opts = { end_col = occurrence.stop, hl_group = group, priority = 2000 }
    if occurrence.stop == occurrence.col then
      opts.virt_text = { { '│', group } }
      opts.virt_text_pos = 'overlay'
    end
    emit(row, occurrence.col, opts)
  end
end

local function drawable(s)
  return sessions.owns(s) and not s.layout_invalid and s.result_gutters ~= nil or false
end

vim.api.nvim_set_decoration_provider(decorations, {
  on_win = function(_, _, buf)
    return drawable(sessions.by_buf[buf])
  end,
  on_line = function(_, _, buf, row)
    row_decorations(sessions.by_buf[buf], row, function(line, col, opts)
      opts.ephemeral, opts.strict = true, false
      vim.api.nvim_buf_set_extmark(buf, decorations, line, col, opts)
    end)
  end,
})

-- Decorations drawn on result rows, shaped like nvim_buf_get_extmarks({ details = true }).
function M.decorations(s)
  local marks = {}
  if drawable(s) then
    for row = 0, vim.api.nvim_buf_line_count(s.buf) - 1 do
      row_decorations(s, row, function(line, col, opts)
        table.insert(marks, { 0, line, col, opts })
      end)
    end
  end
  return marks
end

-- True when the buffer still shows the last rendered result rows.
function M.layout_fresh(s)
  local rendered = s.rendered
  return not s.layout_invalid
    and not s.fields_dirty
    and rendered ~= nil
    and rendered.results == s.results
    and rendered.count == #s.results
    and rendered.tick == vim.api.nvim_buf_get_changedtick(s.buf)
end

function M.render(s)
  if not sessions.owns(s) or s.rendering then
    return
  end
  local cursors, views = capture_windows(s)
  local layout = build_layout(s)
  s.rendering = true
  patch_buffer(s, layout.lines)
  decorate(s, layout)
  restore_windows(s, layout, cursors, views)
  vim.bo[s.buf].modified = false
  s.rendered = {
    results = s.results,
    count = #s.results,
    tick = vim.api.nvim_buf_get_changedtick(s.buf),
  }
  s.rendering = false
  s.fields_dirty = false
  M.update_cursor_marker(s)
  syntax.layout_changed(s)
end

-- Selects result id. Without a layout change, rewrites only the old and new selected
-- rows and the results header. Returns false when the caller must render instead.
function M.select(s, id)
  local old = s.selected
  s.selected = id
  if not sessions.owns(s) or s.rendering or not M.layout_fresh(s) then
    return false
  end
  local target = id and s.result_positions[id]
  if not target then
    return false
  end
  -- A previous selection inside a collapsed file has no row to clear.
  local previous = old and s.result_positions[old]
  local rows = { [target.row] = true }
  if previous then
    rows[previous.row] = true
  end
  s.rendering = true
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
    cursors[win] = vim.api.nvim_win_get_cursor(win)
  end
  vim.api.nvim_buf_call(s.buf, function()
    for row in pairs(rows) do
      local line = vim.api.nvim_buf_get_lines(s.buf, row - 1, row, false)[1]
      local selected = row == target.row
      s.result_rows[row] = selected and id or s.result_occurrences[row][1].id
      pcall(vim.cmd, 'undojoin')
      vim.api.nvim_buf_set_lines(s.buf, row - 1, row, false, {
        (selected and '> ' or '  ') .. line:sub(3),
      })
    end
    local header = s.results_header_row
    pcall(vim.cmd, 'undojoin')
    vim.api.nvim_buf_set_lines(s.buf, header, header + 1, false, { results.header(s) })
  end)
  for win, cursor in pairs(cursors) do
    vim.api.nvim_win_set_cursor(win, cursor)
  end
  vim.bo[s.buf].modified = false
  s.rendered.tick = vim.api.nvim_buf_get_changedtick(s.buf)
  s.rendering = false
  -- Replacing a line moves its extmarks, including the cursor marker.
  M.update_cursor_marker(s)
  return true
end

function M.request_render(s)
  s.render_generation = s.generation
  if s.render_pending then
    return
  end
  s.render_pending = true
  vim.schedule(function()
    s.render_pending = false
    if sessions.owns(s) and s.generation == s.render_generation then
      controller.synchronize(s, 'native')
      M.render(s)
    end
  end)
end

function M.focus_field(s, name)
  controller.synchronize(s, 'display')
  if name == 'replacement' then
    s.sections.replace = true
  end
  if name == 'include' or name == 'exclude' then
    s.sections.filters = true
  end
  M.render(s)
  sessions.focus(s)
  local region = s.regions[name]
  if region then
    vim.api.nvim_win_set_cursor(0, { region.start + 1, 0 })
  end
end

function M.field_at_cursor(s)
  if vim.api.nvim_get_current_buf() ~= s.buf then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local name = input_region_at(s, row)
  return name
end

local function attach_edits(s)
  vim.api.nvim_buf_attach(s.buf, false, {
    on_lines = function(_, buf)
      local owner = sessions.by_buf[buf]
      if owner and not owner.rendering and sessions.owns(owner) then
        -- Drop syntax mappings before any redraw can use manually shifted result rows.
        owner.layout_invalid = true
        syntax.invalidate(owner)
        -- Capture input under textlock; synchronize and repair once on the main loop.
        controller.synchronize(owner, 'capture')
        M.request_render(owner)
      end
    end,
  })
end

local function register_events(s)
  local group = vim.api.nvim_create_augroup('SearchlightPanel' .. s.id, { clear = true })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = s.buf,
    callback = function()
      if sessions.owns(s) then
        sessions.last = s.id
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'InsertLeave' }, {
    group = group,
    buffer = s.buf,
    callback = function()
      -- An unchanged tick means the last change was a render or selection patch.
      if not s.rendering and not M.layout_fresh(s) then
        controller.synchronize(s, 'native')
        M.request_render(s)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = s.buf,
    callback = function()
      if not s.rendering and sessions.owns(s) then
        M.update_cursor_marker(s)
        local id = results.at_cursor(s, vim.api.nvim_win_get_cursor(0))
        if id and id ~= s.selected and not M.select(s, id) then
          M.request_render(s)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    buffer = s.buf,
    callback = function()
      sessions.dispose(s)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function register_mappings(s)
  local function action(name, arg)
    return function()
      if sessions.owns(s) then
        controller.action(s, name, arg)
      end
    end
  end
  local keys = {
    f = { 'section', 'filters' },
    v = { 'section', 'replace' },
    ['?'] = { 'section', 'help' },
    [']'] = { 'navigate', 1 },
    ['['] = { 'navigate', -1 },
    ['<CR>'] = { 'enter' },
    ['<Space>'] = { 'exclude' },
    n = { 'replace_next' },
    A = { 'replace_all' },
    R = { 'refresh' },
    d = { 'root' },
    L = { 'limit' },
    q = { 'hide' },
    D = { 'close' },
    ['/'] = { 'field', 'query' },
    r = { 'field', 'replacement' },
    I = { 'field', 'include' },
    E = { 'field', 'exclude' },
    ['<Tab>'] = { 'next_field' },
  }
  for _, control in ipairs(controls) do
    keys[control.key] = { 'toggle', control.option }
  end
  for key, command in pairs(keys) do
    local direct = key:sub(1, 1) == '<' or key == '[' or key == ']' or key == '?'
    local mapping = direct and key or '<localleader>' .. key
    vim.keymap.set(
      'n',
      mapping,
      action(command[1], command[2]),
      { buffer = s.buf, desc = 'Searchlight: ' .. command[1] }
    )
  end
  for key, direction in pairs({ n = 1, N = -1 }) do
    vim.keymap.set('n', key, function()
      if sessions.owns(s) then
        controller.action(s, 'search_next', direction * vim.v.count1)
      end
    end, {
      buffer = s.buf,
      desc = 'Searchlight: ' .. (direction > 0 and 'next' or 'previous') .. ' match',
    })
  end
  vim.keymap.set(
    'i',
    '<Tab>',
    action('next_field'),
    { buffer = s.buf, desc = 'Searchlight: next field' }
  )
  vim.keymap.set('i', '<CR>', function()
    if M.field_at_cursor(s) or vim.api.nvim_win_get_cursor(0)[1] == 1 then
      return '<Cmd>lua require("searchlight").action(' .. s.id .. ', "enter")<CR>'
    end
    return '<CR>'
  end, { buffer = s.buf, expr = true, desc = 'Searchlight: submit input' })
end

function M.attach(s)
  syntax.attach(s)
  attach_edits(s)
  register_events(s)
  register_mappings(s)
end
return M
