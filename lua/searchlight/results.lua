-- File groups own the display; occurrences keep their individual identities and actions.
local M = {}

local function line_state(s, matches)
  if not matches then
    return '    ', false
  end
  local selected = false
  for _, result in ipairs(matches) do
    selected = selected or result.id == s.selected
  end
  return '○   ', selected
end

-- Canonical order is shared by asynchronous completion and display.
function M.compare_ranges(a, b)
  if a.line ~= b.line then
    return a.line < b.line
  end
  if a.start ~= b.start then
    return a.start < b.start
  end
  return a.finish < b.finish
end

function M.compare(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  return M.compare_ranges(a, b)
end

function M.selected(s)
  for index, result in ipairs(s.results) do
    if result.id == s.selected then
      return result, index
    end
  end
end

function M.order(s)
  table.sort(s.results, M.compare)
  -- Source jobs finish out of order; choose the first sorted hit, not the first arrival.
  if s.selection_after then
    local wanted = s.selection_after
    s.selected = nil
    for _, result in ipairs(s.results) do
      if
        result.path == wanted.path
        and result.line == wanted.line
        and result.start == wanted.start
        and result.match == wanted.match
      then
        s.selected = result.id
        break
      end
    end
    s.selection_after = nil
    if not s.selected then
      s.navigation_end = true
    end
  elseif s.selected then
    local found = false
    for _, r in ipairs(s.results) do
      if r.id == s.selected then
        found = true
      end
    end
    if not found then
      s.selected = s.results[1] and s.results[1].id
    end
  elseif not s.navigation_end then
    s.selected = s.results[1] and s.results[1].id
  end
end

local function code_rows(matches, first_match, last_match, emit, checkpoint)
  local snapshot, previous_line = matches[first_match].snapshot, nil
  local final = 0
  for i = first_match, last_match do
    local result = matches[i]
    final = math.max(final, math.min(#snapshot.lines, result.line + result.context_size))
    if checkpoint then
      checkpoint()
    end
  end
  local width = #tostring(final)
  local index, match_index = first_match, first_match
  while index <= last_match do
    local first = math.max(1, matches[index].line - matches[index].context_size)
    local last = math.min(#snapshot.lines, matches[index].line + matches[index].context_size)
    index = index + 1
    while index <= last_match and matches[index].line - matches[index].context_size <= last + 1 do
      last =
        math.min(#snapshot.lines, math.max(last, matches[index].line + matches[index].context_size))
      index = index + 1
      if checkpoint then
        checkpoint()
      end
    end
    for line = first, last do
      if checkpoint then
        checkpoint()
      end
      local line_matches
      while match_index <= last_match and matches[match_index].line == line do
        line_matches = line_matches or {}
        line_matches[#line_matches + 1] = matches[match_index]
        match_index = match_index + 1
      end
      local text = line_matches and line_matches[1].context or snapshot.context_lines[line]
      if text then
        if previous_line and line > previous_line + 1 then
          if emit(nil) == false then
            return
          end
        end
        if emit(line, text, line_matches, width, snapshot) == false then
          return
        end
        previous_line = line
      end
    end
  end
end

-- Requested mappings only; headers, omitted lines, fields and help have no mapping.
-- Columns and lengths are bytes; Unicode markers preserve the gutter's display width.
function M.mappings(s, first, last, emit, checkpoint)
  -- Compact file ranges refer to the canonical occurrence array. Rendering and
  -- mapping walk the same blocks; no per-row geometry or text is retained.
  local layout = s.result_layout or {}
  for _, file in ipairs(layout) do
    if checkpoint then
      checkpoint()
    end
    if file.row >= last then
      break
    end
    if file.end_row > first and not s.collapsed_paths[file.path] then
      local row = file.row
      code_rows(s.results, file.first, file.last, function(line, text, line_matches, width, snapshot)
        if row >= last then
          return false
        end
        if line and row >= first then
          local state = line_state(s, line_matches)
          if emit(row, snapshot, line, 5 + #state + width, #text) == false then
            return false
          end
        end
        row = row + 1
      end, checkpoint)
    end
  end
end

function M.at_cursor(s, cursor)
  local occurrences = (s.result_occurrences or {})[cursor[1]]
  if not occurrences then
    return nil
  end
  for _, occurrence in ipairs(occurrences) do
    if
      cursor[2] >= occurrence.col
      and cursor[2] < math.max(occurrence.stop, occurrence.col + 1)
    then
      return occurrence.id
    end
  end
  -- The gutter acts on the selected occurrence on this line, otherwise its first match.
  if cursor[2] < occurrences[1].col then
    return s.result_rows[cursor[1]]
  end
  local nearest, distance
  for _, occurrence in ipairs(occurrences) do
    local gap =
      math.min(math.abs(cursor[2] - occurrence.col), math.abs(cursor[2] - occurrence.stop))
    if not distance or gap < distance then
      nearest, distance = occurrence.id, gap
    end
  end
  return nearest
end

-- Rebuild only when the occurrence array changes. Selection, colors and viewport
-- motion reuse canonical order and one compact record per file, not an index per hit.
local function geometry(s)
  local old = s.result_layout
  if old and old.results == s.results and old.count == #s.results then
    return old
  end
  table.sort(s.results, M.compare)
  local layout = { results = s.results, count = #s.results }
  for index, result in ipairs(s.results) do
    local file = layout[#layout]
    if not file or file.path ~= result.path then
      file = { path = result.path, first = index, last = index }
      layout[#layout + 1] = file
    else
      file.last = index
    end
  end
  -- Estimate array capacity and record storage; both are bounded by max_results.
  s.result_layout, s.result_layout_bytes = layout, 128 + #layout * 256
  return layout
end

function M.header(s)
  geometry(s)
  local _, index = M.selected(s)
  return string.format('[Results]  %d/%d', index or 0, #s.results)
end

function M.render(s, add, highlights)
  local stamp, mapped = 0, 0
  local function mix(value)
    stamp = (stamp * 31 + value) % 2147483647
  end
  local rows, occurrences, positions, headers, file_rows, markers = {}, {}, {}, {}, {}, {}
  local layout = geometry(s)
  for file_index, file in ipairs(layout) do
    local path = file.path
    if file_index > 1 then
      add('')
    end
    local relative = require('searchlight.scope').relative(s.root, path)
    local name = vim.fs.basename(relative)
    local directory = relative:sub(1, #relative - #name)
    local collapsed = s.collapsed_paths[path]
    local heading = (collapsed and '▸ ' or '▾ ') .. name
    local header_text = heading .. (directory ~= '' and '  ' .. directory or '')
    local header = add(header_text)
    headers[path], file_rows[header + 1] = header + 1, path
    -- Zero-based first code row (the existing file_headers index is one-based).
    file.row = header + 1
    table.insert(highlights, {
      row = header,
      start = 0,
      stop = #header_text,
      group = 'CursorLine',
      hl_eol = true,
      priority = 90,
    })
    table.insert(highlights, {
      row = header,
      start = 0,
      stop = #heading,
      group = 'Title',
    })
    if directory ~= '' then
      table.insert(highlights, {
        row = header,
        start = #heading + 2,
        stop = #heading + 2 + #directory,
        group = 'Comment',
      })
    end
    if not collapsed then
      mix(tonumber(s.results[file.first].snapshot.hash:sub(1, 8), 16))
      code_rows(s.results, file.first, file.last, function(line, text, line_matches, width)
        if not line then
          add('      ⋯')
          return
        end
        local state, selected = line_state(s, line_matches)
        local prefix = (selected and '> ' or '  ')
          .. state
          .. string.format('%' .. width .. 'd', line)
          .. ' | '
        local row = add(prefix .. text:gsub('[\r\n]', ' '))
        mix(row)
        mix(line)
        mix(#prefix)
        mix(#text)
        mapped = mapped + 1
        table.insert(highlights, {
          row = row,
          start = 0,
          stop = #prefix,
          group = 'LineNr',
        })
        if state == '○   ' then
          markers[row + 1] = 2
          table.insert(highlights, {
            row = row,
            start = 2,
            stop = 2 + #'○',
            group = 'SearchlightMarker',
            priority = 2001,
          })
        end
        if line_matches then
          rows[row + 1] = line_matches[1].id
          occurrences[row + 1] = {}
          for _, result in ipairs(line_matches) do
            local position = {
              row = row + 1,
              col = #prefix + result.start,
              stop = #prefix + result.finish,
              id = result.id,
            }
            positions[result.id] = position
            table.insert(occurrences[row + 1], position)
            if result.id == s.selected then
              rows[row + 1] = result.id
            end
            table.insert(highlights, {
              row = row,
              start = position.col,
              stop = position.stop,
              -- Stale snapshots keep their match colors and circle markers.
              group = not result.enabled and 'Comment'
                or result.id == s.selected and 'IncSearch'
                or 'Search',
            })
          end
        end
      end)
    end
  end
  for i, file in ipairs(layout) do
    file.end_row = layout[i + 1] and layout[i + 1].row or math.huge
  end
  s.result_rows, s.result_occurrences, s.result_positions = rows, occurrences, positions
  s.file_headers, s.file_rows = headers, file_rows
  s.result_markers = markers
  local key = stamp .. ':' .. mapped
  if s.layout_key ~= key or s.layout_invalid then
    s.layout_revision = (s.layout_revision or 0) + 1
    s.layout_key, s.layout_invalid = key, nil
    s.layout_changed = true
  end
  return rows
end

return M
