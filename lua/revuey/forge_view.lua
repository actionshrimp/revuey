-- The panel's side of the PR lookup (UI glue over forge.lua): resolves which PR each stack
-- layer (or the plain review branch) has, fetches them in the background when the review is
-- drawn (open, `R`, a scope switch) unless the cache is fresh, and draws the per-row `#123 ✓`
-- chips and the detail section of the layer being viewed. Nothing here ever shows an error:
-- failures are in revuey.log.
local forge = require('revuey.forge')
local git = require('revuey.git')
local log = require('revuey.log')

local M = {}

function M.enabled()
  return forge.options().enabled
end

---State kept on the session: targets by layer name ('' for a plain review), the remote info,
---the detail section's fold state and rows.
local function state(s)
  s.forge = s.forge or { collapsed = false, fetches = 0 }
  return s.forge
end

---Signature of what the panel shows, so a fetch that changed nothing does not redraw.
local function shown_sig(f)
  local parts = {}
  for key, t in pairs(f.targets or {}) do
    local pr = forge.get(t)
    parts[#parts + 1] = key .. '=' .. (pr and vim.json.encode(pr) or '-')
  end
  table.sort(parts)
  return table.concat(parts, '\n')
end

---Resolve targets for the review shown and fetch their PRs unless the cache answers them all.
---Async; redraws the panel when what it shows changed. Called from view's render (open, `R`,
---scope switches) and lazily from the panel once the cache has expired.
function M.update(s)
  if not M.enabled() or not s or s.cleaned then
    return
  end
  local f = state(s)
  if f.busy then
    f.again = true
    return
  end
  f.busy = true
  local review = s.review
  local function done()
    f.busy = false
    if f.again and not s.cleaned then
      f.again = nil
      vim.schedule(function()
        M.update(s)
      end)
    end
  end
  git.async(function()
    local hosts = forge.options().hosts
    local info = forge.remote_info(review.root, hosts)
    if s.cleaned then
      return done()
    end
    f.info = info
    f.targets = forge.targets(review, info)
    if next(f.targets) and forge.fetch(f.targets) then
      f.fetches = f.fetches + 1
    end
    local sig = shown_sig(f)
    f.ready = true
    if sig ~= f.sig and s.review == review then
      f.sig = sig
      require('revuey.panel').render(s)
    elseif s.review ~= review then
      f.again = true
    end
    done()
  end, function(err)
    log.write('forge', 'lookup error: ' .. tostring(err))
    done()
  end)
end

---From the panel's render: after the TTL, look again (no polling loop: only when the panel is
---redrawn anyway).
function M.lazy(s)
  local f = s and s.forge
  if not f or f.busy or not f.targets or not next(f.targets) or not M.enabled() then
    return
  end
  if not f.scheduled and not forge.is_fresh(f.targets) then
    f.scheduled = true
    vim.schedule(function()
      f.scheduled = false
      if not s.cleaned then
        M.update(s)
      end
    end)
  end
end

---The PR of a layer (by name) or of the plain review (key '').
---@return revuey.PR?
function M.pr(s, key)
  local f = s and s.forge
  if not f or not f.targets or not M.enabled() then
    return nil
  end
  return forge.get(f.targets[key])
end

---Key of the layer being viewed: its name, '' for a plain review, nil in full-stack scope.
function M.current_key(s)
  local r = s.review
  if not r.stack then
    return ''
  end
  if r.scope and r.scope.kind == 'layer' then
    local l = r.stack.layers[r.scope.index]
    return l and l.name
  end
end

---Virtual-text chunks for a row: `#123 ✓ `, `#123 draft `, `#123 merged `.
function M.chunks(pr)
  if not pr then
    return nil
  end
  local m = forge.row(pr)
  local out = { { m.number, m.number_hl } }
  if m.glyph then
    out[#out + 1] = { ' ' .. m.glyph, m.glyph_hl }
  end
  if m.marker then
    out[#out + 1] = { ' ' .. m.marker, m.marker_hl }
  end
  out[#out + 1] = { ' ', 'Normal' }
  return out
end

---Parent of the layer being viewed, as a branch name GitHub would use (nil: no stack).
local function parent_branch(s)
  local r = s.review
  if not (r.stack and r.scope and r.scope.kind == 'layer') then
    return nil
  end
  local l = r.stack.layers[r.scope.index]
  if not l then
    return nil
  end
  -- a parent that is a layer: the branch its lookup used; trunk or anything else: remote stripped
  for _, other in ipairs(r.stack.layers) do
    if other.name == l.parent then
      local t = s.forge.targets and s.forge.targets[other.name]
      if t then
        return t.branch
      end
    end
  end
  return forge.branch_name(l.parent, s.forge.info)
end

---Detail section of the viewed layer's PR: a heading (`<Tab>` folds it) and the PR's title,
---author, review state, reviewers, checks, mergeability and base. Nothing without a PR.
---Rows go to `s.panel_forge` (heading row, rows -> PR) for `<Tab>` and the open key.
function M.render_detail(s, add, add_virt, width)
  s.panel_forge = nil
  local key = M.current_key(s)
  local pr = key and M.pr(s, key)
  if not pr then
    return
  end
  local panel = require('revuey.panel')
  local f = s.forge
  local pf = { rows = {}, pr = pr }
  s.panel_forge = pf
  local fold = f.collapsed and '▸' or '▾'
  local head = (' %s PR #%d'):format(fold, pr.number)
  local row = add(head, { { 1, 1 + #fold, 'RevueyForgeDim' }, { 1 + #fold, #head, 'RevueyPanelTitle' } })
  local m = forge.row(pr)
  local virt = {}
  if m.glyph then
    virt[1] = { m.glyph, m.glyph_hl }
  end
  if m.marker then
    virt[#virt + 1] = { m.marker, m.marker_hl }
  end
  if #virt > 0 then
    add_virt(row, virt)
  end
  pf.heading = row
  pf.rows[row] = pr
  if f.collapsed then
    add('')
    return
  end
  for _, item in ipairs(forge.detail(pr, parent_branch(s))) do
    local indent = (item.kind == 'review' or item.kind == 'requested') and '     ' or '   '
    local text = item.glyph and (item.glyph .. ' ' .. item.text) or item.text
    local lines = panel.wrap(text, width, indent)
    for i, line in ipairs(lines) do
      local hls = { { #indent, #line, item.hl } }
      if i == 1 and item.glyph and (item.kind == 'review' or item.kind == 'requested') then
        -- reviewer name in normal colour, glyph and state coloured
        local name_end = #indent + #item.glyph + 1 + #(item.text:match('^%S+') or '')
        hls = { { #indent, #indent + #item.glyph, item.hl }, { #indent + #item.glyph, name_end, 'Normal' }, { name_end, #line, item.hl } }
      end
      local r = add(line, hls)
      pf.rows[r] = pr
    end
  end
  add('')
end

---Toggle the detail section (<Tab> on its heading). Returns false when `row` is not the heading.
function M.toggle(s, row)
  local pf = s.panel_forge
  if not pf or pf.heading ~= row then
    return false
  end
  state(s).collapsed = not s.forge.collapsed
  require('revuey.panel').render(s)
  return true
end

---PR for a panel row: a layer row's PR, the detail section's PR, else the viewed layer's.
---@return revuey.PR?
function M.pr_at(s, row)
  local layer = s.panel_layers and s.panel_layers[row]
  if type(layer) == 'number' then
    local l = s.review.stack.layers[layer]
    return l and M.pr(s, l.name), l and l.name
  end
  if s.panel_forge and s.panel_forge.rows[row] then
    return s.panel_forge.rows[row]
  end
  local key = M.current_key(s)
  return key and M.pr(s, key), key
end

---Open the PR for a panel row in the browser (vim.ui.open on its URL).
function M.open(s, row)
  local pr, key = M.pr_at(s, row)
  if not pr then
    local what = (key and key ~= '') and key or (s.review.stack and 'this scope' or s.review.branch)
    return vim.notify('revuey: no pull request found for ' .. what, vim.log.levels.INFO)
  end
  local ok, err = pcall(vim.ui.open, pr.url)
  if not ok then
    log.write('forge', 'open failed: ' .. tostring(err))
  end
  return pr
end

return M
