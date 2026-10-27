-- The panel's side of the PR lookup (UI glue over forge.lua): resolves which PR each stack
-- layer (or the plain review branch) has, fetches what this review has never fetched (on open, a
-- scope showing a PR for the first time) and everything on `R`, and draws the per-row `#123 ✓`
-- chips and the detail section of the layer being viewed. What is shown never changes on its
-- own: a timer runs the change check (forge.check) while the review is shown and focused, and
-- PRs with news on GitHub are marked (`↻`, "new on GitHub") until `R`. Nothing here ever shows
-- an error: failures are in revuey.log.
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
  s.forge = s.forge or { collapsed = false, fetches = 0, checks = 0, fetched = {}, threads_fetched = {} }
  return s.forge
end

---What a target looks up (its candidates; not the tip, which a commit moves): a target fetched
---in this review under this key is not fetched again until `R`.
local function target_key(name, t)
  local parts = { name }
  for _, c in ipairs(t.candidates) do
    for _, r in ipairs(c.repos) do
      parts[#parts + 1] = forge.repo_key(r) .. ':' .. c.branch .. (c.parent == false and '' or '+')
    end
  end
  return table.concat(parts, '\0')
end

---Drop a change check in flight (its `gh` stopped, its answer ignored): a fetch is about to
---replace what it compares against, and its marks would outlive the news they announce.
local function cancel_check(f)
  f.check_gen = (f.check_gen or 0) + 1
  if f.check_job then
    local job = f.check_job
    pcall(function()
      job:kill(15)
    end)
    f.check_job = nil
  end
  f.checking = false
end

---Signature of what the panel shows, so a fetch that changed nothing does not redraw.
local function shown_sig(f)
  local parts = {}
  for key, t in pairs(f.targets or {}) do
    local pr, stale = forge.get(t)
    if pr then
      -- the panel never shows the description: leave the body out (it can be 64KB)
      local changed = vim.tbl_keys(forge.change(pr) or {})
      table.sort(changed)
      parts[#parts + 1] = key .. '=' .. vim.json.encode(vim.tbl_extend('force', pr, { body = #(pr.body or '') })) .. (stale and '?' or '')
        .. '!' .. table.concat(changed, ',')
    end
  end
  table.sort(parts)
  return table.concat(parts, '\n')
end

---Signature of the PRs the panel would show now (panel.render records what it drew).
function M.signature(s)
  return s.forge and M.enabled() and shown_sig(s.forge) or ''
end

---Resolve targets for the review shown and fetch what this review has not fetched yet: PRs of
---targets never looked up here (on open: every layer's), threads of the scope's open PRs never
---fetched here; with `force` (`R`, after a submit) everything for the scope. Async; redraws the
---panel when what it shows changed. Called from view's render (open, scope switches, refreshes:
---these fetch nothing once fetched) and after a submit.
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
      local todo, keys = {}, {}
      for name, t in pairs(f.targets) do
        local k = target_key(name, t)
        if force or not f.fetched[k] then
          todo[name], keys[#keys + 1] = t, k
        end
      end
      if next(todo) then
        cancel_check(f)
      end
      local ran = forge.fetch(todo, {
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
        f.checked_at = forge.now()
      end
      -- fetched (or failed: `R` tries again; nothing retries on its own)
      for _, k in ipairs(keys) do
        f.fetched[k] = true
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
    -- the description of the scope's open PR (same lookup, same cache): rows above the first file
    -- (scheduled: out of this task, so nothing in it can yield or interleave)
    if s.review == review then
      vim.schedule(function()
        M.sync_description(s)
      end)
    end
    -- then the review threads of the scope's open PRs (those never fetched in this review)
    local prs = M.threads_enabled() and s.review == review and M.scope_prs(s) or {}
    if #prs > 0 then
      local todo = {}
      for _, pr in ipairs(prs) do
        if force or not f.threads_fetched[forge.thread_key(pr)] then
          todo[#todo + 1] = pr
        end
      end
      if #todo > 0 then
        cancel_check(f)
        forge.fetch_threads(todo, {
          alive = alive,
          on_job = function(obj)
            f.job = obj
          end,
        })
        f.job = nil
        if not alive() then
          return done()
        end
        f.checked_at = forge.now()
        for _, pr in ipairs(todo) do
          f.threads_fetched[forge.thread_key(pr)] = true
        end
      end
      local blobs = M.load_head_blobs(s, prs, review.root)
      if not alive() then
        return done()
      end
      if s.review == review and s.layout and vim.api.nvim_buf_is_valid(s.diff_buf)
        and (blobs or M.threads_signature(s) ~= (f.threads_drawn or '')) then
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
  cancel_check(f)
  if f.timer then
    f.timer:stop()
    f.timer:close()
    f.timer = nil
  end
  f.busy = false
end

---Is the change check on (`forge.check`, forge enabled)?
function M.check_enabled()
  local o = forge.options()
  return o.enabled and o.check
end

---Is the review's diff buffer in a window of the current tab page?
local function visible(s)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == s.diff_buf then
      return true
    end
  end
  return false
end

---Run the change check when it is due: a review shown (its diff buffer in a window of this tab
---page) in a focused Neovim, `forge.ttl` seconds since the last fetch or check, no lookup or
---check running. The timer calls it, and FocusGained / entering the review's window or tab page
---(a check that came due meanwhile runs at once). Returns true when it started one.
function M.maybe_check(s)
  local f = s and s.forge
  if not f or s.cleaned or not M.check_enabled() or f.unfocused or f.busy or f.checking or not f.ready then
    return false
  end
  if forge.now() - (f.checked_at or 0) < forge.options().interval or not visible(s) then
    return false
  end
  M.check(s)
  return true
end

---The change check now (one at a time; a lookup in flight wins): one small `gh api graphql` call
---for the scope's PRs (forge.check). PRs with news are marked; the panel, the description's
---title row and the winbar are redrawn only when a mark appeared. Failures are logged, never
---shown, and mark nothing.
function M.check(s)
  local f = s and s.forge
  if not f or s.cleaned or f.checking or f.busy then
    return
  end
  local prs = M.scope_prs(s, true)
  f.checked_at = forge.now()
  if #prs == 0 then
    return
  end
  f.checking = true
  f.check_gen = (f.check_gen or 0) + 1
  local gen = f.check_gen
  local function alive()
    return not s.cleaned and f.check_gen == gen
  end
  git.async(function()
    local marked, err = forge.check(prs, {
      threads = M.threads_enabled(),
      alive = alive,
      on_job = function(obj)
        f.check_job = obj
      end,
    })
    if not alive() then
      return
    end
    f.check_job, f.checking = nil, false
    f.checks = f.checks + 1
    f.checked_at = forge.now()
    if not marked then
      log.write('forge', 'change check failed: ' .. tostring(err))
      return
    end
    if next(marked) then
      M.redraw_marks(s)
    end
  end, function(e)
    if alive() then
      f.check_job, f.checking = nil, false
    end
    log.write('forge', 'change check error: ' .. tostring(e))
  end)
end

---Redraw what shows change marks: the panel (keep_view), the description rows (in place, through
---sync_description's gate), the winbar.
function M.redraw_marks(s)
  if s.cleaned then
    return
  end
  if M.signature(s) ~= (s.forge.drawn or '') then
    require('revuey.panel').render(s, { keep_view = true })
  end
  M.sync_description(s)
  if s.diff_win and vim.api.nvim_win_is_valid(s.diff_win) and #vim.api.nvim_list_uis() > 0 then
    pcall(vim.api.nvim__redraw, { win = s.diff_win, winbar = true })
  end
end

---Start the change check for a shown review (view.show, once its augroup exists): a timer that
---looks every quarter of `forge.ttl` whether a check is due (cheap: no call unless due), focus
---tracking, and a check on coming back (FocusGained, the review's window or tab page entered).
---Stopped by detach.
function M.attach(s)
  if not M.enabled() then
    return
  end
  local f = state(s)
  f.checked_at = f.checked_at or forge.now()
  local api = vim.api
  api.nvim_create_autocmd('FocusLost', {
    group = s.augroup,
    callback = function()
      f.unfocused = true
    end,
  })
  api.nvim_create_autocmd('FocusGained', {
    group = s.augroup,
    callback = function()
      f.unfocused = false
      M.maybe_check(s)
    end,
  })
  api.nvim_create_autocmd({ 'TabEnter', 'BufWinEnter' }, {
    group = s.augroup,
    callback = function()
      vim.schedule(function()
        M.maybe_check(s)
      end)
    end,
  })
  if M.check_enabled() and not f.timer then
    local tick = math.max(1, math.floor(forge.options().interval / 4))
    f.timer = vim.uv.new_timer()
    f.timer:start(tick, tick, vim.schedule_wrap(function()
      M.maybe_check(s)
    end))
  end
end

---The PR of a layer (by name) or of the plain review (key ''), whether it is stale (a later
---lookup failed) and its change marks (news on GitHub since it was fetched; forge.change).
---@return revuey.PR?, boolean?, table<string, true>?
function M.pr(s, key)
  local f = s and s.forge
  if not f or not f.targets or not M.enabled() then
    return nil
  end
  local pr, stale = forge.get(f.targets[key])
  return pr, stale, pr and forge.change(pr) or nil
end

---Are review threads shown (forge and `forge.threads` enabled)?
function M.threads_enabled()
  local o = forge.options()
  return o.enabled and o.threads
end

---The open PRs of the scope shown: the viewed layer's (or the plain review's), every layer's in
---full-stack scope (bottom first). Closed and merged PRs have no threads to show here (`all`:
---those too, for the change check). The second value: PR url -> true when stale (a later
---lookup failed).
---@return revuey.PR[], table<string, boolean>
function M.scope_prs(s, all)
  local f = s and s.forge
  if not f or not f.targets then
    return {}, {}
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
  local out, seen, stale = {}, {}, {}
  for _, k in ipairs(keys) do
    local pr, st = forge.get(f.targets[k])
    if pr and (all or pr.state == 'OPEN') and not seen[pr.url] then
      seen[pr.url] = true
      out[#out + 1] = pr
      stale[pr.url] = st == true
    end
  end
  return out, stale
end

---Is the PR description shown (forge and `forge.description` enabled)?
function M.description_enabled()
  local o = forge.options()
  return o.enabled and o.description
end

---Descriptions to show at the top of the diff view: the scope's open PRs (scope_prs: the viewed
---layer's, every layer's in full-stack scope, bottom first) whose body is not empty once cleaned
---(no body, whitespace or only a PR template's comments: nothing). From the PR lookup's cache,
---so a failed refetch keeps what was shown.
---`mark`: 'new' when the title or description changed on GitHub since (the change check),
---'stale' when the last lookup failed (this is the previous one), else nil.
---@return {pr:revuey.PR, md:string, mark?:'new'|'stale'}[]
function M.descriptions(s)
  if not M.description_enabled() then
    return {}
  end
  local fd = require('revuey.forge_description')
  local out = {}
  local prs, stale = M.scope_prs(s)
  for _, pr in ipairs(prs) do
    local md = fd.clean(pr.body)
    if md ~= '' then
      local mark = forge.change(pr, forge.SIGNALS_DESC) and 'new' or stale[pr.url] and 'stale' or nil
      out[#out + 1] = { pr = pr, md = md, mark = mark }
    end
  end
  return out
end

---Signature of the descriptions the diff view would show now (render records what it drew).
function M.description_signature(s)
  local parts = {}
  for _, d in ipairs(M.descriptions(s)) do
    parts[#parts + 1] = table.concat({ d.pr.url, d.pr.number, d.pr.title, tostring(d.pr.draft), d.md, d.mark or '' }, '\0')
  end
  return table.concat(parts, '\n')
end

---What the diff view draws for the descriptions: their signature and the wrap width (none: '').
local function drawn_key(s, width)
  local sig = M.description_signature(s)
  return sig ~= '' and (sig .. '\n@' .. tostring(width)) or ''
end

---Rows to put above the first file of the diff layout (layout.compose's `head`): each
---description's title, body and a blank row, as prose rows (`role = 'description'`, which every
---diff feature skips), and a block per PR `{url, number, title, start_row, end_row, fold?}`
---(rows: the description is at the top, so they are rows of the buffer). Records what it drew.
---@return {rows:{text:string, entry:table}[], blocks:table[]}?
function M.description_head(s, width)
  local f = s and s.forge
  if not f then
    return nil -- no lookup yet (or the forge is off): nothing to show
  end
  f.desc_drawn = drawn_key(s, width)
  local list = M.descriptions(s)
  if #list == 0 then
    return nil
  end
  local fd = require('revuey.forge_description')
  local o = forge.options()
  local head = { rows = {}, blocks = {} }
  for _, d in ipairs(list) do
    local r = fd.render(d.pr, d.md, width, { max_lines = o.description_lines, mark = d.mark })
    local base = #head.rows
    local block = { url = d.pr.url, number = d.pr.number, title = d.pr.title, mark = d.mark, start_row = base + 1, end_row = base + #r.rows }
    if r.fold then
      block.fold = { base + r.fold[1], base + r.fold[2] }
    end
    for _, row in ipairs(r.rows) do
      head.rows[#head.rows + 1] = {
        text = (row.text:gsub('[\r\n]', ' ')),
        entry = { kind = 'prose', role = 'description', hls = row.hls, desc = block },
      }
    end
    head.blocks[#head.blocks + 1] = block
  end
  return head
end

---After a lookup (scheduled out of its task) or a resize: when the descriptions changed (one
---arrived, was edited, went away, or the width re-wraps them), replace their rows in place
---(view.replace_description: the head rows only, so nothing below moves on screen). Not in the
---guide view (it has none; switching back renders them). Only in Normal mode: in Visual,
---Insert or another mode it waits for the mode to change, so a selection or an edit never sees
---the rows move; with the comment editor open (a float at a buffer row), until it is closed.
function M.sync_description(s)
  local f = s and s.forge
  if not f or s.cleaned or (s.view_mode or 'diff') ~= 'diff' or not s.layout then
    return
  end
  local view = require('revuey.view')
  if drawn_key(s, view.description_width(s)) == (f.desc_drawn or '') then
    return
  end
  local api = vim.api
  if not (s.diff_buf and api.nvim_buf_is_valid(s.diff_buf)) then
    return
  end
  if api.nvim_get_mode().mode ~= 'n' then
    if not f.desc_wait then
      f.desc_wait = true
      api.nvim_create_autocmd('ModeChanged', {
        group = s.augroup,
        once = true,
        callback = function()
          f.desc_wait = nil
          vim.schedule(function()
            M.sync_description(s)
          end)
        end,
      })
    end
    return
  end
  local editor = package.loaded['revuey.comment_editor']
  if editor and editor.current and not editor.current.done then
    -- the comment editor floats at a buffer row: once it is closed
    if not f.desc_later then
      f.desc_later = true
      vim.defer_fn(function()
        f.desc_later = nil
        M.sync_description(s)
      end, 500)
    end
    return
  end
  local ok, err = pcall(view.replace_description, s)
  if not ok then
    log.write('forge', 'description: ' .. tostring(err))
  end
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

---Blobs of the threads' files at the head commit their threads were numbered against
---(forge.threads_head: `<oid>:<path>` -> blob), looked up with one `git cat-file --batch-check`
---for the keys not known yet. Found blobs are immutable facts, kept for the review; a commit or
---path missing here is asked again on the next update (the user may fetch it meanwhile), so a
---missing head costs one `git cat-file --batch-check` per update (open, refresh, scope switch,
---`R`; local, never a GitHub call) until the commit is found.
---Placement trusts GitHub's line numbers when the review's new side of a file is that blob.
---Call inside git.async. Returns true when a blob was found.
function M.load_head_blobs(s, prs, root)
  local f = state(s)
  f.head_blobs = f.head_blobs or {}
  local keys, seen = {}, {}
  for _, pr in ipairs(prs) do
    local head = forge.threads_head(pr)
    for _, t in ipairs(head and forge.threads_for(pr) or {}) do
      local k = head .. ':' .. t.path
      if not f.head_blobs[k] and not seen[k] and not k:find('\n', 1, true) then
        seen[k] = true
        keys[#keys + 1] = k
      end
    end
  end
  if #keys == 0 then
    return false
  end
  local res = git.system({ 'git', 'cat-file', '--batch-check' }, { cwd = root, stdin = table.concat(keys, '\n') .. '\n' })
  local out = vim.split(res.stdout or '', '\n', { plain = true })
  local found = false
  for i, k in ipairs(keys) do
    local oid, kind = (out[i] or ''):match('^(%x+) (%a+)')
    if res.code == 0 and kind == 'blob' then
      f.head_blobs[k] = oid
      found = true
    end
  end
  return found
end

---Blob of `path` at the head commit the PR's threads were numbered against, when known (see
---load_head_blobs).
function M.head_blob(s, pr, path)
  local head = forge.threads_head(pr)
  local b = s.forge and s.forge.head_blobs and head and s.forge.head_blobs[head .. ':' .. path]
  return b or nil
end

---Has the scope shown any review threads (for the panel's key hint)?
function M.has_threads(s)
  if not M.threads_enabled() then
    return false
  end
  for _, pr in ipairs(M.scope_prs(s)) do
    if next(forge.threads_for(pr) or {}) then
      return true
    end
  end
  return false
end

---Signature of the threads the scope would show now (comments_view records what it drew).
function M.threads_signature(s)
  if not M.threads_enabled() then
    return ''
  end
  local parts = {}
  for _, pr in ipairs(M.scope_prs(s)) do
    local e = forge.threads_cache[forge.thread_key(pr)]
    -- stale and cut lists change the panel's threads line
    parts[#parts + 1] = forge.thread_key(pr) .. '=' .. (e and e.sig or '-') .. (e and e.failed and '?' or '') .. (e and e.truncated and '+' or '')
      .. '@' .. (e and e.head_oid or '') -- the head the placement trusts
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

---Virtual-text chunks for a row: `#123 ✓ `, `#123 draft `, `#123 merged ` (`↻` after it when
---GitHub has news since it was fetched: `R` shows them; a dim `?` when stale: the last lookup
---failed, this is the previous result).
function M.chunks(pr, stale, changed)
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
  if changed then
    out[#out + 1] = { forge.GLYPH_NEW, 'RevueyForgeChanged' }
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
  local pr, stale, changed
  if key then
    pr, stale, changed = M.pr(s, key)
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
  if changed then
    virt[#virt + 1] = { (#virt > 0 and ' ' or '') .. '(' .. forge.NEW_TEXT .. ' · R)', 'RevueyForgeChanged' }
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
  local threads, tstale, truncated
  if M.threads_enabled() and pr.state == 'OPEN' then
    threads, tstale, truncated = forge.threads_for(pr)
  end
  local counts = threads and require('revuey.forge_threads').summary(threads) or nil
  if counts then
    counts.truncated, counts.stale = truncated, tstale
    counts.changed = forge.change(pr, forge.SIGNALS_THREADS) ~= nil
  end
  for _, item in ipairs(forge.detail(pr, parent_branch(s), counts)) do
    local indent = (item.kind == 'review' or item.kind == 'requested') and '     ' or '   '
    local text = item.glyph and (item.glyph .. ' ' .. item.text) or item.text
    local lines = panel.wrap(text, width, indent)
    for i, line in ipairs(lines) do
      local hls = { { #indent, #line, item.hl } }
      if item.marks and #lines == 1 then
        -- the threads line's marks in their own colours (when it is not wrapped)
        for _, m in ipairs(item.marks) do
          hls[#hls + 1] = { #indent + m[1], #indent + m[2], m[3] }
        end
      end
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
