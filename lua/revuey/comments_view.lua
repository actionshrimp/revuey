-- Comments in the review UI (diff and guide views): placement on every render, inline threads
-- as virtual lines (buffer text and the side table never change, so LSP, marks and folds keep
-- working), gutter signs through the statuscolumn, the editor float, actions on the comment
-- under the cursor, the comments list, export, the event feed and live reload when another
-- instance or `bin/revuey reply` changes the comments file.
local api = vim.api
local comments = require('revuey.comments')
local export = require('revuey.comments_export')
local config = require('revuey.config')
local review_mod = require('revuey.review')
local prose = require('revuey.prose')
local editor = require('revuey.comment_editor')

local M = {}

M.ns = api.nvim_create_namespace('revuey.comments')

---Pluggable actions. `send` is the editor's send key (<C-a>): by default it saves the comment and
---sends it to the coding-agent session watching this review (M.send_to_agent); the later chat
---panel can plug in here. It gets {session, comment?, anchor, text, kind, store} and returns true
---when it took the text (the editor then closes).
M.actions = {
  send = function(req)
    return M.send_to_agent(req)
  end,
}

local function opt(name, default)
  local c = config.options.comments or {}
  if c[name] == nil then
    return default
  end
  return c[name]
end

local function cm(s)
  s.cm = s.cm or { expanded = {}, hidden = false }
  return s.cm
end

---Which GitHub review threads are drawn: 'all' (resolved and outdated ones collapsed), 'open'
---(resolved ones left out), 'none'. `forge.threads.show` is the start; the forge_threads key
---cycles it per review.
local FORGE_SHOW = { 'all', 'open', 'none' }
local function forge_show(s)
  local c = cm(s)
  if not c.forge_show then
    local t = (config.options.forge or {}).threads
    local v = type(t) == 'table' and t.show or nil
    c.forge_show = vim.tbl_contains(FORGE_SHOW, v) and v or 'all'
  end
  return c.forge_show
end

-- ---------------------------------------------------------------------------
-- Review info, store, watcher
-- ---------------------------------------------------------------------------

---What the comments file and events record about the review (export headers, CLI filters).
function M.review_info(s)
  return comments.review_info(s.review)
end

local function stop_watch(c)
  if c.watcher then
    pcall(function()
      c.watcher:stop()
      c.watcher:close()
    end)
    c.watcher = nil
  end
  if c.timer then
    pcall(function()
      c.timer:stop()
      c.timer:close()
    end)
    c.timer = nil
  end
end

---Load the store of the session's review scope (once per scope) and watch its file.
function M.sync_store(s)
  local c = cm(s)
  local path = comments.path_for(s.review.state._path)
  if c.path == path and c.store then
    return c.store
  end
  stop_watch(c)
  c.path = path
  c.events = comments.events_path_for(s.review.state._path)
  c.store = comments.load(path)
  c.expanded = {}
  -- watch the directory: saves replace the file (rename), which a watch on the file would miss
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, 'p')
  local name = vim.fs.basename(path)
  local ok, w = pcall(vim.uv.new_fs_event)
  if ok and w then
    c.timer = vim.uv.new_timer()
    local started = pcall(w.start, w, dir, {}, function(err, fname)
      if err or (fname and fname ~= name) then
        return
      end
      if c.timer then
        c.timer:stop()
        c.timer:start(80, 0, vim.schedule_wrap(function()
          if s.cm == c and c.path == path and not s.cleaned then
            M.reload(s)
          end
        end))
      end
    end)
    if started then
      c.watcher = w
    else
      pcall(w.close, w)
    end
  end
  return c.store
end

---Re-read the comments file (another instance or the CLI changed it) and redraw when anything
---changed. Placement changes found while redrawing are not saved here (only on renders), so two
---instances showing different modes can never keep rewriting the file for each other.
function M.reload(s)
  local c = cm(s)
  if not c.store then
    return false
  end
  local before, known = {}, {}
  for id, x in pairs(c.store.comments) do
    before[id] = comments.delivery(x)
    known[id] = true
  end
  local ok, changed = pcall(comments.reload, c.store)
  if ok and changed then
    M.refresh(s)
    for id, x in pairs(c.store.comments) do
      if before[id] ~= 'answered' and comments.delivery(x) == 'answered' then
        vim.notify('revuey: the agent answered on ' .. comments.location(x), vim.log.levels.INFO)
      elseif known[id] == nil and not x.deleted and x.author and x.author.kind == 'agent' then
        vim.notify('revuey: the agent commented on ' .. comments.location(x), vim.log.levels.INFO)
      end
    end
    return true
  end
  return false
end

function M.detach(s)
  if s.cm then
    stop_watch(s.cm)
  end
  if editor.current and not editor.current.done and editor.current.opts.session == s then
    local st = editor.current
    pcall(api.nvim_win_close, st.win, true)
  end
end

-- ---------------------------------------------------------------------------
-- Placement and decoration
-- ---------------------------------------------------------------------------

---Full text of a side of a file in the review (new: the reviewed snapshot; old: the old blob).
local function side_text(s, path, side)
  local U = review_mod.units(s.review)
  local fi = U.by_path[path]
  local f = fi and s.review.files[fi]
  local c = cm(s)
  c.blobs = c.blobs or {}
  s.head_cache = s.head_cache or {}
  -- the same text `bin/revuey comment` hashes (review.side_text)
  return review_mod.side_text(s.review, f, side, { heads = s.head_cache, blobs = c.blobs })
end

---Placement context for the session's current review (cached per review).
local function context(s)
  local c = cm(s)
  if c.ctx_review ~= s.review then
    c.ctx_review = s.review
    c.ctx = comments.context(s.review.files, review_mod.units(s.review), function(path, side)
      return side_text(s, path, side)
    end)
  end
  return c.ctx
end
M.context = context

local function entry_side_lnum(e, side)
  if side == 'new' then
    return e.kind ~= 'del' and e.new_lnum or nil
  end
  return e.kind ~= 'add' and e.old_lnum or nil
end

---Rows of the current layout by path, side and line; file header and last rows.
local function row_index(s)
  local L = s.layout
  if L.comment_index then
    return L.comment_index
  end
  local idx = { lines = {}, file_row = {}, file_last = {} }
  for row, e in ipairs(L.map) do
    if e.path and e.file_idx and e.file_idx > 0 and e.kind ~= 'prose' and e.kind ~= 'diagram' then
      local p = e.path
      if e.kind == 'add' or e.kind == 'del' or e.kind == 'ctx' then
        idx.lines[p] = idx.lines[p] or { new = {}, old = {} }
        for _, side in ipairs({ 'new', 'old' }) do
          local n = entry_side_lnum(e, side)
          if n and not idx.lines[p][side][n] then
            idx.lines[p][side][n] = row
          end
        end
      end
      if e.meta ~= 'blank' then
        idx.file_last[p] = math.max(idx.file_last[p] or 0, row)
      end
      if not idx.file_row[p] and (e.meta == 'file' or e.meta == 'hunk') then
        idx.file_row[p] = row
      end
    end
  end
  L.comment_index = idx
  return idx
end

local function ago(ms)
  local d = math.floor((comments.now_ms() - (tonumber(ms) or 0)) / 1000)
  if d < 60 then
    return 'just now'
  elseif d < 3600 then
    return math.floor(d / 60) .. ' min ago'
  elseif d < 86400 then
    return math.floor(d / 3600) .. ' h ago'
  elseif d < 86400 * 7 then
    return math.floor(d / 86400) .. ' d ago'
  end
  return os.date('%Y-%m-%d', math.floor(ms / 1000))
end
M.ago = ago

---Text width for threads: the diff window minus the gutter, capped.
local function thread_width(s)
  local w = (s.diff_win and api.nvim_win_is_valid(s.diff_win)) and api.nvim_win_get_width(s.diff_win) or 100
  return math.max(30, math.min(w - (2 * (s.numw or 3) + 4) - 1, opt('width', 100)))
end

---Prose line ({text, hls}) -> virtual text chunks.
local function chunks(line, base)
  local text, hls = line.text, line.hls or {}
  if #hls == 0 then
    return { { text, base } }
  end
  local groups = {}
  for _, h in ipairs(hls) do
    for b = h[1] + 1, math.min(h[2], #text) do
      groups[b] = h[3]
    end
  end
  local out, start, cur = {}, 1, groups[1]
  for b = 2, #text + 1 do
    local g = groups[b]
    if b > #text or g ~= cur then
      local piece = text:sub(start, b - 1)
      if piece ~= '' then
        out[#out + 1] = { piece, cur and { base, cur } or base }
      end
      start, cur = b, g
    end
  end
  return out
end

local function fill(width, used)
  return string.rep('─', math.max(1, width - used))
end

local function author_label(a)
  a = a or {}
  if a.kind == 'user' or not a.kind then
    return a.name or 'You'
  end
  if a.kind == 'forge' then
    return a.name or 'ghost' -- a GitHub login (the thread header says GitHub)
  end
  local kind = ({ ai = 'AI', agent = 'Agent' })[a.kind] or a.kind
  if a.name and a.name ~= '' and a.name:lower() ~= a.kind then
    return a.name .. ' (' .. kind:lower() .. ')' -- "claude (agent)": never mistaken for the user
  end
  return a.name or kind
end

---Highlight of an author: agents and AI stand out from the user.
local function author_hl(a)
  if a and a.kind == 'forge' then
    return 'RevueyForgeAuthor'
  end
  return a and (a.kind == 'agent' or a.kind == 'ai') and 'RevueyCommentAgent' or 'RevueyCommentAuthor'
end

---Virtual lines of one thread.
---@param p revuey.CommentPlacement
local function thread_lines(s, c, p, width)
  local expanded = cm(s).expanded[c.id]
  local max = opt('max_lines', 6)
  local B = 'RevueyCommentBorder'
  local lines = {}
  local head = { { '╭─ ', B }, { author_label(c.author), author_hl(c.author) }, { ' · ' .. ago(c.updated_at or c.created_at), 'RevueyCommentMeta' } }
  local used = 3 + api.nvim_strwidth(author_label(c.author)) + api.nvim_strwidth(head[3][1])
  local function chip(text, hl)
    head[#head + 1] = { ' · ', 'RevueyCommentMeta' }
    head[#head + 1] = { text, hl }
    used = used + 3 + api.nvim_strwidth(text)
  end
  local g = c.forge
  if g then
    -- a GitHub review thread (read-only): its PR first, then its state there
    head[1] = { '╭─ ', 'RevueyForgeBorder' }
    head[#head + 1] = { ' · ', 'RevueyCommentMeta' }
    head[#head + 1] = { 'GitHub #' .. g.pr, 'RevueyForgeNumber' }
    used = used + 3 + api.nvim_strwidth('GitHub #' .. g.pr)
  end
  if c.file_level then
    chip('file', 'RevueyCommentMeta')
  end
  if g then
    if g.pending then
      chip('pending (your unsubmitted review)', 'RevueyCommentDraft')
    end
    if g.resolved then
      chip(g.resolved_by and ('resolved by ' .. g.resolved_by) or 'resolved', 'RevueyCommentResolved')
    end
    if g.outdated then
      chip('outdated', 'RevueyCommentOutdated')
    end
    if p.how == 'moved' then
      chip('GitHub line ' .. tostring(c.anchor.start_line), 'RevueyCommentMeta')
    end
  end
  if c.forge_reply then
    chip('local reply to GitHub #' .. tostring(c.forge_reply.pr) .. ' thread', 'RevueyForgeNumber')
  end
  if c.ai and c.status ~= 'accepted' then
    chip(c.ai.severity or 'minor', M.SEVERITY_HL[c.ai.severity] or 'RevueyAiMinor')
  end
  if g then
    -- a GitHub thread's state is in its own chips above
  elseif c.status == 'draft' then
    chip('draft', 'RevueyCommentDraft')
  elseif c.status == 'resolved' then
    chip('resolved', 'RevueyCommentResolved')
  elseif c.status == 'dismissed' then
    chip('dismissed', 'RevueyCommentResolved')
  elseif c.status == 'accepted' then
    chip('accepted from AI review', 'RevueyCommentMeta')
  elseif require('revuey.ai_review').untriaged(c) then
    local k = config.options.keymaps
    local hint = {}
    for _, x in ipairs({ { k.comment_accept, 'accept' }, { k.comment_dismiss, 'dismiss' } }) do
      local key = type(x[1]) == 'table' and x[1][1] or x[1]
      if key then
        hint[#hint + 1] = key .. ' ' .. x[2]
      end
    end
    if #hint > 0 then
      chip(table.concat(hint, ' · '), 'RevueyAiTriage')
    end
  end
  if c.draft or c.reply_draft then
    chip('unsaved edit', 'RevueyCommentDraft')
  end
  local d = M.delivery_label(s, c)
  if d then
    chip(d.text, d.hl)
  end
  if p.outdated then
    chip(p.how == 'missing' and 'file not in this review' or ('outdated · was ' .. comments.location(c)), 'RevueyCommentOutdated')
  end
  head[#head + 1] = { ' ' .. fill(width, used + 1), B }
  lines[#lines + 1] = head
  local body = {}
  local function add_text(md, first, rest)
    local rendered = prose.render(md or '', width - api.nvim_strwidth(rest) - 2)
    while #rendered > 0 and rendered[#rendered].text == '' do
      rendered[#rendered] = nil
    end
    for i, l in ipairs(rendered) do
      local ch = { { i == 1 and first or rest, B } }
      vim.list_extend(ch, chunks(l, 'RevueyCommentText'))
      body[#body + 1] = ch
    end
  end
  -- resolved, dismissed and (GitHub) outdated threads are collapsed to their first line
  local resolved = (c.status == 'resolved' or c.status == 'dismissed' or (g and g.outdated)) and not expanded
  add_text(c.body, '│ ', '│ ')
  for _, r in ipairs(c.thread or {}) do
    if not r.deleted then
      local rh = {
        { '│ ↳ ', B },
        { author_label(r.author), author_hl(r.author) },
        { ' · ' .. ago(r.created_at), 'RevueyCommentMeta' },
      }
      if r.pending then
        rh[#rh + 1] = { ' · pending', 'RevueyCommentDraft' }
      end
      body[#body + 1] = rh
      add_text(r.body, '│   ', '│   ')
    end
  end
  if g and g.hidden > 0 then
    body[#body + 1] = { { '│ ', B }, { ('… %d more on GitHub'):format(g.hidden), 'RevueyCommentMeta' } }
  end
  local limit = resolved and 1 or max
  if not expanded and #body > limit then
    local hidden = #body - limit
    for i = 1, limit do
      lines[#lines + 1] = body[i]
    end
    local k = config.options.keymaps.comment_expand
    lines[#lines + 1] = {
      { '│ ', B },
      { ('… %d more line%s%s'):format(hidden, hidden == 1 and '' or 's', k and (' (' .. k .. ' expands)') or ''), 'RevueyCommentMeta' },
    }
  else
    vim.list_extend(lines, body)
  end
  lines[#lines + 1] = { { '╰─', B } }
  if g then
    -- the GitHub thread's border, so it never reads as a local comment
    for _, l in ipairs(lines) do
      for _, ch in ipairs(l) do
        if ch[2] == B then
          ch[2] = 'RevueyForgeBorder'
        end
      end
    end
  end
  return lines
end

---Marker of a comment sent to an agent: {text, hl}, or nil when it was never sent. It follows the
---message's delivery, not who is connected now: once a watch printed it, it stays "sent".
function M.delivery_label(s, c)
  local d = comments.delivery(c)
  if d == 'delivered' then
    return { text = 'sent → agent', hl = 'RevueyCommentSent' }
  elseif d == 'sent' then
    if require('revuey.agent_link').connected(s) then
      return { text = 'sending → agent', hl = 'RevueyCommentSent' }
    end
    return { text = 'queued: no agent connected', hl = 'RevueyCommentQueued' }
  elseif d == 'seen' then
    return { text = 'seen by agent', hl = 'RevueyCommentSent' }
  elseif d == 'answered' then
    return { text = 'answered', hl = 'RevueyCommentAnswered' }
  end
end

local SIGN_HL = { draft = 'RevueyCommentDraft', resolved = 'RevueyCommentResolved', dismissed = 'RevueyCommentResolved' }

---Highlight of an AI finding's severity.
M.SEVERITY_HL = { critical = 'RevueyAiCritical', major = 'RevueyAiMajor', minor = 'RevueyAiMinor', nit = 'RevueyAiNit' }

---Place every comment in the current review and draw threads and signs. `persist`: save
---changed "last known" anchors (renders after the review changed; never on live reloads).
---@param o? {persist?:boolean}
function M.render(s, o)
  o = o or {}
  local c = cm(s)
  local store = M.sync_store(s)
  local ctx = context(s)
  local idx = row_index(s)
  local buf = s.diff_buf
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  c.place, c.signs, c.cover, c.jump, c.counts = {}, {}, {}, {}, {}
  c.orphans = 0
  local attach = {} -- row -> list of {c, p, group}
  local changed = false
  local all = comments.list(store, { include_resolved = true, include_drafts = true })
  for _, cmt in ipairs(all) do
    local p = comments.place(cmt, ctx)
    c.place[cmt.id] = p
    -- a comment from `bin/revuey comment` has no unit yet: store the one found here even on a
    -- live reload (once, so instances in different modes cannot ping-pong)
    local resolve = not o.persist and comments.unresolved(cmt) and p.unit ~= nil and not p.outdated
    if (o.persist or resolve) and comments.apply_placement(cmt, p) then
      store._dirty[cmt.id] = true
      changed = true
    end
    local path = p.path or cmt.anchor.path
    local open = cmt.status ~= 'resolved' and cmt.status ~= 'dismissed'
    if open then
      c.counts[path] = (c.counts[path] or 0) + 1
    end
    local row, group, first
    if cmt.file_level then
      row = idx.file_row[path]
      first = row
    elseif not p.outdated then
      local L = idx.lines[path] and idx.lines[path][cmt.anchor.side]
      first = L and L[p.start_line]
      row = L and L[p.end_line]
      if first and row and row < first then
        first, row = row, first
      end
    else
      local L = idx.lines[path] and idx.lines[path][cmt.anchor.side]
      row = L and L[p.end_line or 0]
      if row then
        first = L[p.start_line or 0] or row
        if first > row then
          first = row
        end
      else
        row = idx.file_last[path]
        group = row and 'outdated' or nil
        first = row
      end
    end
    if not row then
      -- the file is not shown (it left the review): a group at the end of the buffer, so the
      -- comment stays visible, navigable and listed
      row = #s.layout.lines
      first = row
      group = p.how == 'missing' and 'missing' or 'hidden'
      if open then
        c.orphans = c.orphans + 1
      end
    end
    if row > 0 then
      local hl = p.outdated and 'RevueyCommentOutdated' or SIGN_HL[cmt.status] or 'RevueyCommentSign'
      for r = first, row do
        if not group then
          c.signs[r] = c.signs[r] == 'RevueyCommentSign' and c.signs[r] or hl
        end
        c.cover[r] = c.cover[r] or {}
        table.insert(c.cover[r], cmt.id)
      end
      c.jump[cmt.id] = first
      attach[row] = attach[row] or {}
      table.insert(attach[row], { c = cmt, p = p, group = group })
    end
  end
  if changed then
    pcall(comments.save, store, M.review_info(s))
  end
  M.place_forge(s, ctx, idx, attach)
  local width = thread_width(s)
  if not c.hidden then
    for row, items in pairs(attach) do
      local vl = {}
      local headed = {}
      -- in-file items first, then outdated, then the end-of-review groups; GitHub threads after
      -- local comments, in the order they were started
      local rank = { outdated = 1, gh_outside = 2, missing = 3, hidden = 4, gh_missing = 5 }
      table.sort(items, function(x, y)
        local rx, ry = rank[x.group] or 0, rank[y.group] or 0
        if rx ~= ry then
          return rx < ry
        end
        local fx, fy = x.c.forge ~= nil, y.c.forge ~= nil
        if fx ~= fy then
          return fy
        elseif fx and x.c.created_at ~= y.c.created_at then
          return x.c.created_at < y.c.created_at
        end
        return x.c.id < y.c.id
      end)
      local titles = {
        outdated = 'Outdated comments',
        missing = 'Comments on files no longer in this review',
        hidden = 'Comments on files not shown in this view',
        gh_outside = 'GitHub threads on lines not shown here',
        gh_missing = 'GitHub threads on files not shown here',
      }
      for _, it in ipairs(items) do
        if it.group and not headed[it.group] then
          headed[it.group] = true
          vl[#vl + 1] = { { '' } }
          vl[#vl + 1] = { { titles[it.group], 'RevueyCommentOutdated' } }
        end
        if it.group == 'missing' or it.group == 'hidden' or it.group == 'gh_missing' then
          vl[#vl + 1] = { { comments.location(it.c) .. ' (' .. (it.c.file_level and 'file' or it.c.anchor.side) .. ')', 'RevueyFilePath' } }
        end
        vim.list_extend(vl, thread_lines(s, it.c, it.p, width))
      end
      pcall(api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, { virt_lines = vl, priority = 30 })
    end
  end
  -- statuscolumn signs are drawn by view.statuscolumn from c.signs
  -- (with no UI attached there is nothing to redraw, and a headless redraw can crash Neovim)
  if #api.nvim_list_uis() > 0 and s.diff_win and api.nvim_win_is_valid(s.diff_win) then
    pcall(api.nvim__redraw, { win = s.diff_win, statuscolumn = true, valid = false })
  end
end

---Place the GitHub review threads of the scope's open PRs (forge_view.thread_items) and add them
---to `attach` like comments: on their lines, else in a group at the end of their file ("not
---shown here": outdated, changed locally, outside the hunks), else at the end of the review.
---Gutter bars, `cover` (so `cz`, `cr` and `gx` find them) and `jump` (`]m`, the list) as for
---comments; the items live in `c.forge_items` only, never in the comments store.
function M.place_forge(s, ctx, idx, attach)
  local c = cm(s)
  c.forge_items, c.forge_place, c.forge_rows = {}, {}, {}
  local fv = require('revuey.forge_view')
  local items = fv.thread_items(s)
  if s.forge then
    s.forge.threads_drawn = fv.threads_signature(s)
  end
  local show = forge_show(s)
  if show == 'none' then
    return
  end
  local ft = require('revuey.forge_threads')
  for _, x in ipairs(items) do
    local it = x.item
    if not (show == 'open' and it.status == 'resolved') then
      local p = ft.place(x.thread, ctx)
      c.forge_items[it.id] = it
      c.forge_place[it.id] = p
      local path = p.path
      local row, first, group
      if p.how == 'file' then
        row = idx.file_row[path]
        first = row
      elseif p.how == 'line' or p.how == 'moved' then
        local L = idx.lines[path] and idx.lines[path][p.side]
        first, row = L and L[p.start_line], L and L[p.end_line]
        if first and row and row < first then
          first, row = row, first
        end
        first = first or row
      end
      if not row and p.how ~= 'missing' then
        row = idx.file_last[path]
        first = row
        group = row and 'gh_outside' or nil
      end
      if not row then
        row = #s.layout.lines
        first = row
        group = 'gh_missing'
      end
      if row > 0 then
        local hl = (it.forge.resolved or it.forge.outdated) and 'RevueyCommentResolved' or 'RevueyForgeSign'
        for r = first, row do
          if not group and not c.signs[r] then
            c.signs[r] = hl -- a local comment's bar wins on a shared row
          end
          c.cover[r] = c.cover[r] or {}
          table.insert(c.cover[r], it.id)
        end
        c.jump[it.id] = first
        c.forge_rows[it.id] = { first = first, last = row, group = group }
        attach[row] = attach[row] or {}
        table.insert(attach[row], { c = it, p = p, group = group })
      end
    end
  end
end

---`gH`: cycle the GitHub threads shown: all (resolved and outdated collapsed), open only, none.
function M.toggle_forge(s)
  if not s then
    return
  end
  local c = cm(s)
  local cur = forge_show(s)
  for i, v in ipairs(FORGE_SHOW) do
    if v == cur then
      c.forge_show = FORGE_SHOW[i % #FORGE_SHOW + 1]
    end
  end
  M.render(s)
  local text = { all = 'all (resolved and outdated collapsed)', open = 'open only (resolved hidden)', none = 'hidden' }
  vim.notify('revuey: GitHub threads: ' .. text[c.forge_show], vim.log.levels.INFO)
end

---Redraw comments (and the panel's counts) without re-rendering the review.
function M.refresh(s)
  if not s or s.cleaned or not s.layout or not api.nvim_buf_is_valid(s.diff_buf) then
    return
  end
  M.render(s)
  require('revuey.panel').render(s)
end

---Gutter mark for a row (statuscolumn), or nil.
function M.sign(s, row)
  local c = s.cm
  return c and c.signs and c.signs[row]
end

---Open comments on files the view does not show (panel).
function M.orphans(s)
  return s.cm and s.cm.orphans or 0
end

---Unresolved comments on a file (panel).
function M.count(s, path)
  local c = s.cm
  return c and c.counts and c.counts[path] or 0
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

---Save `store` (default: the session's) and append an event of `kind` (nil: none, e.g. a draft).
---An editor opened before a scope switch still saves to the store it was opened for.
local function save_and_emit(s, kind, cmt, extra, store, sent)
  local c = cm(s)
  store = store or c.store
  local current = store == c.store
  local info = current and M.review_info(s) or nil
  local ok, err = pcall(comments.save, store, info)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  local events = (store.path:gsub('%.comments%.json$', '.events.jsonl'))
  if kind then
    comments.append_event(events, comments.event(kind, cmt, info or store.review, extra))
  end
  if sent then
    -- the message for the agent: the comment as saved, with the review it belongs to. Only once
    -- the comment is on disk (a save deferred by a busy lock lands later): `show`, `reply` and
    -- catch-up read the comments file, so the event must never get there first.
    local ev = comments.sent_event(sent, info or store.review)
    require('revuey.lock').after(store.path, function()
      comments.append_event(events, ev)
    end)
  end
  if current then
    M.refresh(s)
  end
  return true
end

local function editor_col(s)
  return 2 * (s.numw or 3) + 4
end

local function title(anchor, file_level)
  if file_level then
    return anchor.path .. ' (file)'
  end
  local c = { anchor = anchor }
  return comments.location(c) .. ' (' .. anchor.side .. ')'
end

local function send_hook(s, kind, anchor, cmt, store)
  return function(text)
    return M.actions.send({ session = s, kind = kind, anchor = anchor, comment = cmt, text = text, store = store })
  end
end

---`gc`: comment on rows first..last of the diff or guide (a file header or hunk header: the
---whole file). `ask` (`ga`): the same editor, titled as a question for the agent, where <C-a>
---sends (and <C-s> still only saves).
function M.add(s, first, last, ask)
  if not s or #s.review.files == 0 then
    return
  end
  if first > last then
    first, last = last, first
  end
  local store = M.sync_store(s)
  local map = s.layout.map
  local entries = {}
  for row = first, last do
    entries[#entries + 1] = map[row]
  end
  local anchor = comments.anchor_from_rows(s.review.files, review_mod.units(s.review), entries, context(s).get_line)
  local file_level = false
  if anchor then
    local files_seen = {}
    for _, e in ipairs(entries) do
      if e and (e.kind == 'add' or e.kind == 'del' or e.kind == 'ctx') then
        files_seen[e.file_idx] = true
      end
    end
    if vim.tbl_count(files_seen) > 1 then
      vim.notify('revuey: the selection spans several files; the comment is on ' .. anchor.path .. ' only', vim.log.levels.WARN)
      -- the editor goes under that file's last selected row
      for r = last, first, -1 do
        local e = map[r]
        if e and e.path == anchor.path and (e.kind == 'add' or e.kind == 'del' or e.kind == 'ctx') then
          last = r
          break
        end
      end
    end
  end
  local row = last
  if anchor then
    -- attach the editor under the last row of the range
    for r = last, first, -1 do
      local e = map[r]
      if e and (e.kind == 'add' or e.kind == 'del' or e.kind == 'ctx') then
        row = r
        break
      end
    end
  else
    local e = map[first]
    if not (e and e.file_idx and e.file_idx > 0 and e.kind == 'meta' and e.path) then
      return vim.notify('revuey: move to a diff line or a file header to comment', vim.log.levels.INFO)
    end
    anchor = comments.file_anchor(e.path)
    file_level = true
    row = first
  end
  local function new(text, status)
    local cmt = comments.new(anchor, text, { status = status })
    comments.put(store, cmt)
    return cmt
  end
  local send_key = config.options.keymaps.comment_send
  editor.open({
    session = s,
    title = (ask and 'Ask agent · ' or '') .. title(anchor, file_level),
    footer = ask and send_key and (' ' .. send_key .. ' send  <C-s> save only  q cancel ') or nil,
    win = s.diff_win,
    return_win = s.diff_win,
    row = row,
    col = editor_col(s),
    startinsert = true,
    on_save = function(text)
      local cmt = new(text, 'saved')
      save_and_emit(s, 'created', cmt, nil, store)
    end,
    on_draft = function(text)
      new(text, 'draft')
      save_and_emit(s, nil, nil, nil, store)
      vim.notify('revuey: comment kept as a draft (' .. (config.options.keymaps.comment_edit or 'edit') .. ' to continue)', vim.log.levels.INFO)
    end,
    on_send = send_hook(s, ask and 'ask' or 'comment', anchor, nil, store),
  })
end

---The comment as it is now, after reading the file (another instance or the CLI may have
---deleted it since this one last looked); nil when it is gone. `text`: what the user was about to
---save, kept in the unnamed register with a message.
local function still_there(store, id, text)
  pcall(comments.reload, store)
  local cur = comments.get(store, id)
  if not cur then
    if text and text ~= '' then
      vim.fn.setreg('"', text)
    end
    vim.notify(
      'revuey: this comment was deleted elsewhere' .. ((text and text ~= '') and '; your text is in the unnamed register' or ''),
      vim.log.levels.WARN
    )
  end
  return cur
end

---Comments covering the cursor row (sign range or thread). Calls fn with one comment, asking
---which when several cover the row.
function M.with_comment(s, fn, row)
  if not s then
    return
  end
  local c = cm(s)
  row = row or api.nvim_win_get_cursor(s.diff_win)[1]
  local ids = c.cover and c.cover[row] or {}
  local list = {}
  for _, id in ipairs(ids) do
    local cmt = comments.get(c.store, id) or (c.forge_items and c.forge_items[id])
    if cmt then
      list[#list + 1] = cmt
    end
  end
  if #list == 0 then
    return vim.notify('revuey: no comment on this line', vim.log.levels.INFO)
  elseif #list == 1 then
    return fn(list[1])
  end
  vim.ui.select(list, {
    prompt = 'Comment',
    format_item = function(x)
      return comments.location(x) .. '  ' .. (x.forge and ('[GitHub #' .. x.forge.pr .. '] ') or '') .. comments.first_line(x.body)
    end,
  }, function(choice)
    if choice then
      fn(choice)
    end
  end)
end

---A GitHub thread under the cursor for an action that only works on local comments: says so
---(and how to act on it) and returns true.
local function forge_refused(cmt, what)
  if not cmt.forge then
    return false
  end
  local k = config.options.keymaps
  local key = function(x)
    return type(x) == 'table' and x[1] or x
  end
  vim.notify(
    ('revuey: GitHub threads are read-only here: %s it on GitHub (%s opens it)%s'):format(
      what,
      key(k.forge_open) or 'gx',
      key(k.comment_reply) and ('; ' .. key(k.comment_reply) .. ' adds a local reply') or ''
    ),
    vim.log.levels.INFO
  )
  return true
end

local function attach_row(s, cmt)
  local c = cm(s)
  local row = c.jump[cmt.id]
  for r, ids in pairs(c.cover or {}) do
    for _, id in ipairs(ids) do
      if id == cmt.id and (not row or r > row) then
        row = r
      end
    end
  end
  return row or api.nvim_win_get_cursor(s.diff_win)[1]
end

---`ce`: edit a comment (a draft continues where it was left).
function M.edit(s)
  M.with_comment(s, function(cmt)
    if forge_refused(cmt, 'edit') then
      return
    end
    local store = cm(s).store
    local was_draft = cmt.status == 'draft'
    local function update(fn, text)
      local cur = still_there(store, cmt.id, text)
      if not cur then
        return nil -- deleted elsewhere: never resurrect it
      end
      local copy = vim.deepcopy(cur)
      fn(copy)
      comments.put(store, copy)
      return copy
    end
    editor.open({
      session = s,
      title = title(cmt.anchor, cmt.file_level),
      win = s.diff_win,
      return_win = s.diff_win,
      row = attach_row(s, cmt),
      col = editor_col(s),
      text = cmt.draft or cmt.body,
      on_save = function(text)
        local c2 = update(function(x)
          x.body, x.draft = text, nil
          if was_draft then
            x.status = 'saved'
          end
        end, text)
        if c2 then
          save_and_emit(s, was_draft and 'created' or 'updated', c2, nil, store)
        else
          M.refresh(s)
        end
      end,
      on_draft = function(text)
        if update(function(x)
          if x.status == 'draft' then
            x.body = text
          else
            x.draft = text
          end
        end, text) then
          save_and_emit(s, nil, nil, nil, store)
        end
      end,
      on_cancel = function()
        if cmt.draft and update(function(x)
          x.draft = nil
        end) then
          save_and_emit(s, nil, nil, nil, store)
        end
      end,
      on_send = send_hook(s, 'comment', cmt.anchor, cmt, store),
    })
  end)
end

---`cr`: reply to a comment's thread.
function M.reply(s)
  M.with_comment(s, function(cmt)
    if cmt.forge then
      return M.reply_forge(s, cmt)
    end
    local store = cm(s).store
    editor.open({
      session = s,
      title = 'Reply · ' .. title(cmt.anchor, cmt.file_level),
      win = s.diff_win,
      return_win = s.diff_win,
      row = attach_row(s, cmt),
      col = editor_col(s),
      text = cmt.reply_draft,
      startinsert = true,
      on_save = function(text)
        local cur = still_there(store, cmt.id, text)
        if not cur then
          return M.refresh(s)
        end
        if cur.reply_draft then
          local copy = vim.deepcopy(cur)
          copy.reply_draft = nil
          comments.put(store, copy)
        end
        local r = comments.reply(store, cmt.id, text, { kind = 'user' })
        if r then
          save_and_emit(s, 'replied', comments.get(store, cmt.id), { reply = r }, store)
        end
      end,
      on_draft = function(text)
        local cur = still_there(store, cmt.id, text)
        if cur then
          local copy = vim.deepcopy(cur)
          copy.reply_draft = text
          comments.put(store, copy)
          save_and_emit(s, nil, nil, nil, store)
        end
      end,
      on_send = send_hook(s, 'reply', cmt.anchor, cmt, store),
    })
  end)
end

---`cr` on a GitHub thread: a reply that stays local. It is a new local comment on the thread's
---rows (anchored like a selection of them, so it re-anchors as any comment) carrying
---`forge_reply` (the thread, its PR and the last comment's ids), so a later "post review" can send
---it as a reply in that thread. Nothing goes to GitHub. Refused for a thread not on shown lines.
function M.reply_forge(s, item)
  local c = cm(s)
  local p = c.forge_place and c.forge_place[item.id]
  local rows = c.forge_rows and c.forge_rows[item.id]
  if not p or not rows or rows.group then
    return vim.notify(
      'revuey: this GitHub thread is not on a line shown here, so a local reply has nowhere to go; '
        .. 'gx opens it on GitHub',
      vim.log.levels.INFO
    )
  end
  local store = M.sync_store(s)
  local anchor, file_level
  if p.how == 'file' then
    anchor, file_level = comments.file_anchor(p.path), true
  else
    local entries = {}
    for r = rows.first, rows.last do
      entries[#entries + 1] = s.layout.map[r]
    end
    anchor = comments.anchor_from_rows(s.review.files, review_mod.units(s.review), entries, context(s).get_line)
    if not anchor then
      return vim.notify('revuey: no diff line to anchor a reply to', vim.log.levels.INFO)
    end
  end
  local g = item.forge
  local link = {
    thread_id = g.thread_id,
    pr = g.pr,
    repo = g.repo,
    url = g.url,
    comment_id = g.comment_id,
    database_id = g.database_id,
  }
  local function new(text, status)
    local cmt = comments.new(anchor, text, { status = status })
    cmt.forge_reply = link
    comments.put(store, cmt)
    return cmt
  end
  editor.open({
    session = s,
    title = ('Local reply · GitHub #%d · %s'):format(g.pr, title(anchor, file_level)),
    win = s.diff_win,
    return_win = s.diff_win,
    row = rows.last,
    col = editor_col(s),
    startinsert = true,
    on_save = function(text)
      local cmt = new(text, 'saved')
      save_and_emit(s, 'created', cmt, { forge_reply = link }, store)
    end,
    on_draft = function(text)
      new(text, 'draft')
      save_and_emit(s, nil, nil, nil, store)
    end,
  })
end

---`cx`: resolve, or reopen a resolved comment.
function M.resolve(s)
  M.with_comment(s, function(cmt)
    if forge_refused(cmt, 'resolve') then
      return
    end
    if cmt.status == 'draft' then
      return vim.notify('revuey: save the draft first', vim.log.levels.INFO)
    end
    local cur = still_there(cm(s).store, cmt.id)
    if not cur then
      return M.refresh(s)
    end
    local copy = vim.deepcopy(cur)
    -- reopening an accepted AI finding makes it accepted again (still your comment)
    local reopened = (cur.ai and cur.ai.accepted_at) and 'accepted' or 'saved'
    copy.status = cur.status == 'resolved' and reopened or 'resolved'
    comments.put(cm(s).store, copy)
    save_and_emit(s, 'resolved', copy)
  end)
end

---Comments covering the cursor row that are AI findings (with_comment, but only those: a user
---comment on the same line never gets in the way).
local function with_finding(s, fn)
  local c = cm(s)
  local row = api.nvim_win_get_cursor(s.diff_win)[1]
  local any = false
  for _, id in ipairs(c.cover and c.cover[row] or {}) do
    local x = comments.get(c.store, id)
    if x and x.ai then
      any = true
    end
  end
  if not any then
    return vim.notify('revuey: no AI review finding on this line', vim.log.levels.INFO)
  end
  local saved = c.cover[row]
  c.cover[row] = vim.tbl_filter(function(id)
    local x = comments.get(c.store, id)
    return x ~= nil and x.ai ~= nil
  end, saved)
  local ok, err = pcall(M.with_comment, s, fn, row)
  c.cover[row] = saved
  if not ok then
    error(err, 0)
  end
end

---`ca`: accept the AI finding on this line: it becomes your own comment (kept for the forge's
---"add to review" later).
function M.accept(s)
  if not s then
    return
  end
  with_finding(s, function(cmt)
    local store = cm(s).store
    if not still_there(store, cmt.id) then
      return M.refresh(s)
    end
    local c, err = require('revuey.ai_review').accept(store, cmt.id)
    if not c then
      return vim.notify('revuey: ' .. err, vim.log.levels.INFO)
    end
    save_and_emit(s, 'accepted', c)
  end)
end

---`cn`: dismiss the AI finding on this line (kept, collapsed), or restore a dismissed one.
function M.dismiss(s)
  if not s then
    return
  end
  with_finding(s, function(cmt)
    local store = cm(s).store
    if not still_there(store, cmt.id) then
      return M.refresh(s)
    end
    local c, err = require('revuey.ai_review').toggle_dismiss(store, cmt.id)
    if not c then
      return vim.notify('revuey: ' .. err, vim.log.levels.INFO)
    end
    save_and_emit(s, 'dismissed', c)
  end)
end

-- ---------------------------------------------------------------------------
-- Sending to the coding-agent session
-- ---------------------------------------------------------------------------

---This review's session id (the registry's): messages are routed to its watchers.
local function link_id(s)
  return s.link and s.link.id or tostring(vim.uv.os_getpid())
end

local function notify_sent(s, c)
  local where = comments.location(c)
  if require('revuey.agent_link').connected(s) then
    vim.notify('revuey: sent to the agent (' .. where .. ')', vim.log.levels.INFO)
  else
    vim.notify(
      'revuey: queued: no agent connected (' .. where .. '); an agent running `bin/revuey watch` gets it when it connects',
      vim.log.levels.INFO
    )
  end
end

---Send to the agent session watching this review (the editor's <C-a>): the text is saved as the
---comment (new, or an edit of `req.comment`) or, for `kind = 'reply'`, as a reply in its thread;
---the comment is marked sent and a `sent` event goes to the feed. With no agent connected the
---message waits there (`bin/revuey watch` catches up on connect).
---@param req {session:table, kind:'comment'|'ask'|'reply', anchor:table, comment?:table, text:string, store?:table}
function M.send_to_agent(req)
  local s = req.session
  if not s or s.cleaned then
    return false
  end
  local text = vim.trim(req.text or '')
  if text == '' then
    vim.notify('revuey: empty message not sent (q cancels)', vim.log.levels.WARN)
    return false
  end
  local store = req.store or M.sync_store(s)
  local c = req.comment
  local kind, extra, sent
  if c then
    local cur = still_there(store, c.id, text)
    if not cur then
      M.refresh(s)
      return true
    end
    if req.kind == 'reply' then
      if cur.reply_draft then
        local copy = vim.deepcopy(cur)
        copy.reply_draft = nil
        comments.put(store, copy)
      end
      local r = comments.reply(store, c.id, text, { kind = 'user' })
      sent = comments.mark_sent(store, c.id, { reply_id = r.id, session = link_id(s) })
      kind, extra = 'replied', { reply = r }
    else
      local copy = vim.deepcopy(cur)
      local was_draft = copy.status == 'draft'
      local changed = copy.body ~= text
      copy.body, copy.draft = text, nil
      if was_draft then
        copy.status = 'saved'
      end
      comments.put(store, copy)
      sent = comments.mark_sent(store, c.id, { session = link_id(s) })
      kind = was_draft and 'created' or (changed and 'updated' or nil)
    end
  else
    local new = comments.new(req.anchor, text, { status = 'saved' })
    comments.put(store, new)
    sent = comments.mark_sent(store, new.id, { session = link_id(s) })
    kind = 'created'
  end
  if save_and_emit(s, kind, sent, extra, store, sent) then
    notify_sent(s, sent)
  end
  return true
end

---`cs`: send the comment under the cursor to the agent session (again, when it was sent before).
function M.send_existing(s)
  M.with_comment(s, function(cmt)
    if forge_refused(cmt, 'answer') then
      return
    end
    local store = cm(s).store
    local cur = still_there(store, cmt.id)
    if not cur then
      return M.refresh(s)
    end
    local kind
    if cur.status == 'draft' then
      local copy = vim.deepcopy(cur)
      copy.status = 'saved'
      comments.put(store, copy)
      kind = 'created'
    end
    local sent = comments.mark_sent(store, cmt.id, { session = link_id(s) })
    if save_and_emit(s, kind, sent, nil, store, sent) then
      notify_sent(s, sent)
    end
  end)
end

---`ga`: ask the agent about rows first..last (a line, a selection, a file header).
function M.ask(s, first, last)
  return M.add(s, first, last, true)
end

---Ask before deleting; tests replace this.
function M.confirm_delete(msg)
  return vim.fn.confirm(msg, '&Delete\n&Cancel', 2) == 1
end

---`cd`: delete a comment (asks first).
function M.delete(s)
  M.with_comment(s, function(cmt)
    if forge_refused(cmt, 'delete') then
      return
    end
    if not M.confirm_delete('revuey: delete the comment on ' .. comments.location(cmt) .. '?') then
      return
    end
    comments.delete(cm(s).store, cmt.id)
    save_and_emit(s, 'deleted', cmt)
  end)
end

---`cz`: expand or collapse a long (or resolved) comment.
function M.toggle_expand(s)
  M.with_comment(s, function(cmt)
    local c = cm(s)
    c.expanded[cmt.id] = not c.expanded[cmt.id] or nil
    M.render(s)
  end)
end

---`gC`: show or hide the threads (signs stay).
function M.toggle_visible(s)
  if not s then
    return
  end
  local c = cm(s)
  c.hidden = not c.hidden
  M.render(s)
  vim.notify('revuey: comments ' .. (c.hidden and 'hidden' or 'shown'), vim.log.levels.INFO)
end

local function goto_row(s, row)
  api.nvim_set_current_win(s.diff_win)
  api.nvim_win_call(s.diff_win, function()
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(0, { row, 0 })
    vim.cmd('normal! zv')
    local top, bot = vim.fn.line('w0'), vim.fn.line('w$')
    if row < top or row >= bot - 1 then
      vim.cmd('normal! zz')
    end
  end)
end

---`]m` / `[m`: next or previous comment (takes a count).
function M.next(s, dir)
  if not s or not s.cm or not s.cm.jump then
    return
  end
  local rows, seen = {}, {}
  for _, r in pairs(s.cm.jump) do
    if not seen[r] then
      seen[r] = true
      rows[#rows + 1] = r
    end
  end
  table.sort(rows)
  if #rows == 0 then
    return vim.notify('revuey: no comments in this review', vim.log.levels.INFO)
  end
  local row = api.nvim_win_get_cursor(s.diff_win)[1]
  local target
  for _ = 1, vim.v.count1 do
    local t
    if dir > 0 then
      for _, r in ipairs(rows) do
        if r > row then
          t = r
          break
        end
      end
    else
      for i = #rows, 1, -1 do
        if rows[i] < row then
          t = rows[i]
          break
        end
      end
    end
    if not t then
      break
    end
    row, target = t, t
  end
  if target then
    goto_row(s, target)
  end
end

---Jump to a comment by id (from the list).
function M.jump(s, id)
  local row = s.cm and s.cm.jump and s.cm.jump[id]
  if not row then
    return vim.notify('revuey: this comment is not shown in this view', vim.log.levels.INFO)
  end
  goto_row(s, row)
end

-- ---------------------------------------------------------------------------
-- Comments list
-- ---------------------------------------------------------------------------

M.list_state = nil

---Lines of the comments list: {text, id?, hls}.
function M.list_lines(s)
  local c = cm(s)
  local store = M.sync_store(s)
  local list = comments.list(store, { include_resolved = true, include_drafts = true })
  local out = {}
  local path
  for _, cmt in ipairs(list) do
    if cmt.anchor.path ~= path then
      path = cmt.anchor.path
      if #out > 0 then
        out[#out + 1] = { text = '' }
      end
      out[#out + 1] = { text = path, hls = { { 0, #path, 'RevueyFilePath' } } }
    end
    local p = c.place and c.place[cmt.id] or { outdated = cmt.outdated }
    local where = cmt.file_level and 'file' or (cmt.anchor.start_line == cmt.anchor.end_line and tostring(cmt.anchor.start_line) or (cmt.anchor.start_line .. '-' .. cmt.anchor.end_line))
    where = '  ' .. where .. ' (' .. (cmt.file_level and 'file' or cmt.anchor.side) .. ')'
    local tags = {}
    if cmt.ai and cmt.status ~= 'accepted' then
      tags[#tags + 1] = cmt.ai.severity or 'minor'
    end
    if cmt.status == 'resolved' then
      tags[#tags + 1] = '✓ resolved'
    elseif cmt.status == 'draft' then
      tags[#tags + 1] = 'draft'
    elseif cmt.status == 'dismissed' then
      tags[#tags + 1] = 'dismissed'
    elseif cmt.status == 'accepted' then
      tags[#tags + 1] = 'accepted from AI review'
    elseif require('revuey.ai_review').untriaged(cmt) then
      tags[#tags + 1] = 'to triage'
    end
    if cmt.author and cmt.author.kind and cmt.author.kind ~= 'user' then
      tags[#tags + 1] = 'by ' .. author_label(cmt.author)
    end
    if cmt.forge_reply then
      tags[#tags + 1] = 'local reply to GitHub #' .. tostring(cmt.forge_reply.pr)
    end
    if p.how == 'missing' then
      tags[#tags + 1] = 'not in this review'
    elseif p.outdated then
      tags[#tags + 1] = 'outdated'
    end
    local n = 0
    for _, r in ipairs(cmt.thread or {}) do
      n = n + (r.deleted and 0 or 1)
    end
    if n > 0 then
      tags[#tags + 1] = n .. (n == 1 and ' reply' or ' replies')
    end
    local d = M.delivery_label(s, cmt)
    if d then
      tags[#tags + 1] = d.text
    end
    local tag = #tags > 0 and ('  [' .. table.concat(tags, ', ') .. ']') or ''
    local first = comments.first_line(cmt.body):gsub('^%*%*(.-)%*%*$', '%1')
    local text = where .. '  ' .. first .. tag
    out[#out + 1] = {
      text = text,
      id = cmt.id,
      hls = { { 0, #where, 'RevueyCommentMeta' }, { #text - #tag, #text, 'RevueyCommentOutdated' } },
    }
  end
  -- GitHub review threads drawn in this view (read-only), after the local comments
  local gh = {}
  for id, it in pairs(c.forge_items or {}) do
    gh[#gh + 1] = { it = it, p = c.forge_place[id] }
  end
  table.sort(gh, function(x, y)
    local px, py = x.p.path or x.it.anchor.path, y.p.path or y.it.anchor.path
    if px ~= py then
      return px < py
    end
    local lx, ly = x.it.anchor.start_line or 0, y.it.anchor.start_line or 0
    if lx ~= ly then
      return lx < ly
    end
    return x.it.created_at < y.it.created_at
  end)
  path = nil
  for i, x in ipairs(gh) do
    local it, p = x.it, x.p
    if i == 1 then
      if #out > 0 then
        out[#out + 1] = { text = '' }
      end
      out[#out + 1] = { text = 'GitHub threads', hls = { { 0, 14, 'RevueyCommentTitle' } } }
    end
    local fp = p.path or it.anchor.path
    if fp ~= path then
      path = fp
      out[#out + 1] = { text = path, hls = { { 0, #path, 'RevueyFilePath' } } }
    end
    local where = it.file_level and 'file' or ((p.start_line and p.how ~= 'outside') and p.start_line or it.anchor.start_line)
    if not it.file_level and p.how ~= 'outside' and p.end_line and p.end_line ~= p.start_line then
      where = where .. '-' .. p.end_line
    end
    where = '  ' .. tostring(where) .. ' (' .. (it.file_level and 'file' or it.anchor.side) .. ')'
    local tags = { 'GitHub #' .. it.forge.pr, 'by ' .. author_label(it.author) }
    if it.forge.resolved then
      tags[#tags + 1] = '✓ resolved'
    end
    if it.forge.outdated then
      tags[#tags + 1] = 'outdated'
    end
    if it.forge.pending then
      tags[#tags + 1] = 'pending'
    end
    if p.how == 'outside' or p.how == 'missing' then
      tags[#tags + 1] = 'not on a shown line'
    end
    local n = #it.thread + it.forge.hidden
    if n > 0 then
      tags[#tags + 1] = n .. (n == 1 and ' reply' or ' replies')
    end
    local tag = '  [' .. table.concat(tags, ', ') .. ']'
    local text = where .. '  ' .. comments.first_line(it.body) .. tag
    out[#out + 1] = {
      text = text,
      id = it.id,
      hls = { { 0, #where, 'RevueyCommentMeta' }, { #text - #tag, #text, 'RevueyCommentOutdated' } },
    }
  end
  if #out == 0 then
    local k = config.options.keymaps.comment_add or 'gc'
    out[1] = { text = 'No comments yet: ' .. k .. ' on a line (or a selection) adds one.' }
  end
  -- the latest AI review's verdict and summary first
  local rec = require('revuey.ai_review_view').record(s)
  if rec then
    local head = require('revuey.ai_review_view').verdict_line(rec)
    local top = { { text = head, hls = { { 0, #head, 'RevueyCommentTitle' } } } }
    for _, l in ipairs(require('revuey.panel').wrap(rec.summary ~= '' and rec.summary or '(no summary)', 76, '  ')) do
      top[#top + 1] = { text = l, hls = { { 0, #l, 'RevueyCommentMeta' } } }
    end
    top[#top + 1] = { text = '' }
    vim.list_extend(top, out)
    out = top
  end
  return out
end

---`:RevueyComments` / `cl`: all comments of the review in a float; <CR> jumps, q closes.
function M.open_list(s)
  if not s then
    return vim.notify('revuey: no review open', vim.log.levels.WARN)
  end
  if M.list_state and api.nvim_win_is_valid(M.list_state.win) then
    api.nvim_win_close(M.list_state.win, true)
  end
  local lines = M.list_lines(s)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local texts = vim.tbl_map(function(l)
    return l.text
  end, lines)
  api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'revuey-comments'
  local lns = api.nvim_create_namespace('revuey.comments.list')
  local widest = 30
  for i, l in ipairs(lines) do
    widest = math.max(widest, api.nvim_strwidth(l.text))
    for _, h in ipairs(l.hls or {}) do
      if h[2] > h[1] then
        pcall(api.nvim_buf_set_extmark, buf, lns, i - 1, h[1], { end_col = h[2], hl_group = h[3] })
      end
    end
  end
  local width = math.min(widest + 2, vim.o.columns - 6)
  local height = math.min(#lines, math.max(3, vim.o.lines - 8))
  local n = 0
  for _, l in ipairs(lines) do
    n = n + (l.id and 1 or 0)
  end
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = 'rounded',
    style = 'minimal',
    title = (' Comments (%d) '):format(n),
    title_pos = 'left',
    footer = ' <CR> jump  q close ',
    footer_pos = 'right',
    zindex = 55,
  })
  vim.wo[win].cursorline = true
  M.list_state = { win = win, buf = buf, lines = lines }
  -- start on the first comment
  for i, l in ipairs(lines) do
    if l.id then
      api.nvim_win_set_cursor(win, { i, 0 })
      break
    end
  end
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local function jump()
    local l = lines[api.nvim_win_get_cursor(win)[1]]
    if not l or not l.id then
      return
    end
    close()
    M.jump(s, l.id)
  end
  for _, k in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', k, close, { buffer = buf, nowait = true, silent = true, desc = 'revuey: close the comments list' })
  end
  for _, k in ipairs({ '<CR>', 'o', '<2-LeftMouse>' }) do
    vim.keymap.set('n', k, jump, { buffer = buf, nowait = true, silent = true, desc = 'revuey: jump to the comment' })
  end
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  return M.list_state
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

---Parse `:RevueyCommentsExport [markdown|json] [--all] [register|file]`.
---@return {format:string, all:boolean, target?:string}? opts, string? err
function M.parse_export_args(args)
  local o = { format = 'markdown', all = false }
  for _, a in ipairs(args or {}) do
    if a == 'markdown' or a == 'md' then
      o.format = 'markdown'
    elseif a == 'json' then
      o.format = 'json'
    elseif a == '--all' then
      o.all = true
    elseif a:sub(1, 2) == '--' then
      return nil, 'unknown flag ' .. a .. ' (use --all)'
    elseif o.target then
      return nil, 'more than one target: ' .. o.target .. ', ' .. a
    else
      o.target = a
    end
  end
  return o
end

---Export the review's comments to a register (default `+`) or a file. Returns the text.
function M.export(s, args)
  if not s then
    return vim.notify('revuey: no review open', vim.log.levels.WARN)
  end
  local o, err = M.parse_export_args(args)
  if not o then
    return vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
  end
  local store = M.sync_store(s)
  local list = export.select(store, { all = o.all })
  local text = export.render(o.format, { { review = M.review_info(s), comments = list } })
  local target = o.target or (vim.fn.has('clipboard') == 1 and '+' or '"')
  local is_reg = #target == 1 or (target:sub(1, 1) == '"' and #target == 2)
  if is_reg then
    local reg = #target == 2 and target:sub(2) or target
    vim.fn.setreg(reg, text, 'l')
    vim.notify(('revuey: %d comment%s copied to register %s (%s)'):format(#list, #list == 1 and '' or 's', reg, o.format), vim.log.levels.INFO)
  else
    local path = vim.fn.fnamemodify(vim.fn.expand(target), ':p')
    local fd, ferr = io.open(path, 'w')
    if not fd then
      return vim.notify('revuey: cannot write ' .. path .. ': ' .. tostring(ferr), vim.log.levels.ERROR)
    end
    fd:write(text)
    fd:close()
    vim.notify(('revuey: %d comment%s written to %s (%s)'):format(#list, #list == 1 and '' or 's', path, o.format), vim.log.levels.INFO)
  end
  return text
end

return M
