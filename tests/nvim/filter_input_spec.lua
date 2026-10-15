local shared = require('tests.helpers')
for _, mode in ipairs({ 'search', 'replace' }) do
  local function test(name, requirements, run)
    shared.test(mode .. ': ' .. name, requirements, run)
  end
  local H = require('tests.helpers')
  local p = require('searchlight')
  local view = require('searchlight.view')

  local function keys(text)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
  end

  local function lines(s, field)
    local region = s.regions[field]
    return vim.api.nvim_buf_get_lines(s.buf, region.start, region.stop, false)
  end

  for _, field in ipairs({ 'include', 'exclude' }) do
    test(
      field .. ' preserves a trailing space after a glob through refresh',
      'Q-01,Q-05',
      function()
        local a = H.fixture()
        H.write(a .. '/one.lua', 'abc\n')
        local s = H[mode](a, { query = 'abc', [field] = { '*.lua' } })
        view.focus_field(s, field)
        local region = s.regions[field]
        vim.api.nvim_buf_set_text(s.buf, region.start, #'*.lua', region.start, #'*.lua', { ' ' })
        vim.api.nvim_exec_autocmds('TextChangedI', { buffer = s.buf })
        vim.wait(100)
        view.render(s)
        region = s.regions[field]
        H.eq(vim.api.nvim_buf_get_lines(s.buf, region.start, region.stop, false), { '*.lua ' })
        H.eq(s.fields[field], { '*.lua ' })
      end
    )

    test(
      field .. ' accepts incremental keyboard spaces and comma-separated globs',
      'Q-01,Q-05',
      function()
        local a = H.fixture()
        H.write(a .. '/one.lua', 'abc\n')
        H.write(a .. '/two.txt', 'abc\n')
        H.write(a .. '/three.md', 'abc\n')
        local s = H[mode](a, { query = 'abc', [field] = { '*.lua' } })
        view.focus_field(s, field)
        for _, suffix in ipairs({ ' ', ' ', ', ', '*.txt' }) do
          keys('A' .. suffix .. '<Esc>')
          vim.wait(50)
          view.render(s)
        end
        H.eq(lines(s, field), { '*.lua  , *.txt' })
        H.eq(s.fields[field], { '*.lua  , *.txt' })
        keys('<CR>')
        H.wait(s, 'complete')
        H.eq(#s.results, field == 'include' and 2 or 1)
      end
    )

    test(
      field .. ' retains whitespace and blank lines while searches parse globs',
      'Q-01,Q-05,Q-06',
      function()
        local a = H.fixture()
        H.write(a .. '/one.lua', 'abc\n')
        H.write(a .. '/two.txt', 'abc\n')
        H.write(a .. '/three.md', 'abc\n')
        local s = H[mode](a)
        local input = { '', ' \t*.lua  , ', ' \t ', '\t*.txt\t', '' }
        local region = s.regions[field]
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, input)
        vim.api.nvim_exec_autocmds('TextChangedI', { buffer = s.buf })
        p.refresh(s)
        H.wait(s, 'complete')
        H.eq(#s.results, field == 'include' and 2 or 1)
        H.eq(lines(s, field), input)
        p.action(s, 'section', 'filters')
        p.action(s, 'section', 'filters')
        p.refresh(s)
        H.wait(s, 'complete')
        H.eq(lines(s, field), input)
        H.eq(s.fields[field], input)

        -- Validation reports errors without erasing unfinished/invalid declarations.
        input = { '  *.lua, !  ', '', '\t' }
        region = s.regions[field]
        vim.api.nvim_buf_set_lines(s.buf, region.start, region.stop, false, input)
        vim.api.nvim_exec_autocmds('TextChangedI', { buffer = s.buf })
        p.refresh(s)
        H.wait(s, 'error')
        H.eq(lines(s, field), input)
        H.eq(s.fields[field], input)
      end
    )
  end
end
