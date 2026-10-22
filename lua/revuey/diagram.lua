-- Overview diagram of a guide (pure, deterministic): the model returns nodes and edges, never
-- drawings (models align box art badly), and this module lays them out and draws them.
--
--   * `render(d, width)` -> lines + highlight spans + node spans. A small layered (Sugiyama-style)
--     layout, top to bottom: ranks by longest path (cycles broken by a DFS that reverses back
--     edges), long edges split by dummy points, two barycenter sweep pairs to reduce crossings
--     (the best order seen wins), x placement that centres nodes over their neighbours, then
--     edges routed through the gap between ranks on horizontal tracks (one track per edge that
--     changes column, ordered so a line never runs along another), labels put next to the
--     arrow where they fit (else listed under the diagram).
--   * When a rank does not fit `width`, the compact list form: `A ──calls──▶ B`.
--   * `mermaid(d)`: Mermaid flowchart text of the same data (for image rendering elsewhere).
-- `d` is a validated diagram (guide.validate_diagram): {nodes = {{id, label, kind, section?}},
-- edges = {{from, to, label?}}}, ids unique, edges between known nodes, no self loops.
local M = {}

local strwidth = vim.api.nvim_strwidth

M.KIND_HL = { new = 'RevueyDiagramNew', changed = 'RevueyDiagramChanged', context = 'RevueyDiagramContext' }
M.EDGE_HL = 'RevueyDiagramEdge'
M.LABEL_HL = 'RevueyDiagramLabel'
M.KINDS = { 'new', 'changed', 'context' }

local MIN_GAP, MAX_GAP = 2, 4 -- columns between neighbouring items of a rank

local function chars(s)
  return vim.fn.split(s, '\\zs')
end

---Shorten `s` to at most `max` display cells, ending in "…" when cut.
function M.truncate(s, max)
  if strwidth(s) <= max then
    return s
  end
  local out, w = {}, 0
  for _, ch in ipairs(chars(s)) do
    local cw = strwidth(ch)
    if w + cw > max - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. '…'
end

-- ---------------------------------------------------------------------------
-- Graph: cycle breaking, ranks, dummies, order
-- ---------------------------------------------------------------------------

local function graph(d)
  local idx = {}
  for i, n in ipairs(d.nodes) do
    idx[n.id] = i
  end
  local edges = {}
  for _, e in ipairs(d.edges) do
    local u, v = idx[e.from], idx[e.to]
    if u and v and u ~= v then
      edges[#edges + 1] = { u = u, v = v, label = e.label }
    end
  end
  return edges
end

---Back edges of a DFS (sources first, then node order) are reversed for the layout.
local function break_cycles(n, edges)
  local out, indeg = {}, {}
  for i = 1, n do
    out[i], indeg[i] = {}, 0
  end
  for ei, e in ipairs(edges) do
    table.insert(out[e.u], ei)
    indeg[e.v] = indeg[e.v] + 1
  end
  local st = {}
  local function dfs(u)
    st[u] = 1
    for _, ei in ipairs(out[u]) do
      local v = edges[ei].v
      if st[v] == 1 then
        edges[ei].reversed = true
      elseif not st[v] then
        dfs(v)
      end
    end
    st[u] = 2
  end
  for u = 1, n do
    if indeg[u] == 0 and not st[u] then
      dfs(u)
    end
  end
  for u = 1, n do
    if not st[u] then
      dfs(u)
    end
  end
  for _, e in ipairs(edges) do
    -- layout direction: a -> b (top to bottom)
    if e.reversed then
      e.a, e.b = e.v, e.u
    else
      e.a, e.b = e.u, e.v
    end
  end
end

---Longest-path ranks; sources are then pulled down next to their highest successor.
local function ranks_of(n, edges)
  local preds, succs, indeg = {}, {}, {}
  for i = 1, n do
    preds[i], succs[i], indeg[i] = {}, {}, 0
  end
  for _, e in ipairs(edges) do
    table.insert(preds[e.b], e.a)
    table.insert(succs[e.a], e.b)
    indeg[e.b] = indeg[e.b] + 1
  end
  local order, rank = {}, {}
  local ready = {}
  for i = 1, n do
    if indeg[i] == 0 then
      ready[#ready + 1] = i
    end
  end
  while #ready > 0 do
    table.sort(ready)
    local u = table.remove(ready, 1)
    order[#order + 1] = u
    rank[u] = rank[u] or 0
    for _, v in ipairs(succs[u]) do
      rank[v] = math.max(rank[v] or 0, rank[u] + 1)
      indeg[v] = indeg[v] - 1
      if indeg[v] == 0 then
        ready[#ready + 1] = v
      end
    end
  end
  for i = #order, 1, -1 do
    local u = order[i]
    if #preds[u] == 0 and #succs[u] > 0 then
      local m = math.huge
      for _, v in ipairs(succs[u]) do
        m = math.min(m, rank[v])
      end
      rank[u] = m - 1
    end
  end
  return rank
end

local function crossings(segs_between, pos)
  local c = 0
  for i = 1, #segs_between do
    local a = segs_between[i]
    for j = i + 1, #segs_between do
      local b = segs_between[j]
      local d1, d2 = pos[a.from] - pos[b.from], pos[a.to] - pos[b.to]
      if d1 * d2 < 0 then
        c = c + 1
      end
    end
  end
  return c
end

-- ---------------------------------------------------------------------------
-- Drawing grid
-- ---------------------------------------------------------------------------

local U, D, L, R = 1, 2, 4, 8
local LINE = {
  [U + D] = '│', [L + R] = '─', [D + R] = '╭', [D + L] = '╮', [U + R] = '╰', [U + L] = '╯',
  [U + D + R] = '├', [U + D + L] = '┤', [L + R + D] = '┬', [L + R + U] = '┴', [U + D + L + R] = '┼',
  [U] = '│', [D] = '│', [L] = '─', [R] = '─',
}

local function new_grid()
  return { rows = {} }
end

local function cell(g, y, x)
  local row = g.rows[y]
  if not row then
    row = {}
    g.rows[y] = row
  end
  local c = row[x]
  if not c then
    c = {}
    row[x] = c
  end
  return c
end

local function put(g, y, x, ch, hl)
  local c = cell(g, y, x)
  c.ch, c.hl, c.mask = ch, hl, nil
end

local function line_mask(g, y, x, mask)
  local c = cell(g, y, x)
  if c.ch then
    return
  end
  c.mask = (c.mask or 0) + 0
  -- bitwise or without the bit library
  local m = c.mask
  for _, b in ipairs({ U, D, L, R }) do
    if mask % (b * 2) >= b and m % (b * 2) < b then
      m = m + b
    end
  end
  c.mask, c.hl = m, M.EDGE_HL
end

local function free(g, y, x)
  local row = g.rows[y]
  local c = row and row[x]
  return not c or (not c.ch and not c.mask)
end

---Grid -> lines (right-trimmed), highlight spans and byte offsets per cell.
local function flush(g, height, width)
  local lines, hls, bytes = {}, {}, {}
  for y = 0, height - 1 do
    local parts, off, colb = {}, 0, {}
    local row = g.rows[y] or {}
    local last = -1
    for x = 0, width - 1 do
      local c = row[x]
      if c and (c.ch or c.mask) and c.ch ~= ' ' then
        last = x
      end
    end
    local run_hl, run_s
    for x = 0, last do
      local c = row[x]
      local ch = c and (c.ch or (c.mask and LINE[c.mask])) or ' '
      local hl = c and (c.ch or c.mask) and c.hl or nil
      colb[x] = off
      if hl ~= run_hl then
        if run_hl then
          hls[#hls + 1] = { y + 1, run_s, off, run_hl }
        end
        run_hl, run_s = hl, off
      end
      parts[#parts + 1] = ch
      off = off + #ch
    end
    if run_hl then
      hls[#hls + 1] = { y + 1, run_s, off, run_hl }
    end
    colb[last + 1] = off
    lines[y + 1] = table.concat(parts)
    bytes[y] = colb
  end
  return lines, hls, bytes
end

---Write text at (y, x); wide characters take two cells (the second is empty).
local function text_at(g, y, x, s, hl)
  for _, ch in ipairs(chars(s)) do
    put(g, y, x, ch, hl)
    local w = strwidth(ch)
    for k = 1, w - 1 do
      put(g, y, x + k, '', hl)
    end
    x = x + w
  end
  return x
end

-- ---------------------------------------------------------------------------
-- Legend and list form
-- ---------------------------------------------------------------------------

local function legend(d)
  local used = {}
  for _, n in ipairs(d.nodes) do
    used[n.kind] = true
  end
  local text, hls = '', {}
  for _, k in ipairs(M.KINDS) do
    if used[k] then
      if text ~= '' then
        text = text .. '  '
      end
      local s = #text
      text = text .. '■ ' .. k
      hls[#hls + 1] = { s, #text, M.KIND_HL[k] }
    end
  end
  return text, hls
end

---Compact list form: one line per edge (`A ──label──▶ B`), then nodes without edges.
---@return {lines:string[], hls:table, nodes:table, mode:'list'}
function M.list(d, width)
  local lines, hls, nodes = {}, {}, {}
  local by_id = {}
  for _, n in ipairs(d.nodes) do
    by_id[n.id] = n
  end
  local function add(parts)
    local text, row = '', #lines + 1
    for _, p in ipairs(parts) do
      local s = #text
      text = text .. p[1]
      if p[2] then
        hls[#hls + 1] = { row, s, #text, p[2] }
      end
      if p.node then
        nodes[#nodes + 1] = { row, s, #text, p.node }
      end
    end
    lines[row] = text
  end
  local linked = {}
  for _, e in ipairs(d.edges) do
    local a, b = by_id[e.from], by_id[e.to]
    if a and b then
      linked[a.id], linked[b.id] = true, true
      local arrow = e.label and e.label ~= '' and (' ──' .. e.label .. '──▶ ') or ' ───▶ '
      local left = { { a.label, M.KIND_HL[a.kind], node = a.id } }
      local mid = { arrow, M.EDGE_HL }
      local right = { b.label, M.KIND_HL[b.kind], node = b.id }
      if strwidth(a.label .. arrow .. b.label) <= width then
        add({ left[1], mid, right })
      else
        add({ left[1], { vim.trim(arrow):gsub('^', ' '), M.EDGE_HL } })
        add({ { '    ' }, right })
      end
    end
  end
  for _, n in ipairs(d.nodes) do
    if not linked[n.id] then
      add({ { '• ', M.EDGE_HL }, { n.label, M.KIND_HL[n.kind], node = n.id } })
    end
  end
  local lt, lhs = legend(d)
  lines[#lines + 1] = ''
  lines[#lines + 1] = lt
  for _, sp in ipairs(lhs) do
    hls[#hls + 1] = { #lines, sp[1], sp[2], sp[3] }
  end
  return { lines = lines, hls = hls, nodes = nodes, mode = 'list' }
end

-- ---------------------------------------------------------------------------
-- Layered layout
-- ---------------------------------------------------------------------------

---Lay out and draw a diagram in at most `width` columns.
---@param d table validated diagram
---@param width integer
---@return {lines:string[], hls:{[1]:integer,[2]:integer,[3]:integer,[4]:string}[], nodes:{[1]:integer,[2]:integer,[3]:integer,[4]:string}[], mode:'boxes'|'list'}
---  hls: {row (1-based), start byte, end byte, group}; nodes: {row, start byte, end byte, node id}
function M.render(d, width)
  local n = #d.nodes
  local edges = graph(d)
  break_cycles(n, edges)
  local rank = ranks_of(n, edges)

  -- items: real nodes 1..n, then dummy points of long edges
  local items = {}
  for i, node in ipairs(d.nodes) do
    local label = M.truncate(node.label, math.max(width - 4, 4))
    items[i] = { node = i, rank = rank[i] or 0, label = label, w = strwidth(label) + 4 }
  end
  local segs = {}
  for ei, e in ipairs(edges) do
    local chain = { e.a }
    for r = rank[e.a] + 1, rank[e.b] - 1 do
      items[#items + 1] = { dummy = ei, rank = r, w = 1 }
      chain[#chain + 1] = #items
    end
    chain[#chain + 1] = e.b
    for k = 1, #chain - 1 do
      segs[#segs + 1] = {
        from = chain[k],
        to = chain[k + 1],
        edge = ei,
        head_down = not e.reversed and k == #chain - 1,
        head_up = e.reversed and k == 1,
        label = e.label and e.label ~= '' and ((e.reversed and k == 1) or (not e.reversed and k == #chain - 1)) and e.label or nil,
      }
    end
  end
  local preds, succs = {}, {}
  for i in ipairs(items) do
    preds[i], succs[i] = {}, {}
  end
  for _, sg in ipairs(segs) do
    table.insert(preds[sg.to], sg)
    table.insert(succs[sg.from], sg)
  end
  local maxr = 0
  for _, it in ipairs(items) do
    maxr = math.max(maxr, it.rank)
  end
  -- room for one port per line on each side
  for i, it in ipairs(items) do
    if not it.dummy then
      it.w = math.max(it.w, 2 * math.max(#preds[i], #succs[i]) + 1)
    end
  end

  -- order within ranks: initial by item index, then barycenter sweeps
  local ranks = {}
  for r = 0, maxr do
    ranks[r] = {}
  end
  for i, it in ipairs(items) do
    table.insert(ranks[it.rank], i)
  end
  local pos = {}
  local function index_positions()
    for r = 0, maxr do
      for p, i in ipairs(ranks[r]) do
        pos[i] = p
      end
    end
  end
  index_positions()
  local between = {}
  for r = 0, maxr - 1 do
    between[r] = {}
  end
  for _, sg in ipairs(segs) do
    table.insert(between[items[sg.from].rank], sg)
  end
  local function total_crossings()
    local c = 0
    for r = 0, maxr - 1 do
      c = c + crossings(between[r], pos)
    end
    return c
  end
  local function reorder(r, down)
    local bary = {}
    for p, i in ipairs(ranks[r]) do
      local nb = down and preds[i] or succs[i]
      if #nb > 0 then
        local sum = 0
        for _, sg in ipairs(nb) do
          sum = sum + pos[down and sg.from or sg.to]
        end
        bary[i] = sum / #nb
      else
        bary[i] = p
      end
    end
    local cur = {}
    for p, i in ipairs(ranks[r]) do
      cur[i] = p
    end
    table.sort(ranks[r], function(a, b)
      if bary[a] ~= bary[b] then
        return bary[a] < bary[b]
      end
      return cur[a] < cur[b]
    end)
    for p, i in ipairs(ranks[r]) do
      pos[i] = p
    end
  end
  for r = 1, maxr do
    reorder(r, true) -- initial order follows the rank above
  end
  local best, best_c = vim.deepcopy(ranks), total_crossings()
  for _ = 1, 2 do
    for r = maxr - 1, 0, -1 do
      reorder(r, false)
    end
    for r = 1, maxr do
      reorder(r, true)
    end
    local c = total_crossings()
    if c < best_c then
      best, best_c = vim.deepcopy(ranks), c
    end
  end
  ranks = best
  index_positions()

  -- too wide for the window: list form. Otherwise the widest gap between items that fits.
  local function fits_with(gap)
    for r = 0, maxr do
      local w = -gap
      for _, i in ipairs(ranks[r]) do
        w = w + items[i].w + gap
      end
      if w > width then
        return false
      end
    end
    return true
  end
  if not fits_with(MIN_GAP) then
    return M.list(d, width)
  end
  local GAP = MIN_GAP
  for gap = MAX_GAP, MIN_GAP, -1 do
    if fits_with(gap) then
      GAP = gap
      break
    end
  end

  -- x placement: centre each item over its neighbours, keep order and gaps, fit the width
  local function center(i)
    local it = items[i]
    return it.x + math.floor(it.w / 2)
  end
  -- Closest positions to `desired` (least squares) that keep the order and the gaps, within the
  -- width: isotonic regression by pooling adjacent violators on x minus the packed offset.
  local function place(r, desired)
    local list = ranks[r]
    local off, o = {}, 0
    for k, i in ipairs(list) do
      off[k] = o
      o = o + items[i].w + GAP
    end
    local maxy = width - (off[#list] + items[list[#list]].w)
    local blocks = {}
    for k in ipairs(list) do
      blocks[#blocks + 1] = { sum = desired[k] - off[k], n = 1, from = k, to = k }
      while #blocks > 1 do
        local b, a = blocks[#blocks], blocks[#blocks - 1]
        if a.sum / a.n <= b.sum / b.n then
          break
        end
        a.sum, a.n, a.to = a.sum + b.sum, a.n + b.n, b.to
        blocks[#blocks] = nil
      end
    end
    for _, b in ipairs(blocks) do
      local y = math.min(math.max(math.floor(b.sum / b.n + 0.5), 0), maxy)
      for k = b.from, b.to do
        items[list[k]].x = y + off[k]
      end
    end
    -- rounding and clamping can leave a block overlapping the one before: push right
    for k = 2, #list do
      local prev = items[list[k - 1]]
      items[list[k]].x = math.max(items[list[k]].x, prev.x + prev.w + GAP)
    end
  end
  for r = 0, maxr do
    local zeros = {}
    for k in ipairs(ranks[r]) do
      zeros[k] = 0
    end
    place(r, zeros)
  end
  -- desired centre: the mean centre of the neighbours above ('down'), below ('up') or both
  local function align(r, mode)
    local desired = {}
    for k, i in ipairs(ranks[r]) do
      local sum, cnt = 0, 0
      if mode ~= 'up' then
        for _, sg in ipairs(preds[i]) do
          sum, cnt = sum + center(sg.from), cnt + 1
        end
      end
      if mode ~= 'down' then
        for _, sg in ipairs(succs[i]) do
          sum, cnt = sum + center(sg.to), cnt + 1
        end
      end
      if cnt > 0 then
        desired[k] = math.floor(sum / cnt + 0.5) - math.floor(items[i].w / 2)
      else
        desired[k] = items[i].x
      end
    end
    place(r, desired)
  end
  for _ = 1, 2 do
    for r = 1, maxr do
      align(r, 'down')
    end
    for r = maxr - 1, 0, -1 do
      align(r, 'up')
    end
  end
  for r = 0, maxr do
    align(r, 'both')
  end
  local minx = math.huge
  for _, it in ipairs(items) do
    minx = math.min(minx, it.x)
  end
  for _, it in ipairs(items) do
    it.x = it.x - minx
  end

  -- ports: lines leave/enter a box at distinct columns, ordered by the other end's position
  local function assign_ports(i, list, key, other)
    local it = items[i]
    if it.dummy then
      for _, sg in ipairs(list) do
        sg[key] = it.x
      end
      return
    end
    table.sort(list, function(a, b)
      local ca, cb = center(a[other]), center(b[other])
      if ca ~= cb then
        return ca < cb
      end
      return a.edge < b.edge
    end)
    local k = #list
    for p, sg in ipairs(list) do
      sg[key] = it.x + math.floor(p * it.w / (k + 1))
    end
  end
  for i in ipairs(items) do
    assign_ports(i, vim.list_slice(succs[i], 1), 'sx', 'to')
    assign_ports(i, vim.list_slice(preds[i], 1), 'tx', 'from')
  end

  -- gaps: tracks for lines that change column, rows for labels, the arrow row
  local gaps = {}
  for r = 0, maxr - 1 do
    local gsegs = between[r]
    local bends = {}
    for _, sg in ipairs(gsegs) do
      if sg.sx ~= sg.tx then
        bends[#bends + 1] = sg
      end
    end
    -- a line arriving at column c must turn after a line leaving from column c has turned
    local after = {}
    for _, a in ipairs(bends) do
      after[a] = {}
    end
    for _, a in ipairs(bends) do
      for _, b in ipairs(bends) do
        if a ~= b and a.tx == b.sx then
          table.insert(after[a], b) -- a's track below b's
        end
      end
    end
    table.sort(bends, function(a, b)
      if a.sx ~= b.sx then
        return a.sx < b.sx
      end
      return a.tx < b.tx
    end)
    local tracks, done = {}, {}
    local remaining = vim.list_slice(bends, 1)
    while #remaining > 0 do
      local pick_k
      for k, sg in ipairs(remaining) do
        local okk = true
        for _, b in ipairs(after[sg]) do
          if not done[b] then
            okk = false
            break
          end
        end
        if okk then
          pick_k = k
          break
        end
      end
      pick_k = pick_k or 1 -- constraint cycle: accept an overlap
      local sg = table.remove(remaining, pick_k)
      local t = 1
      for _, b in ipairs(after[sg]) do
        if b.track then
          t = math.max(t, b.track + 1)
        end
      end
      local lo, hi = math.min(sg.sx, sg.tx), math.max(sg.sx, sg.tx)
      while true do
        local clash = false
        for _, iv in ipairs(tracks[t] or {}) do
          if not (hi + 1 < iv[1] or lo - 1 > iv[2]) then
            clash = true
            break
          end
        end
        if not clash then
          break
        end
        t = t + 1
      end
      tracks[t] = tracks[t] or {}
      table.insert(tracks[t], { lo, hi })
      sg.track = t
      done[sg] = true
    end
    local ntracks = 0
    for t in pairs(tracks) do
      ntracks = math.max(ntracks, t)
    end
    gaps[r] = { segs = gsegs, tracks = ntracks }
  end

  -- labels: beside the line just above its arrow, else beside it where it leaves the box above
  -- (the exit row, when the gap has one), else listed under the diagram
  local footnotes = {}
  for r = 0, maxr - 1 do
    local gp = gaps[r]
    local cols, exit_cols = {}, {}
    for _, sg in ipairs(gp.segs) do
      cols[sg.tx] = true
      exit_cols[sg.sx] = true
    end
    local rows = { {}, {} } -- placed label intervals per label row
    local exit = {}
    gp.labels = {}
    local used_rows = 0
    local function fits(occupied, row, a, b)
      if a < 0 or b >= width then
        return false
      end
      for c = a - 1, b + 1 do
        if occupied[c] then
          return false
        end
      end
      for _, iv in ipairs(row) do
        if not (b + 1 < iv[1] or a - 1 > iv[2]) then
          return false
        end
      end
      return true
    end
    for _, sg in ipairs(gp.segs) do
      if sg.label then
        local lw = strwidth(sg.label)
        local placed
        for ri = 1, 2 do
          for _, a in ipairs({ sg.tx + 2, sg.tx - 1 - lw }) do
            if not placed and fits(cols, rows[ri], a, a + lw - 1) then
              table.insert(rows[ri], { a, a + lw - 1 })
              gp.labels[#gp.labels + 1] = { row = ri, x = a, text = sg.label }
              used_rows = math.max(used_rows, ri)
              placed = true
            end
          end
        end
        if not placed and gp.tracks > 0 then
          for _, a in ipairs({ sg.sx + 2, sg.sx - 1 - lw }) do
            if not placed and fits(exit_cols, exit, a, a + lw - 1) then
              table.insert(exit, { a, a + lw - 1 })
              gp.labels[#gp.labels + 1] = { row = 'exit', x = a, text = sg.label }
              placed = true
            end
          end
        end
        if not placed then
          footnotes[#footnotes + 1] = sg
        end
      end
    end
    gp.label_rows = used_rows
    if gp.tracks == 0 and used_rows == 0 then
      gp.height = 1
    else
      gp.height = (gp.tracks > 0 and 1 or 0) + gp.tracks + used_rows + 1
    end
  end

  -- rows
  local y = 0
  local top = {}
  for r = 0, maxr do
    top[r] = y
    y = y + 3
    if r < maxr then
      gaps[r].y = y
      y = y + gaps[r].height
    end
  end
  local height = y

  local g = new_grid()
  -- boxes and dummies
  for i, it in ipairs(items) do
    local y0 = top[it.rank]
    if it.dummy then
      for k = 0, 2 do
        line_mask(g, y0 + k, it.x, U + D)
      end
    else
      local node = d.nodes[i]
      local hl = M.KIND_HL[node.kind] or M.KIND_HL.changed
      local x0, x1 = it.x, it.x + it.w - 1
      put(g, y0, x0, '╭', hl)
      put(g, y0, x1, '╮', hl)
      put(g, y0 + 2, x0, '╰', hl)
      put(g, y0 + 2, x1, '╯', hl)
      for x = x0 + 1, x1 - 1 do
        put(g, y0, x, '─', hl)
        put(g, y0 + 2, x, '─', hl)
        put(g, y0 + 1, x, ' ', hl)
      end
      put(g, y0 + 1, x0, '│', hl)
      put(g, y0 + 1, x1, '│', hl)
      local lw = strwidth(it.label)
      text_at(g, y0 + 1, x0 + 1 + math.floor((it.w - 2 - lw) / 2), it.label, hl)
      for _, sg in ipairs(succs[i]) do
        if not sg.head_up then
          put(g, y0 + 2, sg.sx, '┬', hl)
        end
      end
      for _, sg in ipairs(preds[i]) do
        if not sg.head_down then
          put(g, y0, sg.tx, '┴', hl)
        end
      end
    end
  end
  -- lines in the gaps
  for r = 0, maxr - 1 do
    local gp = gaps[r]
    local y0, h = gp.y, gp.height
    for _, sg in ipairs(gp.segs) do
      if sg.sx == sg.tx then
        for k = 0, h - 1 do
          line_mask(g, y0 + k, sg.sx, U + D)
        end
      else
        local ty = y0 + sg.track -- exit row is y0, tracks follow
        for yy = y0, ty - 1 do
          line_mask(g, yy, sg.sx, U + D)
        end
        local right = sg.tx > sg.sx
        line_mask(g, ty, sg.sx, U + (right and R or L))
        for x = math.min(sg.sx, sg.tx) + 1, math.max(sg.sx, sg.tx) - 1 do
          line_mask(g, ty, x, L + R)
        end
        line_mask(g, ty, sg.tx, D + (right and L or R))
        for yy = ty + 1, y0 + h - 1 do
          line_mask(g, yy, sg.tx, U + D)
        end
      end
    end
    for _, sg in ipairs(gp.segs) do
      if sg.head_up then
        put(g, y0, sg.sx, '▲', M.EDGE_HL)
      end
      if sg.head_down then
        put(g, y0 + h - 1, sg.tx, '▼', M.EDGE_HL)
      end
    end
    local label_y0 = y0 + h - 1 - gp.label_rows
    for _, lb in ipairs(gp.labels) do
      text_at(g, lb.row == 'exit' and y0 or (label_y0 + lb.row - 1), lb.x, lb.text, M.LABEL_HL)
    end
  end

  local lines, hls, bytes = flush(g, height, width)
  local nodes = {}
  for i, it in ipairs(items) do
    if not it.dummy then
      for k = 0, 2 do
        local yy = top[it.rank] + k
        local cb = bytes[yy]
        local s, e = cb[it.x], cb[it.x + it.w]
        if s and e then
          nodes[#nodes + 1] = { yy + 1, s, e, d.nodes[i].id }
        end
      end
    end
  end
  table.sort(nodes, function(a, b)
    if a[1] ~= b[1] then
      return a[1] < b[1]
    end
    return a[2] < b[2]
  end)
  if #footnotes > 0 then
    lines[#lines + 1] = ''
    for _, sg in ipairs(footnotes) do
      local e = edges[sg.edge]
      local text = M.truncate(d.nodes[e.u].label .. ' → ' .. d.nodes[e.v].label .. ': ', math.max(width - strwidth(sg.label), 8))
      lines[#lines + 1] = text .. sg.label
      hls[#hls + 1] = { #lines, 0, #text, M.EDGE_HL }
      hls[#hls + 1] = { #lines, #text, #lines[#lines], M.LABEL_HL }
    end
  end
  local lt, lhs = legend(d)
  lines[#lines + 1] = ''
  lines[#lines + 1] = lt
  for _, sp in ipairs(lhs) do
    hls[#hls + 1] = { #lines, sp[1], sp[2], sp[3] }
  end
  return { lines = lines, hls = hls, nodes = nodes, mode = 'boxes' }
end

-- ---------------------------------------------------------------------------
-- Mermaid
-- ---------------------------------------------------------------------------

local function mm_escape(s)
  return (s:gsub('&', '#amp;'):gsub('"', '#quot;'):gsub('|', '#124;'):gsub('<', '#lt;'):gsub('>', '#gt;'))
end

---Mermaid flowchart text for a diagram (node ids become n1..nk, kinds become classes).
---@return string
function M.mermaid(d)
  local out = { 'flowchart TD' }
  local ids = {}
  for i, node in ipairs(d.nodes) do
    ids[node.id] = 'n' .. i
    out[#out + 1] = ('  n%d["%s"]'):format(i, mm_escape(node.label))
  end
  for _, e in ipairs(d.edges) do
    local a, b = ids[e.from], ids[e.to]
    if a and b then
      if e.label and e.label ~= '' then
        out[#out + 1] = ('  %s -->|"%s"| %s'):format(a, mm_escape(e.label), b)
      else
        out[#out + 1] = ('  %s --> %s'):format(a, b)
      end
    end
  end
  local styles = {
    new = 'fill:#dafbe1,stroke:#1a7f37,color:#1f2328',
    changed = 'fill:#fff8c5,stroke:#9a6700,color:#1f2328',
    context = 'fill:#f6f8fa,stroke:#8c959f,color:#57606a,stroke-dasharray:3 3',
  }
  for _, k in ipairs(M.KINDS) do
    local members = {}
    for i, node in ipairs(d.nodes) do
      if node.kind == k then
        members[#members + 1] = 'n' .. i
      end
    end
    if #members > 0 then
      out[#out + 1] = ('  classDef %s %s'):format(k, styles[k])
      out[#out + 1] = ('  class %s %s'):format(table.concat(members, ','), k)
    end
  end
  return table.concat(out, '\n') .. '\n'
end

return M
