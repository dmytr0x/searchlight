-- Session control that panel modules call back into. View, actions and search load
-- lazily, so every module can require this one at load time.
local input = require('searchlight.input')
local sessions = require('searchlight.sessions')
local scope = require('searchlight.scope')
local M = {}

-- Every input origin comes through this coordinator. Reading regions reports changes;
-- only the coordinator chooses whether they invalidate, debounce or submit immediately.
function M.synchronize(s, origin, changes, execution)
  -- Validate API updates before reading native edits or invalidating any state.
  if origin == 'set' then
    input.update(s, changes, scope.path)
    input.execution(execution, 'debounced')
  end
  local search = require('searchlight.search')
  local read = require('searchlight.view').read(s)
  if read then
    for name, value in pairs(read.fields) do
      s.fields[name] = value
    end
    s.options, s.search_heading = read.options, read.heading
  end
  local changed = s.input_changed or read and read.changed or false
  if origin == 'capture' then
    s.input_changed = changed or nil
    return changed
  end
  s.input_changed = nil
  if origin == 'set' then
    local next_input = input.update(s, changes, scope.path)
    s.fields, s.options, s.root = next_input.fields, next_input.options, next_input.root
    s.config, s.sections = next_input.config, next_input.sections
    s.search_heading = next_input.heading
    s.fields_dirty = true
    if next_input.search_changed or changed then
      s.navigation_end, s.selection_after = false, nil
    end
    local policy = input.execution(execution, 'debounced')
    -- Native edits alone retain their manual-submit contract under the default policy.
    if execution and execution.refresh ~= nil or next_input.search_changed then
      M.execute(s, policy, next_input.search_changed or changed)
    elseif changed then
      search.invalidate(s, '', false)
    end
  elseif origin == 'refresh' then
    search.refresh(s)
  elseif changed then
    search.invalidate(s, '', false)
  end
  sessions.sync_name(s)
  return changed
end

-- Choose one invalidation/launch path for the complete committed update.
function M.execute(s, policy, changed)
  local search = require('searchlight.search')
  if policy == 'immediate' then
    search.refresh(s)
  elseif policy == 'debounced' then
    search.invalidate(s)
  elseif changed then
    search.invalidate(s, '', false)
  end
end

function M.set(s, changes, execution)
  s = sessions.own(s)
  M.synchronize(s, 'set', changes, execution)
  require('searchlight.view').render(s)
end

function M.refresh(s)
  s = sessions.own(s)
  M.synchronize(s, 'refresh')
end

function M.close(s)
  s = sessions.own(s)
  sessions.dispose(s)
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
end

function M.action(s, name, arg)
  return require('searchlight.actions').action(s, name, arg)
end

return M
