-- The single external-process seam: production uses vim.system; tests can inject a driver.
local M = {}
function M.start(argv, opts, done)
  return vim.system(argv, opts, done)
end
return M
