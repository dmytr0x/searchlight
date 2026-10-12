-- Optional snapshot syntax enrichment. All ownership and budgets are process-wide.
-- Redraw reads ready numeric records only; parsing/querying happens on the main-loop worker.
local M = { namespace = vim.api.nvim_create_namespace('searchlight_syntax') }
local sessions = require('searchlight.sessions')
local scope = require('searchlight.scope')
local limits = {
  parsers = 2,
  retained_bytes = 512 * 1024,
  spans = 8192,
  rows = 256,
  blocks = 1024,
  chunks = 256,
  chunk_lines = 40,
  captures = 1024,
  line_bytes = 4096,
  demands = 8,
  languages = 8,
  failures = 64,
  missing = 64,
  groups = 1024,
  batch_ms = 3,
}
-- One global cache owns entries, parser/text capacity, chunks and lookup records.
local cache = {
  entries = {},
  failures = {},
  missing = {},
  languages = {},
  -- Highlight queries of admitted injected languages.
  queries = {},
  groups = {},
  group_ids = {},
  clock = 0,
  revision = 0,
}
-- Windows own their demands and packed mappings.
local viewport = { demands = {}, serial = 0, request_pending = false }
-- Scheduled work and the one in-flight parse share process-wide progress.
local progress = {
  busy = false,
  pending = false,
  redraw_pending = false,
  redraw_all = false,
  redraw_wins = {},
  reload_pending = false,
  initialized = false,
}
-- maps[i + 0..6]: panel row (0-based), source line (1-based), byte gutter,
-- contiguous line-byte lengths, canonical source path, SHA-256:language key, language.
-- spans[i + 0..4]: source line (1-based), left/right byte offsets (right exclusive),
-- interned group index, priority rank below the search match layer.
-- Published chunk spans are sorted by line; line_start[line] is that line's first span.
local MAP_WIDTH, SPAN_WIDTH = 7, 5
local counters = {
  parsers = 0,
  retained_bytes = 0,
  spans = 0,
  blocks = 0,
  rows = 0,
  demands = 0,
  languages = 0,
  failures = 0,
  missing = 0,
  groups = 0,
  chunks = 0,
  parses = 0,
  extractions = 0,
  destroyed = 0,
  dropped = 0,
  max_batch_ms = 0,
}
local high_water = {}
local function count(name, amount)
  counters[name] = counters[name] + amount
  high_water[name] = math.max(high_water[name] or 0, counters[name])
end
local adapter = {
  now = function()
    return vim.uv.hrtime() / 1e6
  end,
  -- `buffers` maps canonical paths to loaded buffers; it is built lazily by the caller.
  language = function(snapshot, buffers)
    local ft
    if snapshot.buf and vim.api.nvim_buf_is_valid(snapshot.buf) then
      ft = vim.bo[snapshot.buf].filetype
    else
      -- Metadata only: never bufadd/bufload, and never start a source highlighter/LSP.
      local buf = buffers()[snapshot.path]
      if buf and vim.api.nvim_buf_is_valid(buf) then
        ft = vim.bo[buf].filetype
      end
    end
    if not ft or ft == '' then
      ft = vim.filetype.match({ filename = snapshot.path, contents = snapshot.lines })
    end
    return ft and vim.treesitter.language.get_lang(ft)
  end,
  query = function(lang)
    return vim.treesitter.query.get(lang, 'highlights')
  end,
  load = function(lang)
    return vim.treesitter.language.add(lang)
  end,
  injections = function(lang)
    return vim.treesitter.query.get(lang, 'injections')
  end,
  -- Mirrors LanguageTree injection resolution: an alias names a language only with a parser.
  resolve = function(alias)
    alias = alias:gsub('%s+', ''):lower():gsub('%-', '_')
    if alias:match('[%w_]+') ~= alias then
      return
    end
    for _, lang in ipairs({ alias, vim.treesitter.language.get_lang(alias) }) do
      if
        vim._ts_has_language(lang)
        or #vim.api.nvim_get_runtime_file('parser/' .. lang .. '.*', false) > 0
      then
        return lang
      end
    end
  end,
  parser = function(text, lang)
    -- parse(false) uses the parent tree only. Empty child injection queries keep
    -- injections one level deep, so only languages discovered in the parent can load.
    return vim.treesitter.get_string_parser(text, lang, {
      injections = setmetatable({}, {
        __index = function(_, child)
          return child ~= lang and '' or nil
        end,
      }),
    })
  end,
  range = function(node, text, metadata)
    local r = vim.treesitter.get_range(node, text, metadata)
    return r[1], r[2], r[4], r[5]
  end,
  defer = function(ms, callback)
    vim.defer_fn(callback, ms)
  end,
}
local default_adapter = adapter
local default_limits = vim.deepcopy(limits)
local function now()
  return adapter.now()
end
local function tick()
  cache.clock = cache.clock + 1
  return cache.clock
end
local function remove_record(records, name, key)
  if records[key] then
    records[key] = nil
    counters[name] = counters[name] - 1
  end
end
local function clear_records(records, name)
  for key in pairs(records) do
    remove_record(records, name, key)
  end
end
local function release_language(lang)
  cache.languages[lang] = nil
  counters.languages = counters.languages - 1
end
local function release_groups()
  cache.groups, cache.group_ids = {}, {}
  counters.groups = 0
end
-- Without `win`, every window is redrawn.
local function redraw(win)
  if win then
    progress.redraw_wins[win] = true
  else
    progress.redraw_all = true
  end
  if progress.redraw_pending then
    return
  end
  progress.redraw_pending = true
  vim.schedule(function()
    local all, wins = progress.redraw_all, progress.redraw_wins
    progress.redraw_pending, progress.redraw_all, progress.redraw_wins = false, false, {}
    if not vim.api.nvim__redraw then
      vim.cmd('redraw!')
    elseif all then
      vim.api.nvim__redraw({ valid = false })
    else
      for target in pairs(wins) do
        if vim.api.nvim_win_is_valid(target) then
          vim.api.nvim__redraw({ win = target, valid = false })
        end
      end
    end
  end)
end
local function record(records, name, key, cooldown)
  if #key > 256 then
    return
  end
  if not records[key] then
    if counters[name] == limits[name] then
      local oldest, age
      for k, v in pairs(records) do
        if not age or v[1] < age then
          oldest, age = k, v[1]
        end
      end
      remove_record(records, name, oldest)
    end
    count(name, 1)
  end
  records[key] = { tick(), cooldown and now() + cooldown or math.huge }
end
local function suppressed(records, key)
  return records[key] and records[key][2] > now()
end
-- Transient failures (parse timeouts, budgets) retry with exponential backoff and
-- recover without user input; permanent failures keep a fixed cooldown.
local function retry()
  for _, d in pairs(viewport.demands) do
    d.done, d.next_map, d.next_line = false, 1, 0
  end
  M.request()
end
local function backoff(key)
  local previous = cache.failures[key]
  local attempts = (previous and previous[3] or 0) + 1
  local delay = math.min(1000 * 2 ^ (attempts - 1), 30000)
  record(cache.failures, 'failures', key, delay)
  if cache.failures[key] then
    cache.failures[key][3] = attempts
    adapter.defer(delay, retry)
  end
end
local function drop_demand(win)
  local d = viewport.demands[win]
  if not d then
    return
  end
  counters.blocks = counters.blocks - #d.maps / MAP_WIDTH
  counters.rows = counters.rows - d.rows
  counters.demands = counters.demands - 1
  viewport.demands[win] = nil
end
local function drop_demands(id)
  for win, d in pairs(viewport.demands) do
    if not id or d.id == id then
      drop_demand(win)
    end
  end
end
local function release_chunk(chunk)
  counters.spans = counters.spans - #chunk.spans / SPAN_WIDTH
  counters.chunks = counters.chunks - 1
end
local function remove_chunk(e, first)
  local chunk = e.chunks[first]
  if chunk then
    release_chunk(chunk)
    e.chunks[first] = nil
    for line = first, first + chunk.lines - 1 do
      e.lines[line] = nil
    end
  end
end
-- Published chunks never overlap; e.lines[line] is the start of the chunk covering line.
local function chunk_for(e, line)
  local first = e.lines[line]
  if first then
    return e.chunks[first], first
  end
end
local function clear_chunks(e)
  for first in pairs(e.chunks) do
    remove_chunk(e, first)
  end
end
local function reserve_parser(e, text)
  count('parsers', 1)
  count('retained_bytes', #text)
  e.text, e.used, e.active = text, tick(), true
end
local function release_parser(e)
  if e.text then
    if e.parser then
      pcall(e.parser.destroy, e.parser)
      counters.destroyed = counters.destroyed + 1
    end
    counters.parsers = counters.parsers - 1
    counters.retained_bytes = counters.retained_bytes - #e.text
    e.parser, e.tree, e.text = nil, nil, nil
  end
end
local function evict(key)
  local e = cache.entries[key]
  if not e or e.active then
    return false
  end
  clear_chunks(e)
  release_parser(e)
  cache.entries[key] = nil
  e.parser, e.tree, e.query, e.text, e.chunks, e.lines = nil, nil, nil, nil, nil, nil
  e.injections, e.combined = nil, nil
  return true
end
local function release_inactive_parser(except_key)
  local oldest
  for key, e in pairs(cache.entries) do
    if key ~= except_key and e.text and not e.active and (not oldest or e.used < oldest.used) then
      oldest = e
    end
  end
  if oldest then
    -- Visible colors own cached spans, not native trees or source strings. Recycle the
    -- parser capacity without erasing colors already extracted for another group.
    release_parser(oldest)
    return true
  end
  return false
end
-- Chunks mapped by a demand stay. Other chunks are kept, least recently used first out,
-- within half of the chunk and span budgets so scroll-back reuses them; with no demand
-- at all, nothing is kept.
local function trim_spans()
  local mapped, others = {}, {}
  for _, d in pairs(viewport.demands) do
    for i = 1, #d.maps, MAP_WIDTH do
      local e = cache.entries[d.maps[i + 5]]
      if e then
        for line = d.maps[i + 1], d.maps[i + 1] + #d.maps[i + 3] - 1 do
          local chunk = chunk_for(e, line)
          if chunk then
            mapped[chunk] = true
          end
        end
      end
    end
  end
  local keep = next(viewport.demands) ~= nil
  for _, e in pairs(cache.entries) do
    for first, chunk in pairs(e.chunks) do
      if not mapped[chunk] then
        others[#others + 1] = { e = e, first = first, used = chunk.used }
      end
    end
  end
  table.sort(others, function(a, b)
    return a.used < b.used
  end)
  for _, other in ipairs(others) do
    if keep and counters.chunks <= limits.chunks / 2 and counters.spans <= limits.spans / 2 then
      break
    end
    remove_chunk(other.e, other.first)
  end
  for key, e in pairs(cache.entries) do
    if not e.text and not next(e.chunks) then
      evict(key)
    end
  end
end
local function intern(name)
  if cache.group_ids[name] then
    return cache.group_ids[name]
  end
  if #name > 256 or #cache.groups >= limits.groups then
    return nil
  end
  local id = #cache.groups + 1
  -- Resolve named groups outside redraw. Creating a group during redraw can invalidate
  -- the same screen repeatedly; numeric IDs still follow colorscheme relinking.
  cache.groups[id], cache.group_ids[name] = vim.api.nvim_get_hl_id_by_name(name), id
  counters.groups = id
  high_water.groups = id
  return id
end
local worker
local function request_from_redraw()
  if not viewport.request_pending then
    viewport.request_pending = true
    vim.schedule(function()
      viewport.request_pending = false
      M.request()
    end)
  end
end
local function schedule_worker()
  if not progress.pending and not progress.busy then
    progress.pending = true
    -- Yield to the event loop between slices. Chaining vim.schedule callbacks can
    -- drain the entire workload before timers and input get another turn.
    vim.defer_fn(function()
      progress.pending = false
      worker()
    end, 0)
  end
end
local function valid(d)
  local s = sessions.by_id[d.id]
  return sessions.owns(s)
    and not s.layout_invalid
    and s.config.syntax_highlighting
    and s.generation == d.generation
    and s.layout_revision == d.layout
    and vim.api.nvim_win_is_valid(d.win)
    and vim.api.nvim_win_get_buf(d.win) == s.buf
    and vim.api.nvim_win_get_tabpage(d.win) == vim.api.nvim_get_current_tabpage()
end
local function parse_entry(e)
  local key = e.key
  progress.busy = true
  counters.parses = counters.parses + 1
  local done = false
  -- Async parsing yields between slices, so wall-clock time also counts unrelated
  -- scheduled work. The file size cap bounds parse cost; Neovim's 'redrawtime' TIMEOUT
  -- remains the safety net.
  local function finish(err, trees)
    if done then
      return
    end
    done, progress.busy, e.active = true, false, false
    if cache.entries[key] ~= e then
      schedule_worker()
      return
    end
    if err == 'TIMEOUT' then
      backoff(key)
      evict(key)
    elseif err or not trees or not trees[1] then
      record(cache.failures, 'failures', key, 30000)
      evict(key)
    else
      e.tree = trees[1]
      remove_record(cache.failures, 'failures', key)
    end
    schedule_worker()
  end
  -- The callback API can yield during injection processing, but Neovim's native
  -- string parse ignores its timeout. The snapshot size cap bounds that pause.
  local parsed, err = pcall(e.parser.parse, e.parser, false, finish)
  if not parsed then
    finish(err)
  end
end
-- Loads `lang` and its highlight query within the language budget; failures are
-- recorded as missing. Returns the query.
local function admit_language(lang)
  if cache.queries[lang] then
    return cache.queries[lang]
  end
  if
    suppressed(cache.missing, lang)
    or not cache.languages[lang] and counters.languages == limits.languages
  then
    return
  end
  local new_language = not cache.languages[lang]
  if new_language then
    cache.languages[lang] = true
    count('languages', 1)
  end
  local loaded, available = pcall(adapter.load, lang)
  if not loaded or not available then
    if new_language then
      release_language(lang)
    end
    record(cache.missing, 'missing', lang)
    return
  end
  local ok, query = pcall(adapter.query, lang)
  if not ok or not query then
    record(cache.missing, 'missing', lang)
    return
  end
  cache.queries[lang] = query
  return query
end
local function admit(snapshot, lang, key)
  local e = cache.entries[key]
  if e and (e.tree or e.active) then
    e.used = tick()
    return e
  end
  -- A source larger than all retained capacity would only evict other parsers.
  if
    #snapshot.text > limits.retained_bytes
    or suppressed(cache.failures, key)
    or suppressed(cache.missing, lang)
  then
    return
  end
  if not cache.languages[lang] and counters.languages == limits.languages then
    return
  end
  while
    counters.parsers >= limits.parsers
    or counters.retained_bytes + #snapshot.text > limits.retained_bytes
  do
    if not release_inactive_parser(key) then
      return
    end
  end
  if not e then
    e = { key = key, lang = lang, chunks = {}, lines = {} }
    cache.entries[key] = e
  end
  -- Reserve native parser/source capacity before query lookup or parser construction.
  reserve_parser(e, snapshot.text)
  local query = admit_language(lang)
  local parser_ok, parser = false, nil
  if query then
    parser_ok, parser = pcall(adapter.parser, e.text, lang)
  end
  if not parser_ok or not parser then
    if query then
      record(cache.missing, 'missing', lang)
    end
    e.active = false
    evict(key)
    return
  end
  e.query, e.parser = query, parser
  parse_entry(e)
  return e
end

local function reserve_chunk(lines, first)
  if counters.chunks >= limits.chunks then
    return
  end
  count('chunks', 1)
  -- raw[k] keeps the query priority of span k so later slices can re-rank the chunk.
  return { spans = {}, raw = {}, priorities = {}, lines = lines, next_line = first }
end
local function drop_lines(chunk, line)
  local spans, raw, kept = chunk.spans, chunk.raw, 0
  local total = #spans
  for i = 1, total, SPAN_WIDTH do
    if spans[i] < line then
      for k = 0, SPAN_WIDTH - 1 do
        spans[kept + 1 + k] = spans[i + k]
      end
      raw[kept / SPAN_WIDTH + 1] = raw[(i - 1) / SPAN_WIDTH + 1]
      kept = kept + SPAN_WIDTH
    end
  end
  for i = total, kept + 1, -1 do
    spans[i] = nil
  end
  for i = #raw, kept / SPAN_WIDTH + 1, -1 do
    raw[i] = nil
  end
  local removed = (total - kept) / SPAN_WIDTH
  counters.spans = counters.spans - removed
end
-- Stable sort by line keeps capture order, which breaks ties between equal priorities.
local function index_lines(chunk)
  local spans, raw, order = chunk.spans, chunk.raw, {}
  for k = 1, #raw do
    order[k] = k
  end
  table.sort(order, function(a, b)
    local left, right = spans[(a - 1) * SPAN_WIDTH + 1], spans[(b - 1) * SPAN_WIDTH + 1]
    if left ~= right then
      return left < right
    end
    return a < b
  end)
  local sorted, sorted_raw, line_start = {}, {}, {}
  for k, from in ipairs(order) do
    local i, j = (from - 1) * SPAN_WIDTH, (k - 1) * SPAN_WIDTH
    for f = 1, SPAN_WIDTH do
      sorted[j + f] = spans[i + f]
    end
    sorted_raw[k] = raw[from]
    line_start[sorted[j + 1]] = line_start[sorted[j + 1]] or j + 1
  end
  chunk.spans, chunk.raw, chunk.line_start = sorted, sorted_raw, line_start
end
local function publish_chunk(e, first, chunk, win)
  local spans = chunk.spans
  -- Rank priorities within a chunk, preserving overlap order below the match layer (2000).
  local ordered, ranks = {}, {}
  for priority in pairs(chunk.priorities) do
    ordered[#ordered + 1] = priority
  end
  table.sort(ordered)
  for rank, priority in ipairs(ordered) do
    ranks[priority] = rank + 10
  end
  for i = SPAN_WIDTH, #spans, SPAN_WIDTH do
    spans[i] = ranks[chunk.raw[i / SPAN_WIDTH]]
  end
  index_lines(chunk)
  if e.chunks[first] ~= chunk then
    e.chunks[first] = chunk
    for line = first, first + chunk.lines - 1 do
      e.lines[line] = first
    end
  end
  chunk.used = tick()
  redraw(win)
end
-- Languages that a range parse of lines [first, last] adds as children, or nil when the
-- injection query cannot be read safely. Combined injections make Neovim scan the whole
-- tree, so their languages are collected once for the whole source.
local function injected_languages(e, first, last)
  if e.injections == nil then
    local ok, query = pcall(adapter.injections, e.lang)
    e.injections = ok and query or false
  end
  local query = e.injections
  if not query or #query.captures == 0 then
    return {}
  end
  if e.combined then
    return e.combined
  end
  local full = query.has_combined_injections
  local start, stop
  if not full then
    start, stop = first - 1, last + 1
  end
  local langs, resolved = {}, {}
  for _, match, metadata in query:iter_matches(e.tree:root(), e.text, start, stop) do
    local alias = metadata['injection.language']
    if metadata['injection.self'] ~= nil or metadata['injection.parent'] ~= nil then
      -- A child of the parent's language would run the parent's injection query.
      return
    end
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if name == 'injection.language' or name == 'injection.filename' then
        alias = vim.treesitter.get_node_text(nodes[1], e.text, { metadata = metadata[id] })
        if name == 'injection.filename' then
          alias = vim.filetype.match({ filename = alias })
        end
      end
    end
    if alias and resolved[alias] == nil then
      resolved[alias] = adapter.resolve(alias) or false
    end
    local lang = alias and resolved[alias]
    if lang == e.lang then
      return
    elseif lang then
      langs[lang] = true
    end
  end
  if full then
    e.combined = langs
  end
  return langs
end
-- Ensures injections intersecting lines [first, last] are parsed and returns the trees to
-- extract: the parent tree, then injected trees of admitted languages. A newly seen
-- language loads in its own tick. A language refused by the budget would still be loaded
-- by the range parse, so the chunk keeps parent colors only. Sets progress.busy while a
-- load or parse is pending.
local function inject(e, first, last)
  local trees = { { root = e.tree:root(), query = e.query, lang = e.lang, depth = 0 } }
  local failure_key = e.key .. ':injections'
  if suppressed(cache.failures, failure_key) then
    return trees
  end
  local range = { first - 1, 0, last, 0 }
  if not e.parser:is_valid(false, range) then
    local ok, langs = pcall(injected_languages, e, first, last)
    if not ok then
      record(cache.failures, 'failures', failure_key, 30000)
      return trees
    elseif not langs then
      return trees
    end
    for lang in pairs(langs) do
      if not cache.queries[lang] and not suppressed(cache.missing, lang) then
        if not cache.languages[lang] and counters.languages == limits.languages then
          return trees
        end
        progress.busy = true
        vim.schedule(function()
          progress.busy = false
          admit_language(lang)
          schedule_worker()
        end)
        return trees
      end
    end
    progress.busy, e.active = true, true
    counters.parses = counters.parses + 1
    local done = false
    local function finish(err)
      if done then
        return
      end
      done, progress.busy, e.active = true, false, false
      if err == 'TIMEOUT' then
        backoff(failure_key)
      elseif err then
        record(cache.failures, 'failures', failure_key, 30000)
      end
      schedule_worker()
    end
    local parsed, err = pcall(e.parser.parse, e.parser, range, finish)
    if not parsed then
      finish(err)
    end
    if progress.busy or suppressed(cache.failures, failure_key) then
      return trees
    end
  end
  for lang, child in pairs(e.parser:children()) do
    local query = cache.queries[lang]
    if query then
      for _, tree in pairs(child:trees()) do
        local root = tree:root()
        local sr, _, er = root:range()
        if sr < last and er >= first - 1 then
          trees[#trees + 1] = { root = root, query = query, lang = lang, depth = 1 }
        end
      end
    end
  end
  return trees
end
local BUDGET = {}
-- Extracts one slice of the chunk starting at `first` from `trees` in order. Budgets end
-- a slice early and publish the lines finished in every tree; returns true when the
-- chunk needs no further work. Injected captures rank one priority above the parent.
local function extract(e, snapshot, first, last, win, trees)
  local failure_key = e.key .. ':' .. first
  if suppressed(cache.failures, failure_key) then
    return true
  end
  local chunk = e.chunks[first] or reserve_chunk(last - first + 1, first)
  if not chunk then
    backoff(failure_key)
    return true
  end
  local start, spans, raw, visited, started = chunk.next_line, chunk.spans, chunk.raw, 0, now()
  local stop
  counters.extractions = counters.extractions + 1
  local ok, err = pcall(function()
    for _, tree in ipairs(trees) do
      for id, node, metadata in
        tree.query:iter_captures(tree.root, e.text, start - 1, stop and stop - 1 or last)
      do
        metadata = metadata or {}
        local capture = metadata[id] or {}
        local sr, sc, er, ec = adapter.range(node, e.text, capture)
        visited = visited + 1
        -- Captures starting on the slice's first line always run, so every slice advances.
        if sr + 1 > start and (visited > limits.captures or now() - started > limits.batch_ms) then
          stop = math.min(stop or sr + 1, sr + 1)
          break
        end
        high_water.captures = math.max(high_water.captures or 0, visited)
        local name = tree.query.captures[id]
        if name and name:sub(1, 1) ~= '_' and not capture.conceal and not metadata.conceal then
          local group = intern('@' .. name .. '.' .. tree.lang)
          if not group then
            error(BUDGET)
          end
          local priority = tonumber(capture.priority or metadata.priority) or 100
          if priority ~= priority or math.abs(priority) == math.huge then
            priority = 100
          end
          priority = priority + tree.depth
          for line = math.max(start, sr + 1), math.min(last, er + 1) do
            local length = #snapshot.lines[line]
            local left = line == sr + 1 and math.max(0, sc) or 0
            local right = math.min(length, line == er + 1 and ec or length)
            if length <= limits.line_bytes and right > left then
              if counters.spans >= limits.spans then
                error(BUDGET)
              end
              count('spans', 1)
              local n = #spans
              spans[n + 1], spans[n + 2], spans[n + 3], spans[n + 4], spans[n + 5] =
                line, left, right, group, priority
              raw[#raw + 1] = priority
              chunk.priorities[priority] = true
            end
          end
        end
      end
    end
  end)
  counters.max_batch_ms = math.max(counters.max_batch_ms, now() - started)
  if not ok then
    if e.chunks[first] then
      remove_chunk(e, first)
    else
      release_chunk(chunk)
    end
    counters.dropped = counters.dropped + 1
    if err == BUDGET then
      backoff(failure_key)
    else
      record(cache.failures, 'failures', failure_key, 30000)
    end
    return true
  end
  if stop then
    -- Multiline captures already wrote lines at or after `stop`; the next slice rewrites them.
    drop_lines(chunk, stop)
  else
    remove_record(cache.failures, 'failures', failure_key)
  end
  chunk.next_line = stop or last + 1
  publish_chunk(e, first, chunk, win)
  return not stop
end

-- Buffer names are canonicalized like snapshot paths. Never a pattern lookup:
-- bufnr('a/[id]/x') can match 'a/d/x'.
local function loaded_buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= '' and vim.bo[buf].buftype == '' then
      buffers[scope.path(name)] = buf
    end
  end
  return buffers
end
local function snapshot_language(snapshot, state)
  local lang = state.langs[snapshot]
  if lang ~= nil then
    return lang
  end
  lang = false
  local failure_key = snapshot.hash .. ':filetype'
  if not suppressed(cache.failures, failure_key) then
    local ok, found = pcall(adapter.language, snapshot, function()
      state.buffers = state.buffers or loaded_buffers()
      return state.buffers
    end)
    if not ok then
      record(cache.failures, 'failures', failure_key, 30000)
    elseif type(found) == 'string' and #found <= 128 then
      lang = found
    end
  end
  state.langs[snapshot] = lang
  return lang
end
local function map_row(s, d, row, state)
  local line, snapshot = s.row_lines[row + 1], s.row_snapshots[row + 1]
  if not line or d.rows >= d.budget or counters.rows >= limits.rows then
    return
  end
  local length = #snapshot.lines[line]
  if length > limits.line_bytes or #snapshot.text > s.config.syntax_max_file_bytes then
    return
  end
  local lang = snapshot_language(snapshot, state)
  if not lang then
    return
  end
  -- Chunks with and without injected colors never share an entry.
  local key = snapshot.hash .. ':' .. lang .. (s.config.syntax_injections and ':injections' or '')
  local col, n = s.result_gutters[row + 1], #d.maps
  local extend = n > 0
    and d.maps[n - 1] == key
    and d.maps[n - 4] == col
    and d.maps[n - 6] + #d.maps[n - 3] == row
    and d.maps[n - 5] + #d.maps[n - 3] == line
  if extend then
    local lengths = d.maps[n - 3]
    lengths[#lengths + 1] = length
    d.row_maps[row] = n - 6
  elseif counters.blocks < limits.blocks then
    d.maps[n + 1], d.maps[n + 2], d.maps[n + 3], d.maps[n + 4] = row, line, col, { length }
    d.maps[n + 5], d.maps[n + 6], d.maps[n + 7] = snapshot.path, key, lang
    d.row_maps[row] = n + 1
    count('blocks', 1)
  else
    return
  end
  d.rows = d.rows + 1
  count('rows', 1)
end
-- Reads the render-time row source map: visible rows first, then up to one window
-- height below and above, within the demand's row budget.
local function map_demand(s, d, height)
  if not s.row_lines then
    return
  end
  local state = { langs = {} }
  for _, range in ipairs({
    { d.first, d.last - 1 },
    { d.last, d.last + height - 1 },
    { math.max(0, d.first - height), d.first - 1 },
  }) do
    for row = range[1], range[2] do
      map_row(s, d, row, state)
    end
  end
end

local function collect()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local focused = vim.api.nvim_get_current_win()
  table.sort(wins, function(a, b)
    if a == focused or b == focused then
      return a == focused
    end
    return a < b
  end)
  local visible = {}
  for _, win in ipairs(wins) do
    local s = sessions.by_buf[vim.api.nvim_win_get_buf(win)]
    if
      sessions.owns(s)
      and s.config.syntax_highlighting
      and not s.layout_invalid
      and #visible < limits.demands
    then
      visible[#visible + 1] = win
    end
  end
  local wanted = {}
  for _, win in ipairs(visible) do
    wanted[win] = true
  end
  for win in pairs(viewport.demands) do
    if not wanted[win] then
      drop_demand(win)
    end
  end
  local remaining, ranges = limits.rows, {}
  for index, win in ipairs(visible) do
    local first, last
    vim.api.nvim_win_call(win, function()
      first, last = vim.fn.line('w0') - 1, vim.fn.line('w$')
    end)
    local quota = math.floor(remaining / (#visible - index + 1))
    if index == 1 and #visible > 1 then
      quota = math.min(128, remaining - 16 * (#visible - 1))
    end
    last = math.min(last, first + quota)
    remaining = remaining - (last - first)
    ranges[index] = { first, last }
  end
  -- Rows left after every visible range are shared as overscan.
  local overscan = math.floor(remaining / math.max(1, #visible))
  for index, win in ipairs(visible) do
    local s = sessions.by_buf[vim.api.nvim_win_get_buf(win)]
    local first, last = ranges[index][1], ranges[index][2]
    local old = viewport.demands[win]
    if
      not old
      or old.first ~= first
      or old.last ~= last
      or old.focused ~= (win == focused)
      or not valid(old)
    then
      drop_demand(win)
      viewport.serial = viewport.serial + 1
      viewport.demands[win] = {
        win = win,
        focused = win == focused,
        id = s.id,
        generation = s.generation,
        layout = s.layout_revision,
        first = first,
        last = last,
        budget = last - first + overscan,
        maps = {},
        row_maps = {},
        rows = 0,
        serial = viewport.serial,
        done = false,
        next_map = 1,
        next_line = 0,
      }
      count('demands', 1)
      map_demand(s, viewport.demands[win], vim.api.nvim_win_get_height(win))
    end
  end
  trim_spans()
  schedule_worker()
end

-- Debounces viewport changes; restarting the one timer postpones collection.
function M.request()
  viewport.timer = viewport.timer or vim.uv.new_timer()
  viewport.timer:start(30, 0, vim.schedule_wrap(collect))
end

local function choose_demand()
  local focused, chosen = vim.api.nvim_get_current_win(), nil
  for win, d in pairs(viewport.demands) do
    if not valid(d) then
      drop_demand(win)
    elseif
      not d.done and (not chosen or win == focused or (chosen.win ~= focused and win < chosen.win))
    then
      chosen = d
    end
  end
  return chosen
end

local function enrich_demand(s, d, started)
  while d.next_map <= #d.maps do
    local i = d.next_map
    local snapshot = s.snapshots[d.maps[i + 4]]
    local key, lang = d.maps[i + 5], d.maps[i + 6]
    local e = cache.entries[key]
    local first = d.maps[i + 1] + d.next_line
    if
      snapshot
      and not suppressed(cache.failures, key)
      and not suppressed(cache.failures, key .. ':' .. first)
    then
      local chunk, chunk_start
      if e then
        chunk, chunk_start = chunk_for(e, first)
      end
      if chunk and chunk.next_line >= chunk_start + chunk.lines then
        e.used = tick()
        chunk.used = e.used
        d.next_line = math.min(#d.maps[i + 3], chunk_start + chunk.lines - d.maps[i + 1])
      else
        e = admit(snapshot, lang, key)
        if progress.busy then
          return
        end
        if e and e.tree then
          local last
          if chunk then
            first, last = chunk_start, chunk_start + chunk.lines - 1
          else
            last = math.min(d.maps[i + 1] + #d.maps[i + 3] - 1, first + limits.chunk_lines - 1)
            for line = first + 1, last do
              if e.lines[line] then
                last = line - 1
                break
              end
            end
          end
          local trees = { { root = e.tree:root(), query = e.query, lang = e.lang, depth = 0 } }
          if s.config.syntax_injections then
            trees = inject(e, first, last)
            if progress.busy then
              return
            end
          end
          trim_spans()
          if extract(e, snapshot, first, last, d.win, trees) then
            d.next_line = math.min(#d.maps[i + 3], last - d.maps[i + 1] + 1)
            if d.next_line >= #d.maps[i + 3] then
              d.next_map, d.next_line = i + MAP_WIDTH, 0
            end
          end
          schedule_worker()
          return
        else
          d.next_line = #d.maps[i + 3]
        end
      end
    else
      d.next_line = #d.maps[i + 3]
    end
    if d.next_line >= #d.maps[i + 3] then
      d.next_map, d.next_line = i + MAP_WIDTH, 0
    end
    if now() - started > limits.batch_ms then
      schedule_worker()
      return
    end
  end
  d.done = true
  redraw(d.win)
  schedule_worker()
end

worker = function()
  if progress.busy then
    return
  end
  local d = choose_demand()
  if not d then
    return
  end
  local started, s = now(), sessions.by_id[d.id]
  local info = vim.fn.getwininfo(d.win)[1]
  if not info or info.topline - 1 ~= d.first then
    drop_demand(d.win)
    M.request()
    schedule_worker()
    return
  end
  enrich_demand(s, d, started)
end

function M.invalidate(s)
  drop_demands(s.id)
  redraw()
  M.request()
end
function M.layout_changed(s)
  if s.layout_changed then
    s.layout_changed = nil
    M.invalidate(s)
  end
end
function M.detach(s)
  M.invalidate(s)
  trim_spans()
end
function M.reload()
  cache.revision = cache.revision + 1
  drop_demands()
  cache.queries = {}
  for _, e in pairs(cache.entries) do
    clear_chunks(e)
    local ok, query = pcall(adapter.query, e.lang)
    e.query = ok and query or nil
    e.injections, e.combined = nil, nil
    if not e.query and not e.active then
      evict(e.key)
    end
  end
  clear_records(cache.failures, 'failures')
  clear_records(cache.missing, 'missing')
  redraw()
  M.request()
end
function M.diagnostics()
  local copy = vim.deepcopy(counters)
  copy.limits, copy.busy, copy.query_revision = vim.deepcopy(limits), progress.busy, cache.revision
  copy.high_water = vim.deepcopy(high_water)
  return copy
end

local function runtime_queries_changed()
  if not progress.reload_pending then
    progress.reload_pending = true
    -- Neovim's query-cache OptionSet handler may have been registered after ours.
    vim.schedule(function()
      progress.reload_pending = false
      M.reload()
    end)
  end
end
local function draw_win(_, win, buf, first, last)
  local s = sessions.by_buf[buf]
  if not s or not s.config.syntax_highlighting then
    return false
  end
  local d = viewport.demands[win]
  if not d or not valid(d) or d.first ~= first or d.last < math.min(last, first + 16) then
    -- One debounce request, never a closure retaining the session or snapshot.
    if not (viewport.timer and viewport.timer:is_active()) then
      request_from_redraw()
    end
  end
  return d and valid(d) or false
end

local function draw_line(_, win, buf, row)
  local d = viewport.demands[win]
  if not d or not valid(d) then
    return
  end
  local i = d.row_maps[row]
  if not i then
    return
  end
  local offset = row - d.maps[i]
  local line, col, length = d.maps[i + 1] + offset, d.maps[i + 2], d.maps[i + 3][offset + 1]
  local e = cache.entries[d.maps[i + 5]]
  local chunk = e and chunk_for(e, line)
  local j = chunk and chunk.line_start[line]
  if not j then
    return
  end
  local spans = chunk.spans
  while spans[j] == line do
    local left, right = math.min(length, spans[j + 1]), math.min(length, spans[j + 2])
    if right > left then
      vim.api.nvim_buf_set_extmark(buf, M.namespace, row, col + left, {
        end_col = col + right,
        hl_group = cache.groups[spans[j + 3]],
        priority = spans[j + 4],
        ephemeral = true,
        strict = false,
      })
    end
    j = j + SPAN_WIDTH
  end
end

function M.attach(s)
  if not s.config.syntax_highlighting then
    return
  end
  if not progress.initialized then
    progress.initialized = true
    vim.api.nvim_set_decoration_provider(M.namespace, {
      on_win = draw_win,
      on_line = draw_line,
    })
    local group = vim.api.nvim_create_augroup('SearchlightSyntax', { clear = true })
    vim.api.nvim_create_autocmd(
      { 'WinScrolled', 'WinResized', 'WinEnter', 'BufWinEnter', 'BufWinLeave', 'TabEnter' },
      {
        group = group,
        callback = M.request,
      }
    )
    vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = redraw })
    vim.api.nvim_create_autocmd({ 'FileType', 'OptionSet' }, {
      group = group,
      pattern = '*',
      callback = function(event)
        if event.event == 'FileType' or event.match == 'filetype' then
          for _, session in pairs(sessions.by_id) do
            M.invalidate(session)
          end
        elseif event.match == 'runtimepath' then
          runtime_queries_changed()
        end
      end,
    })
    vim.api.nvim_create_autocmd(
      'User',
      { group = group, pattern = 'SearchlightHighlightReload', callback = M.reload }
    )
  end
  M.request()
end

-- Deterministic adapters/cleanup are deliberately test-only. Diagnostics returns copies.
M._test = {
  reset = function(replacement, overrides)
    assert(not progress.busy, 'cannot reset an in-flight parser')
    drop_demands()
    for key in pairs(cache.entries) do
      evict(key)
    end
    clear_records(cache.failures, 'failures')
    clear_records(cache.missing, 'missing')
    for lang in pairs(cache.languages) do
      release_language(lang)
    end
    cache.queries = {}
    release_groups()
    high_water = {}
    limits = vim.deepcopy(default_limits)
    for name, value in pairs(overrides or {}) do
      assert(
        default_limits[name] and value > 0 and value <= default_limits[name],
        'test budgets may only shrink'
      )
      limits[name] = value
    end
    adapter = replacement and vim.tbl_extend('force', default_adapter, replacement)
      or default_adapter
  end,
  collect = collect,
  groups = function()
    return vim.deepcopy(cache.group_ids)
  end,
  demands = function()
    return vim.deepcopy(viewport.demands)
  end,
  entries = function()
    local copy = {}
    for key, e in pairs(cache.entries) do
      copy[key] = {
        lang = e.lang,
        chunks = vim.deepcopy(e.chunks),
        active = e.active,
        text = e.text ~= nil,
      }
    end
    return copy
  end,
}
return M
