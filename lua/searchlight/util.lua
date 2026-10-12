local M = {}

-- Returns nil so callers can clear their reference in the same statement.
function M.close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  return nil
end

return M
