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
    local pr, stale = forge.get(t)
    if pr then
      parts[#parts + 1] = key .. '=' .. vim.json.encode(pr) .. (stale and '?' or '')
    end
  end
  table.sort(parts)
  return table.concat(parts, '\n')
end

---Signature of the PRs the panel would show now (panel.render records what it drew).
function M.signature(s)
  return s.forge and M.enabled() and shown_sig(s.forge) or ''
end

---Resolve targets for the review shown and fetch their PRs unless the cache answers them all.
---Async; redraws the panel when what it shows changed. Called from view's render (open, `R`,
---scope switches) and lazily from the panel once the cache has expired.
function M.update(s, force)
  if not M.enabled() or not s or s.cleaned then
    return
  end
  local f = state(s)
  force = force or s.forge_force
  s.forge_force = nil
  if f.busy then
    -- one lookup in flight per review: later requests (repeated `R`) become one follow-up
    f.again = true
    f.again_force = f.again_force or force
    return
  end
  f.busy = true
  f.gen = (f.gen or 0) + 1
  local gen = f.gen
  local review = s.review
  -- false once the review closed or a newer lookup started: results are dropped
  local function alive()
    return not s.cleaned and f.gen == gen
  end
  local function done()
    if f.gen ~= gen then
      return
    end
    f.busy, f.job = false, nil
    if f.again and not s.cleaned then
      local again_force = f.again_force
      f.again, f.again_force = nil, nil
      vim.schedule(function()
        M.update(s, again_force)
      end)
    end
  end
  git.async(function()
    local hosts = forge.options().hosts
    local info = forge.remote_info(review.root, hosts)
    if not alive() then
      return done()
    end
    f.info = info
    f.targets = forge.targets(review, info)
    if next(f.targets) then
      local ran = forge.fetch(f.targets, {
        force = force,
        alive = alive,
        on_job = function(obj)
          f.job = obj
        end,
      })
      f.job = nil
      if not alive() then
        return done()
      end
      if ran then
        f.fetches = f.fetches + 1
      end
      forge.check_heads(review.root, f.targets)
      if not alive() then
        return done()
      end
    end
    local sig = shown_sig(f)
    f.ready = true
    if s.review == review and sig ~= (f.drawn or '') then
      -- only when what the panel shows changed, and without moving its cursor
      require('revuey.panel').render(s, { keep_view = true })
    elseif s.review ~= review then
      f.again = true
    end
    -- then the review threads of the scope's open PRs (their own TTL cache)
    local prs = M.threads_enabled() and s.review == review and M.scope_prs(s) or {}
    if #prs > 0 then
      forge.fetch_threads(prs, {
        force = force,
        alive = alive,
        on_job = function(obj)
          f.job = obj
        end,
      })
      f.job = nil
      if not alive() then
        return done()
      end
      if s.review == review and s.layout and vim.api.nvim_buf_is_valid(s.diff_buf)
        and M.threads_signature(s) ~= (f.threads_drawn or '') then
        -- threads are virtual lines of the diff buffer: redraw them (and the panel's counts)
        require('revuey.comments_view').render(s)
        require('revuey.panel').render(s, { keep_view = true })
      end
    end
    done()
  end, function(err)
    log.write('forge', 'lookup error: ' .. tostring(err))
    done()
  end)
end

---The review closed: stop a running `gh` and make sure nothing it returns is used.
function M.detach(s)
  local f = s and s.forge
  if not f then
    return
  end
  f.gen = (f.gen or 0) + 1
  if f.job then
    pcall(function()
      f.job:kill(15)
    end)
    f.job = nil
  end
  f.busy = false
end

---From the panel's render: after the TTL, look again (no polling loop: only when the panel is
---redrawn anyway).
function M.lazy(s)
  local f = s and s.forge
  if not f or f.busy or not f.targets or not next(f.targets) or not M.enabled() then
    return
  end
  if not f.scheduled and not (forge.is_fresh(f.targets) and (not M.threads_enabled() or forge.threads_fresh(M.scope_prs(s)))) then
    f.scheduled = true
    vim.schedule(function()
      f.scheduled = false
      if not s.cleaned then
        M.update(s)
      end
    end)
  end
end

---The PR of a layer (by name) or of the plain review (key ''), and whether it is stale (a
---later lookup failed).
---@return revuey.PR?, boolean?
function M.pr(s, key)
  local f = s and s.forge
  if not f or not f.targets or not M.enabled() then
    return nil
  end
  return forge.get(f.targets[key])
end

---Are review threads shown (forge and `forge.threads` enabled)?
function M.threads_enabled()
  local o = forge.options()
  return o.enabled and o.threads
end

---The open PRs of the scope shown: the viewed layer's (or the plain review's), every layer's in
---full-stack scope (bottom first). Closed and merged PRs have no threads to show here.
---@return revuey.PR[]
function M.scope_prs(s)
  local f = s and s.forge
  if not f or not f.targets then
    return {}
  end
  local keys = {}
  local key = M.current_key(s)
  if key then
    keys[1] = key
  elseif s.review.stack then
    for _, l in ipairs(s.review.stack.layers) do
      keys[#keys + 1] = l.name
    end
  end
  local out, seen = {}, {}
  for _, k in ipairs(keys) do
    local pr = forge.get(f.targets[k])
    if pr and pr.state == 'OPEN' and not seen[pr.url] then
      seen[pr.url] = true
      out[#out + 1] = pr
    end
  end
  return out
end

---Review threads to draw in the scope shown: `{item, thread, pr}` (forge_threads.item), PR by
---PR, each in GitHub's order. Empty when disabled or nothing was fetched.
function M.thread_items(s)
  if not M.threads_enabled() then
    return {}
  end
  local out = {}
  for _, pr in ipairs(M.scope_prs(s)) do
    for _, t in ipairs(forge.threads_for(pr) or {}) do
      out[#out + 1] = { item = require('revuey.forge_threads').item(t, pr), thread = t, pr = pr }
    end
  end
  return out
end

---Signature of the threads the scope would show now (comments_view records what it drew).
function M.threads_signature(s)
  if not M.threads_enabled() then
    return ''
  end
  local parts = {}
  for _, pr in ipairs(M.scope_prs(s)) do
    local e = forge.threads_cache[forge.thread_key(pr)]
    parts[#parts + 1] = forge.thread_key(pr) .. '=' .. (e and e.sig or '-')
  end
  return table.concat(parts, '\n')
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

---Virtual-text chunks for a row: `#123 ✓ `, `#123 draft `, `#123 merged ` (a dim `?` after it
---when stale: the last lookup failed, this is the previous result).
function M.chunks(pr, stale)
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
  if stale then
    out[#out + 1] = { '?', 'RevueyForgeDim' }
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
  -- a parent that is a layer: its PR's head branch, else the first name its lookup tries;
  -- trunk or anything else: the remote stripped
  for _, other in ipairs(r.stack.layers) do
    if other.name == l.parent then
      local t = s.forge.targets and s.forge.targets[other.name]
      local pr = t and forge.get(t)
      if pr and pr.head ~= '' then
        return pr.head
      elseif t then
        return t.candidates[1].branch
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
  local pr, stale
  if key then
    pr, stale = M.pr(s, key)
  end
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
  if stale then
    virt[#virt + 1] = { (#virt > 0 and ' ' or '') .. '(stale)', 'RevueyForgeDim' }
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
  local threads = M.threads_enabled() and pr.state == 'OPEN' and forge.threads_for(pr) or nil
  local counts = threads and require('revuey.forge_threads').summary(threads) or nil
  pf.threads = counts and (counts.open + counts.resolved) > 0 or false
  for _, item in ipairs(forge.detail(pr, parent_branch(s), counts)) do
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

---`gx` in the diff: the GitHub thread on this row in the browser. Returns false when no thread
---covers the row (the caller falls back to the usual `gx`).
function M.open_thread(s, row)
  local c = s and s.cm
  for _, id in ipairs(c and c.cover and c.cover[row] or {}) do
    local it = c.forge_items and c.forge_items[id]
    if it then
      local ok, err = pcall(vim.ui.open, it.forge.url)
      if not ok then
        log.write('forge', 'open failed: ' .. tostring(err))
      end
      return true
    end
  end
  return false
end

return M
