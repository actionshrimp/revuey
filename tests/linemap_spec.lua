-- Line-number mapping between two versions of a file (HEAD blob <-> working tree buffer).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local linemap = require('revuey.linemap')

local function lines(n, f)
  local t = {}
  for i = 1, n do
    t[i] = f and f(i) or ('line ' .. i)
  end
  return table.concat(t, '\n') .. '\n'
end

h.test('identical texts map 1:1', function()
  local m = linemap.new(lines(10), lines(10))
  h.eq(1, m(1))
  h.eq(10, m(10))
  h.eq(nil, m(11))
end)

h.test('insertions and deletions shift lines; changed lines map to nil', function()
  local a = lines(10)
  -- b: two lines inserted at top, line 5 changed, line 8 deleted
  local t = vim.split(a, '\n', { plain = true })
  table.remove(t) -- trailing ''
  t[5] = 'CHANGED'
  table.remove(t, 8)
  table.insert(t, 1, 'new a')
  table.insert(t, 1, 'new b')
  local b = table.concat(t, '\n') .. '\n'
  local m = linemap.new(a, b)
  h.eq(3, m(1))
  h.eq(6, m(4))
  h.eq(nil, m(5), 'changed line')
  h.eq(8, m(6))
  h.eq(nil, m(8), 'deleted line')
  h.eq(10, m(9))
  h.eq(11, m(10))
  -- reverse direction
  local r = linemap.new(b, a)
  h.eq(nil, r(1), 'inserted line has no HEAD counterpart')
  h.eq(1, r(3))
  h.eq(9, r(10))
  h.eq(10, r(11))
end)

h.test('duplicate lines are mapped by position, not by text', function()
  local a = lines(60, function(i)
    return (i == 5 or i == 50) and 'export function render() {' or ('const v' .. i)
  end)
  local b = '// x\n// y\n' .. a
  local m = linemap.new(b, a) -- working tree -> HEAD
  h.eq(5, m(7))
  h.eq(50, m(52))
end)

h.test('CRLF and a missing final newline do not shift lines', function()
  local m = linemap.new('a\r\nb\r\nc', 'a\nb\nc\n')
  h.eq(1, m(1))
  h.eq(3, m(3))
end)


-- Regression (final review, low): forward and reverse maps must agree (one diff for both).
h.test('round trips are exact (randomised)', function()
  math.randomseed(42)
  for iter = 1, 2000 do
    local a = {}
    for i = 1, math.random(0, 30) do
      a[i] = 'l' .. math.random(1, 6)
    end
    local b = vim.deepcopy(a)
    for _ = 1, math.random(0, 5) do
      local op, pos = math.random(3), math.random(1, #b + 1)
      if op == 1 then
        table.insert(b, pos, 'n' .. math.random(1, 3))
      elseif op == 2 and #b > 0 then
        table.remove(b, math.min(pos, #b))
      elseif #b > 0 then
        b[math.min(pos, #b)] = 'c' .. math.random(9)
      end
    end
    local at = table.concat(a, '\n') .. (#a > 0 and '\n' or '')
    local bt = table.concat(b, '\n') .. (#b > 0 and '\n' or '')
    local fwd, rev = linemap.both(at, bt)
    local prev = 0
    for l = 1, #a do
      local m = fwd(l)
      if m then
        h.eq(a[l], b[m], 'text, iter ' .. iter)
        h.ok(m > prev, 'monotonic, iter ' .. iter)
        h.eq(l, rev(m), 'round trip, iter ' .. iter)
        prev = m
      end
    end
    for m = 1, #b do
      local l = rev(m)
      if l then
        h.eq(m, fwd(l), 'reverse round trip, iter ' .. iter)
      end
    end
  end
end)

h.run()
