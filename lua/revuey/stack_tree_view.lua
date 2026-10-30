-- The stack tree's glue (UI and git over stack_tree.lua): fetching it with the PR lookup (on
-- open and `R`, decision 20), the review's stack for the chosen path, the tree view (a float
-- over the diff window), and fetching the stack's branches (`git fetch`, never a GitHub write).
--
-- Session state `s.gh_tree`: {fetched, tree, sel (the PR chosen in the tree view; nil = the
-- default route through HEAD's PR), version (bumped when a fetch changes what the stack is
-- built from), reason (why there is no tree), remote, stale, loading (closed subtrees still
-- coming), view (the open tree view)}. Nothing is stored: reopening a review starts from the
-- default route.
local tree_mod = require('revuey.stack_tree')
local forge = require('revuey.forge')
local git = require('revuey.git')
local log = require('revuey.log')
local config = require('revuey.config')
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('revuey.tree')
local ns_path = api.nvim_create_namespace('revuey.tree.path')

---Is the GitHub stack tree on (`stack.github`, and forge enabled)?
function M.enabled()
  return (config.options.stack or {}).github ~= false and forge.options().enabled
end

local function state(s)
  s.gh_tree = s.gh_tree or { version = 0, facts_gen = 0 }
  return s.gh_tree
end
M.state = state

local function first_key(name)
  return require('revuey.keys').first(name)
end

---The branch the tree starts from: HEAD's layer in a git-detected stack, else the checked-out
---branch, else a remote-tracking branch detached HEAD is at.
function M.head_branch(root, git_stack)
  if git_stack then
    local l = git_stack.layers[git_stack.current]
    if l then
      return l.name
    end
  end
  local b = git.current_branch(root)
  if b then
    return b
  end
  local out = git.git({ 'for-each-ref', '--points-at', 'HEAD', '--format=%(refname:short)', 'refs/remotes' }, root) or ''
  for ref in out:gmatch('[^\n]+') do
    if not ref:match('/HEAD$') then
      return ref
    end
  end
end

-- ---------------------------------------------------------------------------
-- Fetching (with the PR lookup, forge_view.update)
-- ---------------------------------------------------------------------------

---Start a tree fetch when this review has none yet (or `force`, `R`): the first round goes into
---the PR lookup's call (`extra`). nil when not wanted or not possible (`gt.reason` says why).
---@return {st:revuey.TreeFetch, extra:table}?
function M.begin(s, info, force)
  if not M.enabled() then
    return nil
  end
  local gt = state(s)
  if gt.fetched and not force then
    return nil
  end
  gt.fetched = true
  local name, trunk = s.review.head_branch, s.review.tree_trunk
  if not trunk then
    gt.reason = 'this review has an explicit base (no stack)'
    return nil
  end
  if not name then
    gt.reason = 'HEAD is not on a branch'
    return nil
  end
  local base, explicit = forge.base_remote(trunk, info)
  if not base then
    gt.reason = 'no GitHub remote'
    return nil
  end
  local trunk_branch = trunk and forge.branch_name(trunk, info) or nil
  local remote = require('revuey.stack').split_remote(name, info.names)
  local t = forge.target(name, info.branches[name] == nil and remote ~= nil, nil, base, info, trunk_branch, explicit)
  if not t or not trunk_branch then
    gt.reason = 'no branch to look up'
    return nil
  end
  local branches, seen = {}, {}
  for _, c in ipairs(t.candidates) do
    if not seen[c.branch] then
      seen[c.branch] = true
      branches[#branches + 1] = c.branch
    end
  end
  local repo = info.remotes[base].repo
  local st = tree_mod.new(repo, trunk_branch, branches, t.candidates[1].head_owner)
  gt.remote = base
  local parts, aliases = tree_mod.first_parts(st)
  return {
    st = st,
    extra = {
      host = repo.host,
      parts = parts,
      fragment = tree_mod.FRAGMENT,
      absorb = function(data, err)
        tree_mod.absorb(st, data, aliases, err)
      end,
    },
  }
end

---Take a fetch's tree. `final`: the closed subtrees are in too.
local function take(s, st, final)
  local gt = state(s)
  if st.failed then
    log.write('forge', 'stack tree: ' .. tostring(st.failed))
  end
  if st.cut then
    log.write('forge', 'stack tree cut: ' .. st.cut)
  end
  local t = tree_mod.tree(st)
  local changed = false
  if not t then
    if st.failed and gt.tree then
      gt.stale = true -- `R` failed: the last tree stays, marked
    else
      changed = gt.tree ~= nil
      gt.tree = nil
      gt.reason = st.failed and 'the GitHub lookup failed (see revuey.log)'
        or ('no pull request for ' .. table.concat(st.start, ' / '))
    end
  else
    changed = not final
    gt.tree, gt.stale, gt.reason = t, (st.failed ~= nil) or nil, nil
    if gt.sel and not t.nodes[gt.sel] then
      gt.sel = nil
    end
  end
  gt.loading = not final and t ~= nil
  gt.calls = st.calls
  if changed then
    gt.version = gt.version + 1
  end
  vim.schedule(function()
    if s.cleaned then
      return
    end
    if changed then
      require('revuey.view').refresh()
    end
    M.redraw(s)
  end)
end

---The rounds after the first (inside forge_view.update's git.async, after the lookup): what
---routes need first, then the stack is rebuilt, then the closed subtrees for the tree view.
function M.continue(s, job, alive, on_job)
  local st = job.st
  local function rounds(closed)
    while alive() do
      local want = tree_mod.plan(st, closed)
      if not want then
        return
      end
      local parts, aliases = tree_mod.parts(st, want)
      local data, err = forge.run_graphql(tree_mod.query(parts), st.repo.host, on_job)
      if not alive() then
        return
      end
      tree_mod.absorb(st, data, aliases, err)
    end
  end
  rounds(false)
  if not alive() then
    return
  end
  local has = tree_mod.tree(st) ~= nil
  take(s, st, false)
  if has then
    rounds(true)
    if alive() then
      take(s, st, true)
    end
  end
end

-- ---------------------------------------------------------------------------
-- The stack for the chosen path
-- ---------------------------------------------------------------------------

---What the clone has (refs, head commits). Inside git.async.
---@return revuey.TreeFacts
function M.facts(s, root, trunk)
  local gt = state(s)
  local t = gt.tree
  local heads, refs = {}, {}
  local out = git.git({ 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads', 'refs/remotes' }, root) or ''
  for line in out:gmatch('[^\n]+') do
    local sha, ref = line:match('^(%x+) (%S+)$')
    if ref and ref:sub(1, 11) == 'refs/heads/' then
      heads[ref:sub(12)] = sha
    elseif ref and ref:sub(1, 13) == 'refs/remotes/' then
      refs[ref:sub(14)] = sha
    end
  end
  local objects, oids = {}, {}
  for _, n in pairs(t and t.nodes or {}) do
    if n.head_oid then
      oids[#oids + 1] = n.head_oid
    end
  end
  if #oids > 0 then
    local res = git.system({ 'git', 'cat-file', '--batch-check' }, { cwd = root, stdin = table.concat(oids, '\n') .. '\n' })
    for oid, kind in tostring(res.stdout or ''):gmatch('(%x+) (%a+)') do
      if kind == 'commit' then
        objects[oid] = true
      end
    end
  end
  local remotes = git.remotes(root)
  local current = git.current_branch(root)
  return {
    remote = gt.remote or 'origin',
    heads = heads,
    refs = refs,
    objects = objects,
    trunk = trunk,
    trunk_rev = git.rev_parse(trunk, root),
    current = current or s.review.head_branch,
    detached = current == nil or nil,
    head = git.rev_parse('HEAD', root),
    normalize = function(n)
      return require('revuey.state').normalize_base(n, remotes)
    end,
  }
end

---The PRs of the chosen path (bottom first) and the index of the chosen PR.
function M.path(s)
  local gt = state(s)
  if not gt.tree then
    return {}
  end
  return tree_mod.route(gt.tree, gt.sel or gt.tree.start)
end

local function signature(st)
  local parts = { st.trunk_rev or '', tostring(st.current) }
  for _, l in ipairs(st.layers) do
    parts[#parts + 1] = table.concat({
      l.name, l.tip, l.parent_rev, tostring(l.pr), tostring(l.others), tostring(l.fetch), tostring(l.is_head),
    }, ' ')
  end
  return table.concat(parts, '\n')
end

---The review's stack from the tree (inside git.async), or nil to keep git detection's: no tree,
---or a default route of one PR (a lone branch stays a plain review until a path is chosen).
---`git_stack` is what git detection found: local-only layers above the path's top (branches
---without a PR yet) stay on top. Unchanged inputs give the same stack object.
---@return revuey.Stack?
function M.stack(s, git_stack, root, trunk, fingerprint)
  local gt = s.gh_tree
  if not (M.enabled() and gt and gt.tree and trunk) then
    return nil
  end
  local path = M.path(s)
  if #path < 2 and not gt.sel then
    return nil
  end
  local key = table.concat({ fingerprint or '', gt.version, gt.facts_gen, tostring(gt.sel) }, '\0')
  if gt.built and gt.built.key == key then
    return gt.built.stack
  end
  local facts = M.facts(s, root, trunk)
  if not facts.trunk_rev then
    return nil
  end
  local st = tree_mod.stack(gt.tree, path, gt.sel, facts)
  if not st then
    return nil
  end
  -- local branches above the top without a PR (yet): git detection's layers stay on top
  local top = st.layers[#st.layers]
  if git_stack and not top.remote then
    local at
    for i, l in ipairs(git_stack.layers) do
      if l.name == top.name then
        at = i
      end
    end
    for i = (at or #git_stack.layers) + 1, #git_stack.layers do
      local l = vim.deepcopy(git_stack.layers[i])
      l.stats = nil
      st.layers[#st.layers + 1] = l
      if l.is_head and not st.head_index then
        st.head_index = #st.layers
        if not gt.sel then
          st.current = #st.layers
        end
      end
    end
  end
  local notes_mod = require('revuey.stack_notes')
  local ctx = { stack = true, trunk = trunk }
  local fk = first_key('stack_fetch')
  for _, num in ipairs(st.missing) do
    local n = gt.tree.nodes[num]
    st.notes[#st.notes + 1] = notes_mod.new('not_fetched', {
      branch = n.fork and ((n.head_owner or '?') .. ':' .. n.head) or n.head,
      pr = num,
      ref = (not n.fork) and (facts.remote .. '/' .. n.head) or ('pull/' .. num .. '/head'),
      key = fk,
    }, ctx)
  end
  if gt.tree.bottom_base and path[1] == gt.tree.chain[1] then
    st.notes[#st.notes + 1] = notes_mod.new('github_base', {
      branch = st.layers[1].name, parent = gt.tree.bottom_base,
    }, ctx)
  elseif gt.tree.stop == 'cycle' and path[1] == gt.tree.chain[1] then
    st.notes[#st.notes + 1] = notes_mod.new('github_base', {
      branch = st.layers[1].name, parent = gt.tree.nodes[path[1]].base, why = 'cycle',
    }, ctx)
  end
  local ign = require('revuey.stack_ignore')
  require('revuey.stack').finish(root, st, ign.patterns((ign.for_root(root, s.opts and s.opts.state_dir))))
  if gt.sel and gt.notify_missing == gt.sel and vim.tbl_contains(st.missing, gt.sel) then
    gt.notify_missing = nil
    vim.schedule(function()
      vim.notify(('revuey: PR #%d is not in this clone yet; %s fetches it'):format(gt.sel, fk or 'stack_fetch'), vim.log.levels.WARN)
    end)
  end
  -- the same stack as before: keep the object (a new one reloads the review)
  local sig = signature(st)
  if gt.built and gt.built.sig == sig then
    gt.built.key = key
    return gt.built.stack
  end
  gt.built = { key = key, sig = sig, stack = st }
  return st
end

-- ---------------------------------------------------------------------------
-- Fetching the stack's branches (git; nothing on GitHub changes)
-- ---------------------------------------------------------------------------

---Why the tree key does nothing here (nil: there is a tree).
function M.unavailable(s)
  local gt = s and s.gh_tree
  if not M.enabled() then
    return 'the stack tree is off (stack.github = false, or forge disabled)'
  end
  if gt and gt.tree then
    return nil
  end
  if not gt or not gt.fetched then
    return 'the stack tree comes from GitHub with the PR lookup; it has not run yet'
  end
  if not gt.reason then
    return 'the stack tree is still loading from GitHub'
  end
  return ('no stack tree from GitHub: %s (the stack comes from git)'):format(gt.reason or 'not loaded')
end

---`git fetch` the heads of `nums` (default: the chosen path) from the PRs' remote: branches
---that exist on GitHub into `<remote>/<head>`, forks and deleted branches through
---`refs/pull/N/head` (commits only, no ref written). Then the review refreshes.
function M.fetch(s, nums)
  local why = M.unavailable(s)
  if why then
    return vim.notify('revuey: ' .. why, vim.log.levels.INFO)
  end
  local gt = state(s)
  if gt.fetching then
    return vim.notify('revuey: a fetch is already running', vim.log.levels.INFO)
  end
  nums = nums or M.path(s)
  local root = s.review.root
  local trunk = s.review.tree_trunk
  gt.fetching = true
  git.async(function()
    local facts = M.facts(s, root, trunk)
    local specs, which = tree_mod.fetch_specs(gt.tree, nums, facts)
    if #specs == 0 then
      gt.fetching = false
      return vim.notify('revuey: nothing to fetch: the stack is up to date with GitHub', vim.log.levels.INFO)
    end
    vim.notify(('revuey: fetching %d PR%s from %s…'):format(#which, #which == 1 and '' or 's', facts.remote), vim.log.levels.INFO)
    local cmd = { 'git', 'fetch', '--no-tags', '--no-write-fetch-head', facts.remote }
    vim.list_extend(cmd, specs)
    local res = git.system(cmd, { cwd = root, timeout = 120000, env = { GIT_TERMINAL_PROMPT = '0' } })
    gt.fetching = false
    gt.facts_gen = gt.facts_gen + 1
    if s.cleaned then
      return
    end
    if res.code ~= 0 then
      local err = vim.trim(tostring(res.stderr or ''))
      log.write('stack', 'git fetch failed: ' .. err)
      local last = err:match('([^\n]*)$') or ''
      vim.notify(('revuey: git fetch failed%s'):format(last ~= '' and (': ' .. last) or ' (see revuey.log)'), vim.log.levels.ERROR)
    else
      local list = vim.tbl_map(function(n)
        return '#' .. n
      end, which)
      vim.notify(('revuey: fetched %s from %s'):format(table.concat(list, ' '), facts.remote), vim.log.levels.INFO)
    end
    require('revuey.view').refresh({ force = true })
    M.redraw(s)
  end, function(err)
    gt.fetching = false
    vim.schedule(function()
      vim.notify('revuey: ' .. tostring(err), vim.log.levels.ERROR)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- The tree view (a float over the diff window)
-- ---------------------------------------------------------------------------

local function display_branch(n)
  return n.fork and ((n.head_owner or '?') .. ':' .. n.head) or n.head
end

---The PR the review is viewing (its layer's), if any.
local function viewed_pr(s)
  local r = s.review
  local l = r.stack and r.scope and r.scope.kind == 'layer' and r.stack.layers[r.scope.index]
  return l and l.pr or nil
end

---Right-side chunks of a node row.
local function right_chunks(s, t, n, row, marks)
  local out = {}
  local function add(text, hl)
    out[#out + 1] = { text, hl }
  end
  if row.hidden then
    add(('+%d closed  '):format(row.hidden), 'Comment')
  end
  if t.more[n.number] then
    add(('+%d more on GitHub  '):format(t.more[n.number]), 'Comment')
  elseif t.unexpanded[n.number] then
    add('…  ', 'Comment')
  end
  local reach = marks[n.number]
  if reach and reach.mark then
    add(tree_mod.MARK_TEXT[reach.mark] .. '  ', 'RevueyStackWarn')
  end
  if n.fork then
    add('fork  ', 'Comment')
  end
  local m = forge.row(n)
  if m.marker then
    add(m.marker, m.marker_hl)
  elseif m.glyph then
    add(m.glyph, m.glyph_hl)
  end
  add(n.number == t.start and ' @' or '  ', 'RevueyUncommitted')
  add(n.number == viewed_pr(s) and ' ▶' or '  ', 'RevueyMode')
  return out
end

local function chunks_width(ch)
  local w = 0
  for _, c in ipairs(ch) do
    w = w + vim.fn.strdisplaywidth(c[1])
  end
  return w
end

---Lines, highlights and row -> PR for the tree at `width`.
function M.lines(s, width, marks)
  local gt = s.gh_tree
  local t = gt.tree
  local v = gt.view or {}
  local path = M.path(s)
  local on_path, main = {}, {}
  for _, num in ipairs(path) do
    on_path[num] = true
    main[num] = true
  end
  local rows = tree_mod.layout(t, { show_closed = v.show_closed, on_path = on_path, main = main })
  local closed = 0
  for _, n in pairs(t.nodes) do
    if n.state == 'CLOSED' then
      closed = closed + 1
    end
  end
  local lines, hls, virt, row_pr = {}, {}, {}, {}
  local function add(text, list)
    lines[#lines + 1] = text
    hls[#lines] = list or {}
    return #lines
  end
  local title = (' Stack tree · %d PR%s on %s'):format(t.count, t.count == 1 and '' or 's', t.trunk)
  local extra = (gt.loading and ' · loading closed PRs…' or '') .. (gt.stale and ' · stale (R failed)' or '')
    .. (t.cut and (' · cut: ' .. t.cut) or '')
  add(title .. extra, { { 0, #title, 'RevueyPanelTitle' }, { #title, #title + #extra, 'Comment' } })
  local help = require('revuey.keys').line(' j k move  <CR> review this path  {tree_closed} ' .. (v.show_closed and 'hide' or 'show')
    .. (' closed (%d)'):format(closed) .. '  {stack_fetch} fetch  q close') or ''
  add(help, { { 0, #help, 'Comment' } })
  add('')
  for _, r in ipairs(rows) do
    if r.trunk then
      local g = tree_mod.graph(r, '◯')
      local text = g .. t.trunk
      add(text, { { 0, #g, 'Comment' }, { #g, #text, 'Comment' } })
    elseif not r.node then
      local g = tree_mod.graph(r, '')
      add(g, { { 0, #g, 'Comment' } })
    else
      local n = t.nodes[r.node]
      local dim = n.state ~= 'OPEN'
      local g, gs, ge = tree_mod.graph(r, on_path[n.number] and '◉' or '◯')
      local right = right_chunks(s, t, n, r, marks)
      local num = '#' .. n.number
      local branch = display_branch(n)
      local avail = width - vim.fn.strdisplaywidth(g) - #num - 1 - chunks_width(right) - 2
      local panel = require('revuey.panel')
      branch = panel.truncate(branch, math.max(math.min(vim.fn.strdisplaywidth(branch), math.max(avail - 12, math.floor(avail * 0.6))), 4))
      local title_room = avail - vim.fn.strdisplaywidth(branch) - 2
      local ttl = title_room >= 4 and ('  ' .. panel.truncate(n.title, title_room)) or ''
      local text = g .. num .. ' ' .. branch .. ttl
      local row = add(text, {
        { 0, #g, 'Comment' },
        { gs, ge, on_path[n.number] and 'RevueyTreeNode' or 'Comment' },
        { #g, #g + #num, dim and 'RevueyForgeDim' or 'RevueyForgeNumber' },
        { #g + #num + 1, #g + #num + 1 + #branch, dim and 'Comment' or 'RevueyStackBranch' },
        { #g + #num + 1 + #branch, #text, dim and 'Comment' or 'Normal' },
      })
      virt[row] = right
      row_pr[row] = n.number
    end
  end
  return lines, hls, virt, row_pr
end

---Marks of every node (how the clone reaches its head), from the last facts.
local function node_marks(s)
  local gt = s.gh_tree
  local out = {}
  if not (gt.view and gt.view.facts) then
    return out
  end
  for num, n in pairs(gt.tree.nodes) do
    out[num] = tree_mod.reach(n, gt.view.facts)
  end
  return out
end

---Highlight the path from the trunk to the PR under the cursor, and its default continuation
---above (dimmer).
function M.highlight(s)
  local gt = s.gh_tree
  local v = gt and gt.view
  if not (v and api.nvim_buf_is_valid(v.buf) and api.nvim_win_is_valid(v.win)) then
    return
  end
  api.nvim_buf_clear_namespace(v.buf, ns_path, 0, -1)
  local num = M.cursor_pr(s)
  if not num then
    return
  end
  local path, idx = tree_mod.route(gt.tree, num)
  local kind = {}
  for i, p in ipairs(path) do
    kind[p] = i <= idx and 'RevueyTreePath' or 'RevueyTreeRoute'
  end
  for row, p in pairs(v.row_pr) do
    if kind[p] then
      api.nvim_buf_set_extmark(v.buf, ns_path, row - 1, 0, { line_hl_group = kind[p], priority = 5 })
    end
  end
end

---The PR on the cursor's row (the nearest PR row above, on a connector row).
function M.cursor_pr(s)
  local v = s.gh_tree and s.gh_tree.view
  if not (v and api.nvim_win_is_valid(v.win)) then
    return nil
  end
  local row = api.nvim_win_get_cursor(v.win)[1]
  for r = row, 1, -1 do
    if v.row_pr[r] then
      return v.row_pr[r]
    end
  end
  for r = row + 1, #v.lines do
    if v.row_pr[r] then
      return v.row_pr[r]
    end
  end
end

---Draw the tree view (keeps the cursor on its PR).
function M.render_view(s)
  local gt = s.gh_tree
  local v = gt and gt.view
  if not (v and api.nvim_buf_is_valid(v.buf) and api.nvim_win_is_valid(v.win)) then
    return
  end
  if not gt.tree then
    return M.close_view(s)
  end
  local keep = M.cursor_pr(s) or v.want
  v.want = nil
  local width = api.nvim_win_get_width(v.win)
  local lines, hls, virt, row_pr = M.lines(s, width, node_marks(s))
  v.lines, v.row_pr = lines, row_pr
  vim.bo[v.buf].modifiable = true
  api.nvim_buf_set_lines(v.buf, 0, -1, false, lines)
  vim.bo[v.buf].modifiable = false
  api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  for row, list in pairs(hls) do
    for _, h in ipairs(list) do
      if h[2] > h[1] then
        pcall(api.nvim_buf_set_extmark, v.buf, ns, row - 1, h[1], { end_col = h[2], hl_group = h[3] })
      end
    end
  end
  for row, ch in pairs(virt) do
    api.nvim_buf_set_extmark(v.buf, ns, row - 1, 0, { virt_text = ch, virt_text_pos = 'right_align' })
  end
  local target
  for row, p in pairs(row_pr) do
    if p == keep then
      target = row
    end
  end
  if not target then
    for row in pairs(row_pr) do
      target = (not target or row < target) and row or target
    end
  end
  if target then
    api.nvim_win_set_cursor(v.win, { target, 0 })
  end
  M.highlight(s)
end

---Redraw what shows the tree (the view when open). Called when a fetch lands.
function M.redraw(s)
  local v = s.gh_tree and s.gh_tree.view
  if not v then
    return
  end
  git.async(function()
    v.facts = M.facts(s, s.review.root, s.review.tree_trunk)
    vim.schedule(function()
      M.render_view(s)
    end)
  end, function() end)
end

function M.close_view(s)
  local gt = s and s.gh_tree
  local v = gt and gt.view
  if not v then
    return
  end
  gt.view = nil
  if api.nvim_win_is_valid(v.win) then
    pcall(api.nvim_win_close, v.win, true)
  end
  if api.nvim_buf_is_valid(v.buf) then
    pcall(api.nvim_buf_delete, v.buf, { force = true })
  end
  if s.diff_win and api.nvim_win_is_valid(s.diff_win) and not s.cleaned then
    pcall(api.nvim_set_current_win, s.diff_win)
  end
end

---Move to the count-th next (dir 1) / previous (-1) PR row.
local function move(s, dir)
  local v = s.gh_tree.view
  local row = api.nvim_win_get_cursor(v.win)[1]
  for _ = 1, vim.v.count1 do
    local r = row + dir
    while r >= 1 and r <= #v.lines and not v.row_pr[r] do
      r = r + dir
    end
    if r < 1 or r > #v.lines then
      break
    end
    row = r
  end
  api.nvim_win_set_cursor(v.win, { row, 0 })
  M.highlight(s)
end

---Review the path through `num`: the stack becomes the trunk-to-`num` chain plus its default
---continuation, viewing `num`'s layer. Session state only.
function M.select(s, num)
  local gt = state(s)
  if not (gt.tree and gt.tree.nodes[num]) then
    return
  end
  gt.sel = num
  gt.notify_missing = num
  M.close_view(s)
  require('revuey.view').refresh({ scope = { kind = 'layer', pr = num }, force = true })
end

---Open the tree view over the diff window (the tree key).
function M.open_view(s)
  if not s then
    return
  end
  local why = M.unavailable(s)
  if why then
    return vim.notify('revuey: ' .. why, vim.log.levels.INFO)
  end
  local gt = state(s)
  if gt.view then
    return M.close_view(s)
  end
  if not (s.diff_win and api.nvim_win_is_valid(s.diff_win)) then
    return
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'revuey-tree'
  pcall(api.nvim_buf_set_name, buf, 'revuey://stack-tree')
  local win = api.nvim_open_win(buf, true, {
    relative = 'win', win = s.diff_win, row = 0, col = 0,
    width = api.nvim_win_get_width(s.diff_win), height = api.nvim_win_get_height(s.diff_win),
    style = 'minimal', border = 'none', zindex = 40,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = 'NormalFloat:Normal'
  gt.view = { buf = buf, win = win, show_closed = false, lines = {}, row_pr = {}, want = viewed_pr(s) or gt.tree.start }
  local function map(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      vim.keymap.set('n', l, fn, { buffer = buf, nowait = true, silent = true, desc = 'revuey: ' .. desc })
    end
  end
  map({ 'j', '<Down>' }, function()
    move(s, 1)
  end, 'stack tree: next PR')
  map({ 'k', '<Up>' }, function()
    move(s, -1)
  end, 'stack tree: previous PR')
  map({ '<CR>', '<2-LeftMouse>' }, function()
    local num = M.cursor_pr(s)
    if num then
      M.select(s, num)
    end
  end, 'stack tree: review the path through this PR')
  map({ 'q', '<Esc>' }, function()
    M.close_view(s)
  end, 'stack tree: close')
  local ck = require('revuey.keys').list('tree_closed')
  if #ck > 0 then
    map(ck, function()
      gt.view.show_closed = not gt.view.show_closed
      M.render_view(s)
    end, 'stack tree: show / hide closed PRs')
  end
  local fk = require('revuey.keys').list('stack_fetch')
  if #fk > 0 then
    map(fk, function()
      local num = M.cursor_pr(s)
      M.fetch(s, num and (tree_mod.route(gt.tree, num)) or nil)
    end, 'stack tree: fetch the path under the cursor')
  end
  local hk = require('revuey.keys').list('help')
  if #hk > 0 then
    map(hk, require('revuey.key_help').toggle, 'all revuey keys (a float)')
  end
  local group = api.nvim_create_augroup('revuey.tree.' .. buf, { clear = true })
  api.nvim_create_autocmd('CursorMoved', {
    group = group, buffer = buf,
    callback = function()
      M.highlight(s)
    end,
  })
  api.nvim_create_autocmd('WinLeave', {
    group = group, buffer = buf,
    callback = function()
      vim.schedule(function()
        if gt.view and gt.view.buf == buf and api.nvim_get_current_win() ~= win then
          M.close_view(s)
        end
      end)
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group, buffer = buf,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  -- draw at once from what is known, then again with the clone's refs (fetch marks)
  M.render_view(s)
  M.redraw(s)
end

---Review cleanup.
function M.detach(s)
  M.close_view(s)
end

---Short texts for a panel layer row's hint lines (under it while the panel has focus).
function M.hints(l)
  local out = {}
  local tk, fk = first_key('stack_tree'), first_key('stack_fetch')
  if l.others and tk then
    local closed = l.others_closed or 0
    local what = closed == l.others and (closed == 1 and '1 closed PR' or (closed .. ' closed PRs'))
      or (l.others == 1 and '1 other path' or (l.others .. ' other paths'))
    out[#out + 1] = ('%s tree: %s here'):format(tk, what)
  end
  if l.fetch and fk then
    out[#out + 1] = ('%s fetch: %s'):format(fk, l.fetch == 'behind' and 'origin is behind GitHub' or 'not fetched yet')
  end
  return out
end

return M
