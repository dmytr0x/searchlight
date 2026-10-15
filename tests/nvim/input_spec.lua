local H = require('tests.helpers')
local p = require('searchlight')
local input = require('searchlight.input')

H.test('context input validates nonnegative whole numbers', 'API,Q-06', function()
  assert(input.valid_context_size(0))
  assert(input.valid_context_size(3))
  for _, value in ipairs({ -1, 0.5, math.huge, '2', false }) do
    assert(not input.valid_context_size(value))
  end
  assert(not input.valid_context_size(nil))
end)

H.test('controller updates modifier controls and context together', 'API,Q-06', function()
  local a = H.fixture()
  H.write(a .. '/one', 'abc ABC\n')
  local s = H.search(a)
  p.set(s, { case = true, context = 0 })
  local read = require('searchlight.view').read(s)
  H.eq(read.options.case, true)
  H.eq(read.options.context, 0)
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(#s.results, 1)
  H.eq(s.options.case, true)
  H.eq(s.options.context, 0)
end)

H.test(
  'input candidates copy and classify session configuration without mutation',
  'API,Validation',
  function()
    local sessions = require('searchlight.sessions')
    local initial = sessions.initial('/old', p.config, 'replace')
    local before = vim.deepcopy(initial)
    local changes = {
      query = '',
      replacement = '',
      include = { '*.lua', '*.md' },
      exclude = {},
      case = false,
      word = true,
      regex = false,
      open = false,
      ignored = true,
      context = 0,
      root = '/new',
      max_results = 2,
      close_on_open = true,
      sections = { filters = false, replace = false, help = true },
    }
    local candidate = input.update(initial, changes, function(path)
      return path .. '/normalized'
    end)
    H.eq(initial, before)
    H.eq(candidate.root, '/new/normalized')
    H.eq(candidate.config.max_results, 2)
    H.eq(candidate.config.close_on_open, true)
    H.eq(candidate.options.context, 0)
    H.eq(candidate.sections, changes.sections)
    H.eq(candidate.search_changed, true)
    H.eq(candidate.presentation_changed, true)
    changes.include[1], changes.sections.help = 'changed', false
    H.eq(candidate.fields.include, { '*.lua', '*.md' })
    H.eq(candidate.sections.help, true)
    local presentation = input.update(
      initial,
      { sections = { help = false }, close_on_open = true },
      function(v)
        return v
      end
    )
    H.eq(presentation.search_changed, false)
    H.eq(presentation.presentation_changed, true)
    H.eq(presentation.sections.filters, true)
    H.eq(presentation.sections.replace, true)
  end
)

H.test(
  'input rejects malformed tables, nonfinite numbers and unsupported values atomically',
  'API,Validation',
  function()
    local initial = require('searchlight.sessions').initial('/', p.config, 'replace')
    local before = vim.deepcopy(initial)
    for _, patch in ipairs({
      false,
      1,
      'query',
      { query = 'valid', include = { [2] = '*.lua' } },
      { include = { '*.lua', extra = '*.md' } },
      { include = { [0] = '*.lua' } },
      { include = { [1.5] = '*.lua' } },
      { include = { '*.lua', false } },
      { exclude = { 'a\nb' } },
      { include = 'lua' },
      { query = 'a\rb' },
      { replacement = 1 },
      { case = 0 },
      { word = 'true' },
      { regex = {} },
      { open = 1 },
      { ignored = 'false' },
      { context = 0 / 0 },
      { max_results = math.huge },
      { max_results = -math.huge },
      { max_results = 0 / 0 },
      { max_results = 0 },
      { max_results = -1 },
      { max_results = 1.5 },
      { max_results = '2' },
      { close_on_open = 1 },
      { root = false },
      { sections = false },
      { sections = { filters = 1 } },
      { sections = { unknown = true } },
      { sections = { [1] = true } },
      { mode = 'search' },
      { [false] = 'unknown' },
    }) do
      H.eq(
        pcall(input.update, initial, patch, function(v)
          return v
        end),
        false,
        vim.inspect(patch)
      )
      H.eq(initial, before)
    end
    local search = require('searchlight.sessions').initial('/', p.config, 'search')
    for _, patch in ipairs({
      { replacement = '' },
      { sections = { replace = false } },
      { sections = { replace = true } },
    }) do
      H.eq(
        pcall(input.update, search, patch, function(v)
          return v
        end),
        false
      )
    end
  end
)

H.test(
  'execution policy validates outer tables, keys and exact values',
  'API,Validation',
  function()
    H.eq(input.execution(nil, false), false)
    H.eq(input.execution({}, 'debounced'), 'debounced')
    for _, policy in ipairs({ false, 'debounced', 'immediate' }) do
      H.eq(input.execution({ refresh = policy }, false), policy)
    end
    for _, value in ipairs({
      false,
      1,
      'immediate',
      { refresh = true },
      { refresh = 'later' },
      { unknown = false },
    }) do
      H.eq(pcall(input.execution, value, false), false)
    end
  end
)
