local results = require('searchlight.results')
local sessions = require('searchlight.sessions')
local rg = require('searchlight.rg')
local scope = require('searchlight.scope')
local sources = require('searchlight.sources')
local process = require('searchlight.process')
local util = require('searchlight.util')
local controller = require('searchlight.controller')
local M = {}

local function current(s, gen)
  return sessions.owns(s) and s.generation == gen
end
local function render(s)
  require('searchlight.view').request_render(s)
end

local function transition(s, status, message)
  s.status, s.message = status, message
end

local function cancel_group(group)
  for _, record in pairs(group.jobs) do
    record.cancelled = true
    if record.handle then
      pcall(record.handle.kill, record.handle, 15)
    end
  end
end

function M.cancel(s)
  require('searchlight.highlight').invalidate(s)
  s.timer = util.close_timer(s.timer)
  if s.job_group then
    cancel_group(s.job_group)
    s.job_group = nil
  end
  s.jobs = {}
end

function M.invalidate(s, reason, launch)
  if not sessions.owns(s) then
    return
  end
  s.generation = s.generation + 1
  M.cancel(s)
  for _, r in ipairs(s.results) do
    r.stale = true
  end
  transition(
    s,
    s.fields.query == '' and 'empty' or (launch == false and 'stale' or 'waiting'),
    reason
  )
  if s.fields.query == '' then
    s.results, s.selected, s.snapshots, s.identities = {}, nil, {}, {}
  end
  render(s)
  if launch ~= false and s.fields.query ~= '' then
    local gen = s.generation
    s.timer = vim.uv.new_timer()
    s.timer:start(
      s.config.debounce_ms,
      0,
      vim.schedule_wrap(function()
        if current(s, gen) then
          s.timer = util.close_timer(s.timer)
          M.launch(s, gen)
        end
      end)
    )
  end
end

local function fail(s, gen, message)
  if not current(s, gen) then
    return
  end
  M.cancel(s)
  transition(s, 'error', message)
  for _, result in ipairs(s.results) do
    result.stale = true
  end
  render(s)
end

-- A group owns accepting jobs; the session owns all unsettled handles, including
-- older cancelled generations. Cancellation never releases pending ownership.
local function job_group(s, gen)
  if not s.job_group then
    s.job_group = {
      session = s,
      generation = gen,
      jobs = s.jobs,
      pending = s.pending_jobs,
      output_limit = s.config.max_output_bytes,
    }
  end
  return s.job_group
end

-- Stream callbacks may arrive on a libuv thread. Reserve queued bytes before
-- scheduling delivery, and mutate domain models only on the main loop.
-- A tolerant job reports a start error to `done` with a nil result instead of failing the run.
local function start_job(group, argv, opts, chunk, done, cleanup, tolerant)
  local s, gen = group.session, group.generation
  local record = { queued = 0, stderr = '', cancelled = false, finishing = false }
  group.jobs[record], group.pending[record] = record, record
  local function finalize(out, start_error)
    if record.settled then
      return
    end
    record.settled = true
    group.jobs[record], group.pending[record] = nil, nil
    if cleanup then
      cleanup()
    end
    if current(s, gen) and not record.cancelled then
      if start_error and not tolerant then
        fail(s, gen, tostring(start_error))
      else
        done(out, record.stderr)
      end
    end
  end
  local function finish(out)
    if record.finishing then
      return
    end
    record.finishing = true
    vim.schedule(function()
      finalize(out)
    end)
  end
  opts.stdout = function(err, data)
    if record.cancelled or record.finishing then
      return
    end
    if err then
      vim.schedule(function()
        fail(s, gen, tostring(err))
      end)
      return
    end
    if not data then
      return
    end
    record.queued = record.queued + #data
    if record.queued > group.output_limit then
      record.cancelled = true
      if record.handle then
        pcall(record.handle.kill, record.handle, 15)
      end
      vim.schedule(function()
        fail(s, gen, 'Process output exceeds queued byte limit')
      end)
      return
    end
    vim.schedule(function()
      record.queued = record.queued - #data
      if current(s, gen) and not record.cancelled then
        local ok, error_message = pcall(chunk, data)
        if not ok then
          fail(s, gen, tostring(error_message))
        end
      end
    end)
  end
  opts.stderr = function(err, data)
    if not record.cancelled and not record.finishing then
      record.stderr = (record.stderr .. (data or tostring(err or ''))):sub(1, 8192)
    end
  end
  local ok, handle = pcall(process.start, argv, opts, finish)
  if not ok then
    record.finishing = true
    finalize(nil, handle)
    return
  end
  record.handle = handle
  if record.cancelled then
    pcall(handle.kill, handle, 15)
  end
  return record
end

-- Session observations stay compatible; the run owns request/phase state and is
-- captured only by its jobs. Domain callbacks never read mutable input mid-run.
local function prepare_run(s, gen)
  local request = {
    mode = s.mode,
    root = s.root,
    fields = vim.deepcopy(s.fields),
    options = vim.deepcopy(s.options),
    config = vim.deepcopy(s.config),
  }
  if
    request.fields.query:find('[\r\n]')
    or request.mode == 'replace' and request.fields.replacement:find('[\r\n]')
  then
    fail(
      s,
      gen,
      request.mode == 'replace' and 'Search and Replace each accept one logical line'
        or 'Search accepts one logical line'
    )
    return
  end
  local cap = rg.probe()
  if not cap.search then
    fail(s, gen, cap.reason)
    return
  end
  local settings, config_error = rg.config(request.options.ignored)
  if not settings then
    fail(s, gen, config_error)
    return
  end
  request.follow = settings.follow
  local ok, argv = pcall(rg.inventory, request)
  if not ok then
    fail(s, gen, tostring(argv))
    return
  end
  local stat = vim.uv.fs_stat(request.root)
  if not stat or stat.type ~= 'directory' then
    fail(s, gen, 'Search root is not a directory: ' .. request.root)
    return
  end
  local buffers_ok, buffers = pcall(scope.buffers, request.root)
  if not buffers_ok then
    fail(s, gen, tostring(buffers))
    return
  end
  local inventory = {
    eligible = {},
    identities = {},
    preferred = {},
    count = 0,
    pending = {},
    head = 1,
    tail = 0,
  }
  inventory.split = rg.split('\0', function(rel)
    inventory.tail = inventory.tail + 1
    inventory.pending[inventory.tail] = rel
  end, request.config.max_output_bytes)
  for _, buffer in ipairs(buffers) do
    inventory.preferred[scope.identity(buffer.path)] = buffer.path
  end
  return {
    session = s,
    generation = gen,
    request = request,
    argv = argv,
    match_argv = rg.match(request),
    buffers = buffers,
    inventory = inventory,
    group = job_group(s, gen),
    queue = {},
    next_source = 1,
    active = 0,
    previous_exclusions = s.exclusions,
    exclusions = {},
    snapshot_bytes = 0,
  }
end

local function admit_path(run, rel)
  local inventory, request = run.inventory, run.request
  rel = rel:gsub('^%./', '')
  local path = (request.root == '/' and '' or request.root) .. '/' .. rel
  -- Without --follow, ripgrep lists no symlinks, so a path under the canonical root
  -- is already canonical.
  if request.follow then
    path = scope.path(path)
  end
  local identity = scope.identity(path)
  path = inventory.preferred[identity] or path
  if
    scope.contains(request.root, path)
    and not scope.metadata(request.root, path)
    and not inventory.identities[identity]
  then
    inventory.identities[identity] = true
    inventory.eligible[path] = true
    inventory.count = inventory.count + 1
    if inventory.count > request.config.max_files then
      error('File inventory cap reached; increase max_files and refresh')
    end
  end
end

-- Paths admitted per main-loop step, so large inventories do not block input.
local inventory_batch = 5000

local pump_inventory
local function schedule_inventory(run)
  if not run.inventory.scheduled then
    run.inventory.scheduled = true
    vim.schedule(function()
      pump_inventory(run)
    end)
  end
end

pump_inventory = function(run)
  local s, gen, inventory = run.session, run.generation, run.inventory
  inventory.scheduled = false
  if not current(s, gen) or s.status ~= 'searching' then
    return
  end
  local ok, err = pcall(function()
    local last = math.min(inventory.head + inventory_batch - 1, inventory.tail)
    for i = inventory.head, last do
      local rel = inventory.pending[i]
      inventory.pending[i] = nil
      inventory.head = i + 1
      admit_path(run, rel)
    end
  end)
  if not ok then
    fail(s, gen, tostring(err))
  elseif inventory.head <= inventory.tail then
    schedule_inventory(run)
  elseif inventory.drained then
    local drained = inventory.drained
    inventory.drained = nil
    drained()
  end
end

local function decode_inventory(run, data)
  run.inventory.split(data, false)
  schedule_inventory(run)
end

-- Calls `done` once every decoded path is admitted.
local function drain_inventory(run, done)
  local inventory = run.inventory
  if inventory.head > inventory.tail and not inventory.scheduled then
    done()
  else
    inventory.drained = done
  end
end

local function select_sources(run)
  local by_path, queue = {}, {}
  for _, b in ipairs(run.buffers) do
    if run.inventory.eligible[b.path] then
      by_path[b.path] = b.buf
    end
  end
  for path in pairs(run.inventory.eligible) do
    if
      (not run.request.options.open or by_path[path])
      and (not run.candidates or run.candidates[path])
    then
      table.insert(queue, { path = path, buf = by_path[path] })
    end
  end
  table.sort(queue, function(a, b)
    return a.path < b.path
  end)
  run.queue = queue
end

local function finalize_run(run)
  local s, gen = run.session, run.generation
  if not current(s, gen) or s.status ~= 'searching' then
    return
  end
  local reset_count = 0
  for id in pairs(run.previous_exclusions) do
    if not run.exclusions[id] then
      reset_count = reset_count + 1
    end
  end
  s.exclusions = run.exclusions
  results.order(s)
  transition(s, s.incomplete and 'truncated' or 'complete', s.message)
  if reset_count > 0 then
    s.message = (s.message or '') .. ' Exclusions reset for changed snapshots: ' .. reset_count
  end
  render(s)
end

local function accept_record(run, match, item)
  local s, gen, snap = run.session, run.generation, match.snapshot
  if s.status ~= 'searching' then
    return
  end
  if item.type == 'context' then
    local line = item.data.line_number
    local text = rg.value(item.data.lines)
    if text and snap.lines[line] == text:gsub('\n$', '') then
      snap.context_lines[line] = snap.lines[line]
      render(s)
    end
    return
  end
  if item.type ~= 'match' then
    return
  end
  match.has_matches = true
  local line = item.data.line_number
  for _, submatch in ipairs(item.data.submatches) do
    if #s.results >= run.request.config.max_results then
      s.incomplete = true
      transition(
        s,
        'truncated',
        run.request.mode == 'replace'
            and 'Match cap reached; increase max_results and refresh for Replace all'
          or 'Match cap reached; increase max_results and refresh'
      )
      M.cancel(s)
      results.order(s)
      render(s)
      return
    end
    local start, stop = submatch.start, submatch['end']
    local matched = rg.value(submatch.match)
    if not snap.lines[line] or snap.lines[line]:sub(start + 1, stop) ~= matched then
      error('ripgrep range does not map to decoded source snapshot: ' .. match.candidate.path)
    end
    local id = match.candidate.path
      .. ':'
      .. snap.hash
      .. ':'
      .. line
      .. ':'
      .. start
      .. ':'
      .. stop
    local enabled = not run.previous_exclusions[id]
    if not enabled then
      run.exclusions[id] = true
    end
    table.insert(s.results, {
      id = id,
      path = match.candidate.path,
      snapshot = snap,
      buf = snap.buf,
      line = line,
      start = start,
      finish = stop,
      match = matched,
      replacement = run.request.mode == 'replace' and rg.value(submatch.replacement) or nil,
      enabled = enabled,
      stale = false,
      generation = gen,
      context = snap.lines[line],
      context_size = run.request.options.context,
    })
  end
  render(s)
end

-- The run accounts admitted text; the session value is its compatibility observation.
local function account_snapshots(run, delta)
  run.snapshot_bytes = run.snapshot_bytes + delta
  run.session.snapshot_bytes = run.snapshot_bytes
end

local pump_sources
local function finish_match(run, match, out, stderr)
  local s, gen, snap = run.session, run.generation, match.snapshot
  local decoder = match.decoder
  local decoded, decode_err = pcall(decoder, '', true)
  if not decoded then
    fail(s, gen, tostring(decode_err))
    return
  end
  if out.code ~= 0 and out.code ~= 1 then
    fail(s, gen, stderr ~= '' and stderr or 'ripgrep exited ' .. out.code)
    return
  end
  if
    snap.buf
    and (
      not vim.api.nvim_buf_is_valid(snap.buf)
      or vim.api.nvim_buf_get_changedtick(snap.buf) ~= snap.tick
    )
  then
    M.invalidate(s, 'Source changed during search', false)
    return
  end
  run.active = run.active - 1
  if not match.has_matches then
    account_snapshots(run, -#snap.text)
    -- Keep physical identity for cross-root aliases with zero hits,
    -- without retaining the complete contents of every scanned file.
    snap.text, snap.lines = nil, nil
  end
  pump_sources(run)
end

local function start_matching(run, candidate, snap)
  local match = { candidate = candidate, snapshot = snap, has_matches = false }
  run.active = run.active + 1
  match.decoder = rg.decoder(function(item)
    accept_record(run, match, item)
  end, run.request.config.max_output_bytes)
  start_job(run.group, run.match_argv, { cwd = run.request.root, stdin = snap.text }, function(data)
    match.decoder(data, false)
  end, function(out, stderr)
    finish_match(run, match, out, stderr)
  end)
end

local function capture_snapshot(run, candidate)
  local prefer_disk = not run.request.options.open
    and candidate.buf
    and not vim.bo[candidate.buf].modified
    and vim.uv.fs_stat(candidate.path) ~= nil
  local snap, err =
    sources.capture(candidate.path, candidate.buf, run.request.config.max_source_bytes, prefer_disk)
  if snap and run.snapshot_bytes + #snap.text > run.request.config.max_snapshot_bytes then
    if run.active > 0 then
      -- Retry after active sources have a chance to release no-hit snapshots.
      return nil, nil, true
    end
    snap, err = nil, 'session snapshot byte budget reached; increase max_snapshot_bytes and refresh'
  end
  return snap, err
end

pump_sources = function(run)
  local s, gen = run.session, run.generation
  if not current(s, gen) or s.status ~= 'searching' then
    return
  end
  local examined = 0
  while run.active < run.request.config.concurrency and run.next_source <= #run.queue do
    if examined >= 50 then
      vim.schedule(function()
        pump_sources(run)
      end)
      return
    end
    examined = examined + 1
    local candidate = run.queue[run.next_source]
    run.next_source = run.next_source + 1
    local snap, err, retry = capture_snapshot(run, candidate)
    if retry then
      run.next_source = run.next_source - 1
      return
    end
    -- A mixed-ending file without a disk hit cannot hide a match.
    local unmatched = err == 'mixed or unsupported source line endings'
      and run.hits
      and not run.hits[candidate.path]
    if not snap then
      if err ~= 'binary source (NUL bytes)' and not unmatched then
        s.incomplete = true
        s.message = (s.message or '') .. ' Skipped ' .. candidate.path .. ': ' .. tostring(err)
      end
    else
      snap.context_lines = {}
      s.snapshots[candidate.path] = snap
      account_snapshots(run, #snap.text)
      start_matching(run, candidate, snap)
      if s.status ~= 'searching' then
        return
      end
    end
  end
  if run.active == 0 and run.next_source > #run.queue then
    finalize_run(run)
  end
end

local function match_sources(run)
  local s, gen = run.session, run.generation
  select_sources(run)
  if #run.queue == 0 then
    -- Compile even with no eligible sources; empty scopes must report invalid regex.
    start_job(
      run.group,
      run.match_argv,
      { cwd = run.request.root, stdin = '' },
      function() end,
      function(out, stderr)
        if out.code ~= 0 and out.code ~= 1 then
          fail(s, gen, stderr ~= '' and stderr or 'Query validation failed')
        else
          finalize_run(run)
        end
      end
    )
  else
    pump_sources(run)
  end
end

-- Disk hits miss only snapshots that differ from disk bytes: decode-sensitive files and
-- buffer-sourced text. Those are always candidates. Any prefilter failure keeps every source.
local function prefilter_sources(run)
  local request = run.request
  if request.options.open then
    match_sources(run)
    return
  end
  local buffers = {}
  for _, b in ipairs(run.buffers) do
    buffers[b.path] = b.buf
  end
  local candidates, relative, paths = {}, {}, {}
  for path in pairs(run.inventory.eligible) do
    local buf = buffers[path]
    if buf and (vim.bo[buf].modified or not vim.uv.fs_stat(path)) then
      candidates[path] = true
    else
      local rel = scope.relative(request.root, path)
      relative[rel] = path
      table.insert(paths, rel)
    end
  end
  if #paths == 0 then
    run.candidates, run.hits = candidates, {}
    match_sources(run)
    return
  end
  table.sort(paths)
  local hits, failed, jobs = {}, false, {}
  for _, argv in ipairs(rg.prefilter(request, paths)) do
    table.insert(jobs, { argv = argv, hit = true })
  end
  for _, argv in ipairs(rg.decode_sensitive(paths)) do
    table.insert(jobs, { argv = argv })
  end
  local remaining = #jobs
  local function settle()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    if not failed then
      run.candidates, run.hits = candidates, hits
    end
    match_sources(run)
  end
  for _, job in ipairs(jobs) do
    local split = rg.split('\0', function(rel)
      local path = relative[rel]
      if not path then
        failed = true
      else
        candidates[path] = true
        if job.hit then
          hits[path] = true
        end
      end
    end, request.config.max_output_bytes)
    start_job(run.group, job.argv, { cwd = request.root }, function(data)
      split(data, false)
    end, function(out)
      if not out or out.code ~= 0 and out.code ~= 1 or split(nil, true) ~= '' then
        failed = true
      end
      settle()
    end, nil, true)
  end
end

local function begin_matching(run)
  if current(run.session, run.generation) then
    prefilter_sources(run)
  end
end

local function check_new_names(run)
  local s, gen = run.session, run.generation
  local candidates = {}
  for _, b in ipairs(run.buffers) do
    if not vim.uv.fs_stat(b.path) then
      table.insert(candidates, b)
    end
  end
  if #candidates == 0 then
    begin_matching(run)
    return
  end
  local shadow_ok, shadow = pcall(scope.shadow, run.request.root, candidates)
  if not shadow_ok then
    fail(s, gen, tostring(shadow))
    return
  end
  start_job(run.group, run.argv, { cwd = shadow.cwd }, function(data)
    decode_inventory(run, data)
  end, function(shadow_out, shadow_stderr)
    if shadow_out.code ~= 0 and shadow_out.code ~= 1 then
      fail(s, gen, shadow_stderr)
      return
    end
    if run.inventory.split(nil, true) ~= '' then
      fail(s, gen, 'Unterminated new-buffer inventory')
      return
    end
    drain_inventory(run, function()
      begin_matching(run)
    end)
  end, function()
    scope.cleanup(shadow)
  end)
end

local function collect_inventory(run)
  local s, gen = run.session, run.generation
  start_job(run.group, run.argv, { cwd = run.request.root }, function(data)
    decode_inventory(run, data)
  end, function(out, stderr)
    if out.code ~= 0 and out.code ~= 1 then
      fail(s, gen, stderr ~= '' and stderr or 'File inventory failed')
    elseif run.inventory.split(nil, true) ~= '' then
      fail(s, gen, 'Unterminated ripgrep inventory')
    else
      drain_inventory(run, function()
        check_new_names(run)
      end)
    end
  end)
end

function M.launch(s, gen)
  if not current(s, gen) or s.fields.query == '' then
    return
  end
  if not rg.probe(function()
    M.launch(s, gen)
  end) then
    return
  end
  controller.synchronize(s, 'launch')
  if not current(s, gen) or s.fields.query == '' then
    return
  end
  local run = prepare_run(s, gen)
  if not run then
    return
  end
  -- Inventory identities let alias writes from other roots invalidate unscanned sources.
  s.results, s.snapshots, s.identities = {}, {}, run.inventory.identities
  transition(s, 'searching', run.request.mode == 'replace' and rg.probe().reason or nil)
  account_snapshots(run, 0)
  s.incomplete = false
  render(s)
  collect_inventory(run)
end

function M.refresh(s)
  M.invalidate(s)
  s.timer = util.close_timer(s.timer)
  M.launch(s, s.generation)
end

function M.source_changed(path, launch, generations)
  -- Observe source edits for safety, but searching is an explicit panel action.
  launch = launch == true
  path = scope.path(path)
  local identities = { [scope.identity(path)] = true }
  for _, s in pairs(sessions.by_id) do
    local snap = s.snapshots[path]
    if snap and snap.disk.exists then
      identities[scope.identity_of(snap.disk)] = true
    end
  end
  for _, s in pairs(sessions.by_id) do
    local affected = scope.contains(s.root, path)
    for identity in pairs(identities) do
      affected = affected or s.identities[identity] == true
    end
    if not affected then
      for _, snap in pairs(s.snapshots) do
        if snap.disk.exists and identities[scope.identity_of(snap.disk)] then
          affected = true
          break
        end
      end
    end
    if affected and (not generations or generations[s.id] == s.generation) then
      M.invalidate(s, 'Source changed: ' .. path, launch)
    end
  end
end
return M
