-- Edit from the review: which composed rows can be edited, and where they are in the real file.
-- Pure (no windows or buffers): the float itself lives in edit_float.lua.
--
-- Only the checked-out layer (`@`) in working-tree mode is editable: its new side *is* the
-- working tree, so a composed add/ctx row maps exactly to a line of the file on disk (through the
-- review's snapshot, then through any edits made since, with linemap). Every other view refuses
-- with a message saying how to get there (gS to check the layer out, gu for working-tree mode).
local config = require('revuey.config')
local linemap = require('revuey.linemap')

local M = {}

---Lines of context kept unfolded around the hunk in the float.
M.CONTEXT = 3

local function key(name, default)
  local k = config.options.keymaps[name]
  return type(k) == 'string' and k or default
end

---Hunk index of a side-table entry (hunk rows carry `hunk_idx`; diff headers only `hunk_id`).
local function hunk_index(e)
  return e.hunk_idx or (e.hunk_id and tonumber(e.hunk_id:match('#(%d+)$'))) or nil
end
M.hunk_index = hunk_index

---Messages (one place, so tests and docs agree).
M.msg = {
  row = function()
    return 'revuey: nothing to edit here; put the cursor on a hunk line (' .. key('edit', 'ge') .. ')'
  end,
  layer = function(name)
    return ("revuey: %s isn't checked out; press %s to switch"):format(name, key('switch_layer', 'gS'))
  end,
  remote = function(name)
    return ('revuey: %s is a remote branch (detached HEAD, read-only); press %s to check out a local branch'):format(
      name,
      key('switch_layer', 'gS')
    )
  end,
  hunk_layer = function(name)
    return ("revuey: this hunk comes from %s, which isn't checked out; view it (%s/%s) and press %s to switch"):format(
      name,
      key('next_layer', ']s'),
      key('prev_layer', '[s'),
      key('switch_layer', 'gS')
    )
  end,
  no_labels = function()
    return ("revuey: can't tell which layer this hunk comes from; view the checked-out layer (%s/%s) to edit it"):format(
      key('next_layer', ']s'),
      key('prev_layer', '[s')
    )
  end,
  mode = function()
    return 'revuey: this is the committed-only view; switch to working-tree mode (' .. key('toggle_mode', 'gu') .. ') to edit'
  end,
  deleted_file = function()
    return 'revuey: this file was deleted; there is nothing to edit'
  end,
  no_text = function()
    return 'revuey: no text to edit for this file'
  end,
  deleted_line = function()
    return "revuey: deleted lines can't be edited; opened at the nearest new-side line"
  end,
}

---Can the row `e` of `review` be edited, and at which new-side line (the review's snapshot)?
---@param review revuey.Review files, mode, stack, scope, layer_labels
---@param e revuey.LineEntry?
---@return {ok:boolean, msg?:string, note?:string, file_idx?:integer, hunk_idx?:integer, lnum?:integer, deleted?:boolean}
function M.decide(review, e)
  local function no(msg)
    return { ok = false, msg = msg }
  end
  -- the row first: prose, diagrams, file headers, notes and blanks never are code
  if not e or not e.file_idx or e.file_idx == 0 then
    return no(M.msg.row())
  end
  local code = e.kind == 'add' or e.kind == 'ctx' or e.kind == 'del'
  local header = e.kind == 'meta' and e.meta == 'hunk'
  if not code and not header then
    return no(M.msg.row())
  end
  local f = review.files[e.file_idx]
  if not f then
    return no(M.msg.row())
  end
  local hi = hunk_index(e)

  -- the layer: only the checked-out one (`@`), in working-tree mode
  local st, scope = review.stack, review.scope
  if st and scope then
    local l = scope.kind == 'layer' and st.layers[scope.index] or st.layers[#st.layers]
    if l and not l.is_head then
      return no(M.msg.layer(l.name))
    elseif l and l.remote then
      -- HEAD detached at a remote layer's tip: an edit would have no branch to be committed on
      return no(M.msg.remote(l.name))
    end
  end
  if review.mode ~= 'worktree' then
    return no(M.msg.mode())
  end
  if st and scope and scope.kind == 'full' and hi then
    -- the full stack shows every layer's lines; only the top (checked out) layer's are ours
    local top = st.layers[#st.layers]
    if not review.layer_labels then
      return no(M.msg.no_labels())
    end
    local per = review.layer_labels[e.file_idx]
    local names = per and per[hi]
    if not names then
      return no(M.msg.no_labels())
    end
    for _, n in ipairs(names) do
      if n ~= top.name and n ~= require('revuey.attribution').UNCOMMITTED then
        return no(M.msg.hunk_layer(n))
      end
    end
  end

  -- the file
  if f.status == 'D' then
    return no(M.msg.deleted_file())
  end
  local h = hi and f.hunks[hi]
  if f.binary or not h or not f.worktree then
    return no(M.msg.no_text())
  end

  local res = { ok = true, file_idx = e.file_idx, hunk_idx = hi }
  if e.kind == 'add' or e.kind == 'ctx' then
    res.lnum = e.new_lnum
  elseif e.kind == 'del' then
    res.lnum, res.deleted, res.note = e.anchor_lnum or math.max(h.new_start, 1), true, M.msg.deleted_line()
  else
    res.lnum = M.first_new(h)
  end
  return res
end

---First new-side line of a hunk (a pure deletion: the line it sits after, at least 1).
function M.first_new(h)
  for _, l in ipairs(h.lines) do
    if l.new_lnum then
      return l.new_lnum
    end
  end
  return math.max(h.new_start - 1, 1)
end

---New-side line range of a hunk in snapshot coordinates (a pure deletion: one line).
---@return integer lo, integer hi
function M.hunk_range(h)
  local lo, hi
  for _, l in ipairs(h.lines) do
    if l.new_lnum then
      lo = lo or l.new_lnum
      hi = l.new_lnum
    end
  end
  if not lo then
    lo = M.first_new(h)
    hi = lo
  end
  return lo, hi
end

local function count_lines(text)
  text = text:gsub('\r\n', '\n')
  if text == '' then
    return 0
  end
  local _, n = text:gsub('\n', '')
  return text:sub(-1) == '\n' and n or n + 1
end

---Map a line of `snapshot` (the reviewed new side) to `current` (the buffer as it is now, with
---any edits made since the review was loaded). Unchanged lines map exactly (by a real diff, so
---duplicated text elsewhere is never picked); a changed or deleted line maps to the nearest
---unchanged line above it, shifted by the distance. Clamped to the current line count.
---@param snapshot string?
---@param current string
---@param lnum integer
---@return integer
function M.map_line(snapshot, current, lnum)
  local count = math.max(count_lines(current), 1)
  if snapshot and snapshot ~= current then
    local fwd = linemap.new(snapshot, current)
    local mapped
    for d = 0, 500 do
      if lnum - d < 1 then
        mapped = lnum -- nothing unchanged above: keep the position
        break
      end
      local m = fwd(lnum - d)
      if m then
        mapped = m + d
        break
      end
    end
    lnum = mapped or lnum
  end
  return math.min(math.max(lnum, 1), count)
end

---Rows of the file shown unfolded in the float: the hunk plus `ctx` lines each side.
---@return integer top, integer bottom
function M.view_range(lo, hi, count, ctx)
  ctx = ctx or M.CONTEXT
  return math.max(1, lo - ctx), math.min(math.max(count, 1), hi + ctx)
end

return M
