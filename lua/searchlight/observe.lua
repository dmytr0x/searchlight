-- Idempotent source-buffer observation, including edits to sources with zero hits.
local sessions = require('searchlight.sessions')
local search = require('searchlight.search')
local scope = require('searchlight.scope')
local sources = require('searchlight.sources')
local M = { watched = {} }

local function generations(filter)
  local result = {}
  for id, s in pairs(sessions.by_id) do
    if not filter or filter(s) then
      result[id] = s.generation
    end
  end
  return result
end

local function watch(buf)
  if
    M.watched[buf]
    or not vim.api.nvim_buf_is_loaded(buf)
    or vim.bo[buf].buftype ~= ''
    or not vim.bo[buf].buflisted
    or vim.api.nvim_buf_get_name(buf) == ''
  then
    return
  end
  M.watched[buf] = scope.path(vim.api.nvim_buf_get_name(buf))
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if sources.mutating or vim.bo[buf].buftype ~= '' then
        return
      end
      local path = M.watched[buf]
      if path then
        local current = generations()
        vim.schedule(function()
          -- An explicit search started after this edit already sees the new text.
          search.source_changed(path, false, current)
        end)
      end
    end,
    on_detach = function()
      M.watched[buf] = nil
    end,
  })
end
M.watch = watch

function M.setup()
  local group = vim.api.nvim_create_augroup('SearchlightSources', { clear = true })
  vim.api.nvim_create_autocmd({
    'BufEnter',
    'BufReadPost',
    'BufAdd',
    'BufFilePost',
    'BufWritePost',
    'BufDelete',
    'BufWipeout',
  }, {
    group = group,
    callback = function(event)
      local buf = event.buf
      if sessions.by_buf[buf] or sources.mutating then
        return
      end
      local old = M.watched[buf]
      local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ''
      local path = name ~= '' and scope.path(name) or nil
      if event.event == 'BufFilePost' and old then
        search.source_changed(old)
        M.watched[buf] = path
      end
      if
        event.event ~= 'BufEnter'
        -- Initial loading does not change a source; it can be part of snapshot capture.
        and (event.event ~= 'BufReadPost' or old)
        and path
        and vim.bo[buf].buftype == ''
        and (vim.bo[buf].buflisted or old)
      then
        if event.event == 'BufAdd' and vim.uv.fs_stat(path) then
          -- Listing an existing file changes open-file scope, not its contents.
          -- Keep disk searches fresh when a result is opened through :edit.
          search.source_changed(
            path,
            false,
            generations(function(s)
              return s.options.open
            end)
          )
        else
          search.source_changed(path)
        end
      end
      watch(buf)
    end,
  })
  vim.api.nvim_create_autocmd('OptionSet', {
    group = group,
    pattern = { 'buflisted', 'fileencoding', 'fileformat', 'endofline', 'bomb' },
    callback = function()
      if sources.mutating then
        return
      end
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= '' then
        search.source_changed(vim.api.nvim_buf_get_name(buf))
        watch(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, s in pairs(sessions.by_id) do
        sessions.dispose(s)
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    watch(buf)
  end
end
return M
