-- Which stack layer introduced each hunk of a full-stack review (for branch labels in the guide,
-- the full-scope diff and the full-stack prompt).
--
-- Approach: diff each layer on its own with no context (`parent...tip`, -U0), then carry every
-- layer's change positions forward to the top of the stack through the -U0 hunks of the layers
-- above it (and of the working tree), with linemap's hunk mapper. A full-scope hunk is touched
-- by a layer when one of that layer's carried positions falls inside the hunk's changed span.
-- Positions are new-side lines for added lines, and "between line p and p+1" (p + 0.5) for
-- deletions, so pure deletions are attributed too. A line a later layer rewrites stops mapping
-- (linemap returns nil), so it belongs to the later layer only. Renames are followed by path.
-- Chosen over `git blame` because it needs one diff per layer (no per-file blame runs), handles
-- deletions, and treats the working tree as one more layer.
--
-- `attribute` is pure; `load` gathers the diffs (call inside git.async).
local linemap = require('revuey.linemap')

local M = {}

M.UNCOMMITTED = 'uncommitted'

---Change positions of a parsed hunk: added lines (new-side numbers) and deletion points p + 0.5
---(after new-side line p).
---@param h revuey.Hunk
---@return number[]
function M.points(h)
  local out, last, del_at = {}, h.new_start - 1, nil
  for _, l in ipairs(h.lines) do
    if l.kind == 'add' then
      out[#out + 1] = l.new_lnum
      last = l.new_lnum
    elseif l.kind == 'del' then
      if del_at ~= last then
        out[#out + 1] = last + 0.5
        del_at = last
      end
    else
      last = l.new_lnum or last
    end
  end
  return out
end

---linemap hunks of a parsed zero-context file diff (diff.parse moves the start of an empty range
---to the line after it; linemap wants the line before).
local function map_hunks(f)
  local t = {}
  for _, h in ipairs(f.hunks) do
    t[#t + 1] = {
      h.old_count == 0 and h.old_start - 1 or h.old_start,
      h.old_count,
      h.new_count == 0 and h.new_start - 1 or h.new_start,
      h.new_count,
    }
  end
  return t
end

---@class revuey.AttribLayer
---@field name string
---@field files revuey.FileDiff[] the layer's own diff, zero context
---@field whole? table<string, true> paths whose every line belongs to this layer (untracked files)

---Attribute the hunks of a full-scope review to layers.
---@param files revuey.FileDiff[] the full-scope review files
---@param layers revuey.AttribLayer[] bottom first (the working tree last, if any)
---@return table<integer, table<integer, string[]>> labels [file_idx][hunk_idx] = layer names
---  (bottom first); [file_idx][0] for a file without a text diff
function M.attribute(files, layers)
  -- per layer: {path -> points} at the top of the stack, and the set of touched paths
  local carried = {}
  for li, layer in ipairs(layers) do
    local pts, touched = {}, {}
    for _, f in ipairs(layer.files) do
      touched[f.path] = true
      local list = {}
      if f.status == 'D' then
        list[1] = 0.5
      else
        for _, h in ipairs(f.hunks) do
          vim.list_extend(list, M.points(h))
        end
      end
      pts[f.path] = list
    end
    -- carry through every later layer
    for lj = li + 1, #layers do
      local by_old = {}
      for _, f in ipairs(layers[lj].files) do
        by_old[f.old_path] = f
      end
      local npts, ntouched = {}, {}
      for path, list in pairs(pts) do
        local f = by_old[path]
        if not f or f.status == 'A' then
          npts[path] = list
        elseif f.status ~= 'D' then
          local map = linemap.from_hunks(map_hunks(f))
          local out = {}
          for _, x in ipairs(list) do
            local whole = math.floor(x)
            if x == whole then
              out[#out + 1] = map(x)
            elseif whole == 0 then
              out[#out + 1] = 0.5
            else
              local y = map(whole)
              out[#out + 1] = y and (y + 0.5) or nil
            end
          end
          npts[f.path] = out
        end
      end
      for path in pairs(touched) do
        local f = by_old[path]
        if not f or f.status == 'A' then
          ntouched[path] = true
        elseif f.status ~= 'D' then
          ntouched[f.path] = true
        end
      end
      pts, touched = npts, ntouched
    end
    for path in pairs(layer.whole or {}) do
      touched[path] = true
    end
    carried[li] = { pts = pts, touched = touched, whole = layer.whole or {} }
  end

  -- Matching runs on the main thread: linear in hunks x carried positions per file, about 80ms
  -- for 6,000 hunks over two layers. Fine for review-sized stacks; move it off the main loop if
  -- that ever matters.
  local labels = {}
  for fi, f in ipairs(files) do
    local per = {}
    labels[fi] = per
    local file_level = {}
    for li, c in ipairs(carried) do
      if c.touched[f.path] then
        file_level[#file_level + 1] = layers[li].name
      end
    end
    if #f.hunks == 0 then
      per[0] = #file_level > 0 and file_level or nil
    end
    for hi, h in ipairs(f.hunks) do
      local p = M.points(h)
      local lo, hi_ = math.huge, -math.huge
      for _, x in ipairs(p) do
        lo, hi_ = math.min(lo, x), math.max(hi_, x)
      end
      local names = {}
      for li, c in ipairs(carried) do
        local hit = c.whole[f.path] == true
        if not hit then
          for _, x in ipairs(c.pts[f.path] or {}) do
            if x >= lo and x <= hi_ then
              hit = true
              break
            end
          end
        end
        if hit then
          names[#names + 1] = layers[li].name
        end
      end
      if #names == 0 and #file_level == 1 then
        names = { file_level[1] } -- nothing matched exactly (a stack that was never restacked)
      end
      per[hi] = #names > 0 and names or nil
    end
  end
  return labels
end

---Gather the per-layer diffs of a full-scope review and attribute its hunks (call inside
---git.async). Returns nil when the review is not a full-stack review, and nil plus a note when
---the stack's shape makes labels unreliable (wrong labels are worse than none).
---Each layer is diffed up to what its child was built on: its tip, or, when the child was not
---restacked after the layer moved (`diverged`), the old tip the child forked from, since the
---layer's later commits are not in the stack's top at all (also for a stale explicit parent
---diffed from an old tip). A child diffed from trunk leaves no path from the layer to the top.
---@param r revuey.Review with r.stack and r.scope
---@return table? labels see attribute()
---@return string? note why there are no labels
function M.load(r)
  local st, scope = r.stack, r.scope
  if not (st and scope and scope.kind == 'full') then
    return nil
  end
  local ends = {}
  for i, l in ipairs(st.layers) do
    local child = st.layers[i + 1]
    if not child or child.parent_rev == l.tip then
      ends[i] = l.tip
    elseif (child.diverged or child.stale) and child.parent_rev ~= st.trunk_rev then
      ends[i] = child.parent_rev -- an old tip of this layer
    else
      return nil, ('branch labels are unavailable: %s is not based on %s\'s commits'):format(child.name, l.name)
    end
  end
  local git = require('revuey.git')
  local diff = require('revuey.diff')
  local fns = {}
  for i, l in ipairs(st.layers) do
    fns[i] = function()
      local text = git.diff(l.parent_rev .. '...' .. ends[i], nil, r.root, 0)
      return text and diff.parse(text) or {}
    end
  end
  local top = st.layers[#st.layers]
  local worktree = r.mode == 'worktree' and top.is_head
  if worktree then
    fns[#fns + 1] = function()
      local text = git.diff(top.tip, nil, r.root, 0)
      return text and diff.parse(text) or {}
    end
    fns[#fns + 1] = function()
      return git.untracked(r.root)
    end
  end
  local res = git.all(fns)
  local layers = {}
  for i, l in ipairs(st.layers) do
    layers[i] = { name = l.name, files = res[i][1] and res[i][2] or {} }
  end
  if worktree then
    local whole = {}
    local untracked = res[#st.layers + 2]
    for _, p in ipairs(untracked[1] and untracked[2] or {}) do
      whole[p] = true
    end
    local wt = res[#st.layers + 1]
    layers[#layers + 1] = { name = M.UNCOMMITTED, files = wt[1] and wt[2] or {}, whole = whole }
  end
  return M.attribute(r.files, layers)
end

return M
