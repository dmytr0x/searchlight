local H = dofile('tests/nvim/helpers.lua')
local p = require('searchlight')
p.setup({ debounce_ms = 10 })
local a = H.fixture()
for i = 1, 200 do
  H.write(a .. string.format('/file%03d.txt', i), string.rep('abc abc abc abc\n', 25))
end
local started, first, beats, largest_gap, last = vim.uv.hrtime(), nil, 0, 0, vim.uv.hrtime()
local s = p.new(a)
local timer = vim.uv.new_timer()
timer:start(
  0,
  10,
  vim.schedule_wrap(function()
    local now = vim.uv.hrtime()
    largest_gap = math.max(largest_gap, (now - last) / 1e6)
    last, beats = now, beats + 1
    if not first and #s.results > 0 then
      first = (now - started) / 1e6
    end
  end)
)
local ok, err = xpcall(function()
  p.set(s, { query = 'abc', replacement = 'X' })
  p.refresh(s)
  H.wait(s, 'truncated')
  H.eq(#s.results, 10000)
  H.eq(p.action(s, 'replace_all'), nil)
  assert(beats > 1, 'main loop did not continue during search')
  print(vim.json.encode({
    files = 200,
    scope_matches = 20000,
    displayed = #s.results,
    status = s.status,
    first_results_ms = first,
    total_ms = (vim.uv.hrtime() - started) / 1e6,
    heartbeat_count = beats,
    longest_heartbeat_gap_ms = largest_gap,
  }))
end, debug.traceback)
timer:stop()
timer:close()
H.cleanup()
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit(1)
else
  vim.cmd.qa({ bang = true })
end
