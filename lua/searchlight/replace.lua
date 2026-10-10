local sources = require('searchlight.sources')
local search = require('searchlight.search')
local rg = require('searchlight.rg')
local results = require('searchlight.results')
local M = { busy = {} }

-- Retained callable entry point; occurrence selection belongs to results.
M.selected = results.selected

function M.preview(result)
  if not result or result.stale or result.replacement == nil then
    return nil
  end
  return result.context:sub(1, result.start)
    .. result.replacement
    .. result.context:sub(result.finish + 1)
end

local function ready(s, all)
  if next(s.pending_jobs) then
    return nil, 'Replacement waits for all process handles to settle'
  end
  if not rg.probe().replacement then
    return nil, rg.probe().reason
  end
  if s.status ~= 'complete' and (all or s.status ~= 'truncated') then
    return nil, 'Replacement requires settled, current results; refresh first'
  end
  if all and s.incomplete then
    return nil, 'Replace all requires uncapped, complete scope; increase the limit and refresh'
  end
  return true
end

local function report_text(report)
  local text = string.format(
    'Applied %d; excluded %d; stale %d; unsupported %d; failed %d',
    report.applied,
    report.excluded,
    report.stale,
    report.unsupported,
    report.failed
  )
  for _, detail in ipairs(report.details) do
    text = text .. ' | ' .. detail.path .. ': ' .. detail.reason
  end
  return text
end

local function freeze_occurrence(result)
  return {
    path = result.path,
    snapshot = result.snapshot,
    line = result.line,
    start = result.start,
    finish = result.finish,
    match = result.match,
    replacement = result.replacement,
  }
end

local function freeze_targets(s, all, report)
  local selected, selected_index = results.selected(s)
  if not all and not selected then
    return nil, 'Select an enabled match first'
  end
  local operation = {
    generation = s.generation,
    groups = {},
    paths = {},
    selected = selected and freeze_occurrence(selected),
  }
  if not all then
    for i = selected_index + 1, #s.results do
      local r = s.results[i]
      if r.enabled and not r.stale then
        operation.successor = { path = r.path, line = r.line, start = r.start, match = r.match }
        break
      end
    end
  end
  for _, result in ipairs(all and s.results or { selected }) do
    if not result.enabled then
      report.excluded = report.excluded + 1
    elseif result.stale or result.generation ~= s.generation then
      report.stale = report.stale + 1
    elseif result.replacement == nil then
      report.unsupported = report.unsupported + 1
    else
      if not operation.groups[result.path] then
        operation.groups[result.path] = {}
        table.insert(operation.paths, result.path)
      end
      -- Snapshot text is immutable; copy occurrence values before any loading autocmds.
      table.insert(operation.groups[result.path], freeze_occurrence(result))
    end
  end
  table.sort(operation.paths)
  return operation
end

local function range_error(edits)
  table.sort(edits, function(a, b)
    return a.line < b.line or a.line == b.line and a.start < b.start
  end)
  for i, edit in ipairs(edits) do
    local previous = edits[i - 1]
    if
      previous
      and previous.line == edit.line
      and (previous.finish > edit.start or previous.start == edit.start)
    then
      return 'overlapping or ambiguous edits'
    end
    if edit.snapshot.lines[edit.line]:sub(edit.start + 1, edit.finish) ~= edit.match then
      return 'invalid snapshot range'
    end
  end
end

local function stale_source(report, path, edits, reason)
  report.stale = report.stale + #edits
  table.insert(report.details, { path = path, reason = reason })
end

local function prepare_sources(s, operation, report)
  local plans = {}
  for _, path in ipairs(operation.paths) do
    local edits = operation.groups[path]
    local reason = range_error(edits)
    if M.busy[path] then
      reason = 'another replacement is applying to this source'
    end
    if not reason then
      local _, validation_error = sources.validate(edits[1].snapshot, true)
      reason = validation_error
    end
    if s.generation ~= operation.generation then
      reason = 'session changed while preparing replacement'
    end
    if reason then
      stale_source(report, path, edits, reason)
      for _, r in ipairs(s.results) do
        if r.path == path then
          r.stale = true
        end
      end
    else
      table.insert(plans, { path = path, edits = edits })
    end
  end
  return plans
end

local function apply_source(plan, buf)
  local applied, previous_mutating = 0, sources.mutating
  M.busy[plan.path], sources.mutating = true, true
  local ok, err = pcall(function()
    vim.bo[buf].buflisted = true
    -- Preserve missing final newlines for sources first opened by this operation.
    if not plan.edits[1].snapshot.write_options and not plan.edits[1].snapshot.endofline then
      vim.bo[buf].fixendofline = false
    end
    vim.api.nvim_buf_call(buf, function()
      -- Finish the preceding user's undo block before the first range edit.
      vim.cmd('let &undolevels = &undolevels')
      for i = #plan.edits, 1, -1 do
        if applied > 0 then
          vim.cmd('undojoin')
        end
        local edit = plan.edits[i]
        vim.api.nvim_buf_set_text(
          buf,
          edit.line - 1,
          edit.start,
          edit.line - 1,
          edit.finish,
          vim.split(edit.replacement, '\n', { plain = true })
        )
        applied = applied + 1
      end
    end)
  end)
  -- This source owns its busy flag; suppression may already belong to an outer edit.
  M.busy[plan.path], sources.mutating = nil, previous_mutating
  require('searchlight.observe').watch(buf)
  return applied, not ok and tostring(err) or nil
end

local function apply_sources(s, operation, plans, report)
  local changed = {}
  for _, plan in ipairs(plans) do
    -- Preparation may load other sources and run autocmds. Validate again at edit time.
    local buf, reason = sources.validate(plan.edits[1].snapshot, true)
    if not buf or s.generation ~= operation.generation then
      stale_source(
        report,
        plan.path,
        plan.edits,
        reason or 'session changed during replacement'
      )
    else
      local applied, edit_error = apply_source(plan, buf)
      report.applied = report.applied + applied
      if applied > 0 then
        changed[plan.path] = true
      end
      if edit_error then
        report.failed = report.failed + #plan.edits - applied
        table.insert(report.details, { path = plan.path, reason = edit_error })
      end
    end
  end
  return changed
end

local function select_successor(s, all, operation, report)
  if not all and report.applied == 1 then
    local selected, successor = operation.selected, operation.successor
    if successor and successor.path == selected.path and successor.line == selected.line then
      successor.start = successor.start + #selected.replacement - (selected.finish - selected.start)
    end
    s.selection_after = successor
    s.selected, s.navigation_end = nil, not successor
  end
end

local function publish_report(s, report, changed)
  for path in pairs(changed) do
    search.source_changed(path, false)
  end
  s.report = report
  local message = report_text(report)
  s.message = message
  if next(changed) then
    search.refresh(s)
    s.message = message
  elseif report.stale > 0 then
    s.status = 'stale'
  end
  require('searchlight.view').render(s)
end

function M.apply(s, all)
  local valid, err = ready(s, all)
  if not valid then
    s.message = err
    require('searchlight.view').render(s)
    return nil, err
  end
  local report = { applied = 0, excluded = 0, stale = 0, unsupported = 0, failed = 0, details = {} }
  local operation, selection_error = freeze_targets(s, all, report)
  if not operation then
    return nil, selection_error
  end
  local plans = prepare_sources(s, operation, report)
  local changed = apply_sources(s, operation, plans, report)
  select_successor(s, all, operation, report)
  publish_report(s, report, changed)
  return report
end
return M
