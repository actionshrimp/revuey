-- Projected syntax highlighting: async parsing, capture extraction limited to hunk rows.
-- Uses the Lua parser and queries bundled with Neovim, so it never skips.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local syntax = require('revuey.syntax')

local function big_lua(n)
  local parts = {}
  for i = 1, n do
    parts[#parts + 1] = ('local function f%d(a) return "x%d" .. tostring(a) end'):format(i, i)
  end
  return table.concat(parts, '\n') .. '\n'
end

-- Regression (finding 3): a whole-blob synchronous parse + capture walk froze the UI for >1s on
-- 20k-line files. Parsing must be asynchronous and captures limited to the requested rows.
h.test('highlight_async does not block and only returns requested rows', function()
  local text = big_lua(20000)
  local done, rows
  local t0 = vim.uv.hrtime()
  syntax.highlight_async(text, 'lua', { { 10000, 10003 } }, function(r)
    done, rows = true, r
  end)
  local sync_ms = (vim.uv.hrtime() - t0) / 1e6
  h.ok(sync_ms < 150, ('synchronous part took %.0fms'):format(sync_ms))
  vim.wait(10000, function()
    return done
  end, 5)
  h.ok(done, 'callback ran')
  local keys = vim.tbl_keys(rows)
  table.sort(keys)
  h.eq({ 10000, 10001, 10002 }, keys)
  local groups = {}
  for _, sp in ipairs(rows[10000]) do
    groups[sp[3]] = true
  end
  h.ok(groups['@keyword.function.lua'] or groups['@keyword.lua'], vim.inspect(groups))
end)

h.test('large ranges are highlighted in chunks without gaps at chunk boundaries', function()
  local text = big_lua(5000)
  local rows
  syntax.highlight_async(text, 'lua', { { 0, 5000 } }, function(r)
    rows = r
  end)
  vim.wait(20000, function()
    return rows ~= nil
  end, 5)
  h.ok(rows, 'callback ran')
  for _, r in ipairs({ 0, 999, 1000, 1001, 2500, 4999 }) do
    h.ok(rows[r] and #rows[r] > 0, 'no spans on row ' .. r)
  end
  h.eq(nil, rows[5000])
end)

-- Regression (review 2): many hunks must not rescan every range per capture.
h.test('collect over 1000 small ranges is fast', function()
  local text = big_lua(20000)
  local p = vim.treesitter.get_string_parser(text, 'lua')
  p:parse(true)
  local ranges = {}
  for i = 0, 19999, 20 do
    ranges[#ranges + 1] = { i, i + 7 }
  end
  local t0 = vim.uv.hrtime()
  local rows = syntax.collect(p, text, ranges)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  h.ok(ms < 1500, ('took %.0fms'):format(ms))
  h.ok(rows[0] and rows[6] and not rows[7] and rows[20], 'rows limited to ranges')
end)

---Lua source whose multi-line constructs (long comments, long strings holding code-like text)
---are long enough to straddle chunk boundaries at any chunk size.
local function tricky_lua(target)
  local L = {}
  local i = 0
  while #L < target do
    i = i + 1
    L[#L + 1] = '--[[ block comment ' .. i
    for k = 1, 140 + (i % 7) * 13 do
      L[#L + 1] = ('local not_code_%d = "%d" -- inside a comment'):format(k, k)
    end
    L[#L + 1] = ']]'
    L[#L + 1] = ('local function f%d(a)'):format(i)
    L[#L + 1] = '  local s = [=['
    for k = 1, 230 + (i % 5) * 17 do
      L[#L + 1] = ('    if x then return "%d" end -- string, not code ]]'):format(k)
    end
    L[#L + 1] = '  ]=]'
    for k = 1, 40 do
      L[#L + 1] = ('  if a > %d then return s .. "%d" end'):format(k, k)
    end
    L[#L + 1] = 'end'
  end
  return table.concat(L, '\n') .. '\n', #L
end

local function span_key(spans)
  local o = {}
  for _, x in ipairs(spans or {}) do
    o[#o + 1] = x[1] .. '-' .. x[2] .. x[3] .. x[4]
  end
  table.sort(o)
  return table.concat(o, ' ')
end

local function chunked(text, ranges)
  local rows
  syntax.highlight_async(text, 'lua', ranges, function(r, err)
    rows = r or { err = err }
  end)
  vim.wait(60000, function()
    return rows ~= nil
  end, 2)
  return rows
end

-- Regression (final review, medium): chunk context starting inside a long comment/string
-- inverted code and strings for whole chunks. Chunked results must equal a whole-file parse.
h.test('chunked highlighting equals whole-file highlighting across straddling constructs', function()
  local text, n = tricky_lua(6000)
  local p = vim.treesitter.get_string_parser(text, 'lua')
  p:parse(true)
  local ref = syntax.collect(p, text, { { 0, n } })
  local got = chunked(text, { { 0, n } })
  h.ok(not got.err, tostring(got.err))
  local bad = {}
  for r = 0, n - 1 do
    if span_key(got[r]) ~= span_key(ref[r]) then
      bad[#bad + 1] = r
    end
  end
  h.eq({}, vim.list_slice(bad, 1, 5), ('%d of %d rows differ'):format(#bad, n))
  -- partial ranges far from the start match too
  local part = chunked(text, { { 3000, 3010 }, { 5200, 5300 } })
  for _, r in ipairs({ 3000, 3009, 5200, 5299 }) do
    h.eq(span_key(ref[r]), span_key(part[r]), 'row ' .. r)
  end
  h.eq(nil, part[2999])
  h.eq(nil, part[3010])
end)

h.test('waiters are not duplicated by repeated redraws while loading', function()
  local repo = h.repo('waiters', { ['a.lua'] = 'local x = 1\n' }, { ['a.lua'] = 'local x = 2\n' })
  local r = assert(require('revuey.review').load({ cwd = repo, base = 'main', state_dir = h.tmpdir('w-state') }))
  local f = r.files[1]
  local c
  for _ = 1, 10 do
    c = syntax.get(r.root, f, 'new', function() end, 'buf1')
  end
  h.ok(c.status ~= 'loading' or vim.tbl_count(c.waiters) == 1, vim.inspect(c.waiters and vim.tbl_count(c.waiters)))
  syntax.load_sync(r.root, f, 'new')
  syntax.clear_cache()
end)

h.test('hunk_ranges covers old and new sides of each hunk', function()
  local f = {
    hunks = {
      { old_start = 3, old_count = 2, new_start = 3, new_count = 4, lines = {} },
      { old_start = 40, old_count = 0, new_start = 42, new_count = 1, lines = {} },
    },
  }
  h.eq({ { 2, 4 } }, syntax.hunk_ranges(f, 'old'))
  h.eq({ { 2, 6 }, { 41, 42 } }, syntax.hunk_ranges(f, 'new'))
end)

h.test('unknown languages degrade to nil', function()
  h.eq(nil, syntax.lang_for_path('x.unknown-ext'))
  h.eq('lua', syntax.lang_for_path('a.lua'))
end)

h.run()
