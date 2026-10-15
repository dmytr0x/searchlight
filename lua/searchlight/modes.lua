-- The two session capabilities share one search engine and panel renderer.
local M = {}
local definitions = {
  search = { fields = { 'query', 'include', 'exclude' }, replacement = false },
  replace = { fields = { 'query', 'replacement', 'include', 'exclude' }, replacement = true },
}
M.replacement_reason =
  'Replacement is unavailable in Search sessions; create a Search & Replace session'

function M.get(mode)
  return assert(definitions[mode], 'Invalid Searchlight session mode: ' .. tostring(mode))
end

function M.can_replace(s)
  return M.get(s.mode).replacement
end

function M.has_field(s, name)
  return vim.tbl_contains(M.get(s.mode).fields, name)
end

return M
