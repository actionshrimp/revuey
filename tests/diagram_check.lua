-- Property checker for diagram.render (used by diagram_spec's fuzz test; adapted from the review's
-- fuzz script). Reads the drawing back from its text: every line fits the width, every node is one
-- intact box, and every edge, traced cell by cell from its port, reaches the right box at an arrow
-- without merging into another line (no T-junctions in the gaps).
local dg = require('revuey.diagram')
local W = vim.api.nvim_strwidth

local M = {}

local function cells(line)
  local out = {}
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    local w = W(ch)
    if w == 0 and #out > 0 then
      out[#out] = out[#out] .. ch
    else
      out[#out + 1] = ch
      for _ = 2, w do
        out[#out + 1] = ''
      end
    end
  end
  return out
end

local DIRS = { down = { 1, 0 }, up = { -1, 0 }, left = { 0, -1 }, right = { 0, 1 } }
local TURN = {
  ['╰'] = { down = 'right', left = 'up' },
  ['╯'] = { down = 'left', right = 'up' },
  ['╭'] = { up = 'right', left = 'down' },
  ['╮'] = { up = 'left', right = 'down' },
}

---@return string[] errors (empty when the drawing is sound)
function M.check(d, width, opts)
  opts = opts or {}
  local errs = {}
  local out = dg.render(d, width)
  local function err(kind)
    errs[#errs + 1] = kind .. '\n' .. table.concat(out.lines, '\n')
  end
  if not vim.deep_equal(out, dg.render(d, width)) then
    err('nondeterministic')
  end
  for _, l in ipairs(out.lines) do
    if W(l) > width then
      err('line wider than ' .. width .. ': ' .. l)
      break
    end
  end
  if out.mode == 'list' then
    return errs, out
  end
  local G = {}
  for y, l in ipairs(out.lines) do
    G[y] = cells(l)
  end
  local function at(y, x)
    return G[y] and G[y][x] or ' '
  end
  local HL = {}
  for _, sp in ipairs(out.hls) do
    local line = out.lines[sp[1]]
    for x = W(line:sub(1, sp[2])) + 1, W(line:sub(1, sp[3])) do
      HL[sp[1] .. ':' .. x] = sp[4]
    end
  end
  local boxes, owner = {}, {}
  for y = 1, #G do
    for x = 1, #G[y] do
      local hl = HL[y .. ':' .. x] or ''
      if G[y][x] == '╭' and hl:match('^RevueyDiagram') and hl ~= 'RevueyDiagramEdge' then
        local x1 = x + 1
        while at(y, x1) == '─' or at(y, x1) == '┴' do
          x1 = x1 + 1
        end
        if at(y, x1) ~= '╮' or at(y + 1, x) ~= '│' or at(y + 1, x1) ~= '│' or at(y + 2, x) ~= '╰' or at(y + 2, x1) ~= '╯' then
          err('broken box')
        else
          local b = { y = y, x0 = x, x1 = x1 }
          boxes[#boxes + 1] = b
          for yy = y, y + 2 do
            for xx = x, x1 do
              if owner[yy .. ':' .. xx] then
                err('overlapping boxes')
              end
              owner[yy .. ':' .. xx] = b
            end
          end
        end
      end
    end
  end
  for _, sp in ipairs(out.nodes) do
    local b = owner[sp[1] .. ':' .. (W(out.lines[sp[1]]:sub(1, sp[2])) + 1)]
    if not b then
      err('node span not on a box')
    else
      b.id = sp[4]
    end
  end
  if #boxes ~= #d.nodes then
    err(('%d boxes for %d nodes'):format(#boxes, #d.nodes))
  end
  local traced = {}
  local function trace(y, x, dir, src)
    for _ = 1, 10000 do
      y, x = y + DIRS[dir][1], x + DIRS[dir][2]
      local ch = at(y, x)
      if owner[y .. ':' .. x] then
        return err('line enters a box without an arrow')
      elseif ch == '│' then
        if dir ~= 'up' and dir ~= 'down' then
          return err('bad join')
        end
      elseif ch == '─' then
        if dir ~= 'left' and dir ~= 'right' then
          return err('bad join')
        end
      elseif ch == '┼' then -- a crossing: go straight on
      elseif TURN[ch] then
        dir = TURN[ch][dir]
        if not dir then
          return err('bad corner')
        end
      elseif ch == '▼' or ch == '▲' then
        local down = ch == '▼'
        if dir ~= (down and 'down' or 'up') then
          return err('arrow points the wrong way')
        end
        local b = owner[(y + (down and 1 or -1)) .. ':' .. x]
        if not b then
          return err('arrow to nothing')
        end
        return src.id .. '>' .. b.id
      elseif ch == '├' or ch == '┤' or ch == '┬' or ch == '┴' then
        return err('T-junction in a gap: two lines merge')
      else
        return err('line runs into [' .. ch .. ']')
      end
    end
    err('trace loop')
  end
  for _, b in ipairs(boxes) do
    for xx = b.x0, b.x1 do
      if at(b.y + 2, xx) == '┬' then
        traced[#traced + 1] = trace(b.y + 2, xx, 'down', b)
      end
      if at(b.y, xx) == '┴' then
        traced[#traced + 1] = trace(b.y, xx, 'up', b)
      end
    end
  end
  local exp = {}
  for _, e in ipairs(d.edges) do
    exp[#exp + 1] = e.from .. '>' .. e.to
  end
  table.sort(exp)
  table.sort(traced)
  if not vim.deep_equal(exp, traced) then
    err('traced edges ' .. table.concat(traced, ' ') .. ' ~= ' .. table.concat(exp, ' '))
  end
  if opts.labels then
    local all = table.concat(out.lines, '\n')
    for _, e in ipairs(d.edges) do
      if e.label and not all:find(e.label, 1, true) then
        err('edge label missing: ' .. e.label)
      end
    end
  end
  return errs, out
end

return M
