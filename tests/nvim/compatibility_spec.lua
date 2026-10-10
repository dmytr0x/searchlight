local H = require('tests.helpers')
local p = require('searchlight')

H.test('session input helpers retain their callable compatibility contract', 'API,Q-06', function()
  local sessions = require('searchlight.sessions')
  H.eq(sessions.option_settings, {
    case = 'match_case_sensetivity',
    word = 'match_whole_words',
    regex = 'use_regular_expressions',
    open = 'only_search_open_files',
    ignored = 'also_search_ignored_files',
  })
  assert(sessions.valid_context_size(0))
  assert(sessions.valid_context_size(3))
  for _, value in ipairs({ -1, 0.5, math.huge, '2', false }) do
    assert(not sessions.valid_context_size(value))
  end
  assert(not sessions.valid_context_size(nil))

  local a = H.fixture()
  H.write(a .. '/one', 'abc ABC\n')
  local s = H.search(a)
  local view = require('searchlight.view')
  view.set_options(s, { case = true, context = 0 })
  view.render(s)
  H.eq(view.read_options(s).case, true)
  H.eq(view.read_options(s).context, 0)
  p.refresh(s)
  H.wait(s, 'complete')
  H.eq(#s.results, 1)
  H.eq(s.options.case, true)
  H.eq(s.options.context, 0)
end)

H.test(
  'replacement selection and capture preview remain callable after migration',
  'API,R-01',
  function()
    local a = H.fixture()
    H.write(a .. '/one', '雪 abc abc\n')
    local s = H.search(a, { query = 'a(b)c', replacement = '$1!', regex = true })
    local replace = require('searchlight.replace')
    local result, index = replace.selected(s)
    H.eq(index, 1)
    assert(result == s.results[1])
    H.eq(replace.preview(result), '雪 b! abc')
    p.navigate(s, 1)
    result, index = replace.selected(s)
    H.eq(index, 2)
    assert(result == s.results[2])
    H.eq(replace.preview(result), '雪 abc b!')
    require('searchlight.search').invalidate(s, 'compatibility check', false)
    H.eq(replace.preview(result), nil)
    s.selected = nil
    H.eq(replace.selected(s), nil)
    H.eq(replace.preview(nil), nil)
  end
)
