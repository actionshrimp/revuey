-- The comments view: every comment thread of the review in one list, over the whole diff
-- window (a float relative to it, below its winbar, as the stack tree), so the diff or guide
-- underneath keeps its cursor, folds and scroll. GitHub review threads, your comments and
-- replies, agent comments and AI review findings, grouped by file in diff order (in full-stack
-- scope by layer first), each with its location, a status, a line of code, and the thread as the
-- diff draws it. `<CR>` shows the comment in the diff (the guide, when it came from there and
-- shows it); the comment keys act on the thread under the cursor through comments_view's actions.
--
-- Nothing is gathered here: the list is what comments_view.render placed for the view below
-- (`s.cm`: the store, placements, GitHub thread items as `gH` shows them), so it matches the
-- diff and `]c`; every comments render (an action, `R`, a reload, threads arriving) redraws it.
--
-- `M.thread_lines` builds one thread's lines for a width, full or compact (one line), so a
-- narrower host (a sidebar) can reuse it with a buffer and window of its own.
local api = vim.api
local comments = require('revuey.comments')
local config = require('revuey.config')

local M = {}

M.ns = api.nvim_create_namespace('revuey.comments.list')

local function cv()
  return require('revuey.comments_view')
end

local UNCOMMITTED = require('revuey.attribution').UNCOMMITTED

-- Above the stack tree (40, its footer 41), so the view opened from inside the tree shows; below
-- the comment editor and other floats (50 and up).
M.ZINDEX = require('revuey.list_float').ZINDEX

local function key(name)
  return require('revuey.keys').first(name)
end

-- ---------------------------------------------------------------------------
-- Entries: what comments_view placed, grouped and ordered
-- ---------------------------------------------------------------------------

---@class revuey.ListEntry
---@field c table comment or GitHub thread item
---@field p table placement (comments.place / forge_threads.place)
---@field path string
---@field fi number file index in the review (math.huge: not in it)
---@field layer? integer stack layer (full-stack scope)

---Status of a thread: a word and its highlight. GitHub: open, resolved, outdated, pending (in
---your unsubmitted review there). Local: resolved, dismissed, draft (unsaved, or an AI finding
---or agent comment not accepted yet), posted, pending (on GitHub), in review (`ci`), outdated
---(not placed in this review), open. Pending: in your unsubmitted review on GitHub.
---@return string word, string hl
function M.status(e)
  local c, p = e.c, e.p or {}
  local g = c.forge
  if g then
    if g.pending then
      return 'pending on GitHub', 'RevueyCommentInReview'
    elseif g.resolved then
      return 'resolved', 'RevueyCommentResolved'
    elseif g.outdated then
      return 'outdated', 'RevueyCommentOutdated'
    end
    return 'open', 'RevueyForgeSign'
  end
  local ar = require('revuey.ai_review')
  if c.status == 'resolved' then
    return 'resolved', 'RevueyCommentResolved'
  elseif c.status == 'dismissed' then
    return 'dismissed', 'RevueyCommentResolved'
  elseif c.status == 'draft' or ar.untriaged(c) or ar.agent_untriaged(c) then
    return 'draft', 'RevueyCommentDraft'
  end
  local st = require('revuey.forge_post').state(c)
  if st == 'posted' then
    return 'posted', 'RevueyForgeNumber'
  elseif st == 'pending' then
    return 'pending on GitHub', 'RevueyCommentInReview'
  elseif c.in_review then
    return 'in review', 'RevueyCommentInReview'
  elseif p.outdated then
    return 'outdated', 'RevueyCommentOutdated'
  end
  return 'open', 'RevueyCommentSign'
end

local CLOSED = { resolved = true, dismissed = true }

---Is the thread collapsed to one line (resolved, dismissed, outdated on GitHub, posted; until
---`cz` expands it), as the diff collapses them to their first line?
local function collapsed(s, e)
  if s.cm and s.cm.expanded and s.cm.expanded[e.c.id] then
    return false
  end
  local c = e.c
  if c.forge then
    return c.forge.resolved or c.forge.outdated
  end
  local posted = type(c.forge_post) == 'table' and c.forge_post.state == 'posted'
  return c.status == 'resolved' or c.status == 'dismissed' or posted
end

---Line order inside a file: file-level first, then the (placed) first line, deleted lines just
---before the new-side line at the same number, then creation.
local function line_key(e)
  if e.c.file_level then
    return -1
  end
  local p, a = e.p or {}, e.c.anchor or {}
  local placed = not p.outdated and p.how ~= 'outside' and p.how ~= 'missing' and p.start_line
  local n = placed or a.sort_line or a.start_line or 0
  if (p.side or a.side) == 'old' and not a.sort_line then
    n = n - 0.5
  end
  return n
end

---Which layer of a full-stack review an entry belongs to: a GitHub thread its PR's layer; a
---local comment the layer that introduced its hunk (the branch labels), a file-level one the
---file's only layer. nil when unknown.
local function layer_of(s, e)
  local st = s.review.stack
  if not st then
    return nil
  end
  local g = e.c.forge
  if g then
    local fv = require('revuey.forge_view')
    for i, l in ipairs(st.layers) do
      local pr = fv.pr(s, l.name)
      if pr and pr.number == g.pr and (not g.pr_url or pr.url == g.pr_url) then
        return i
      end
    end
    return nil
  end
  local labels = s.review.layer_labels
  if not labels or e.fi == math.huge then
    return nil
  end
  local per = labels[e.fi] or {}
  local u = e.p and e.p.unit
  local names = u and u.hunk_idx and per[u.hunk_idx]
  if not names then
    local set, n = {}, 0
    for _, list in pairs(per) do
      for _, name in ipairs(list) do
        if not set[name] and name ~= UNCOMMITTED then
          set[name], n = true, n + 1
        end
      end
    end
    names = n == 1 and vim.tbl_keys(set) or nil
  end
  -- the topmost layer that touched it; uncommitted changes (the working tree, on top of the
  -- stack) count for the top layer when no layer touched it
  for j = #(names or {}), 1, -1 do
    for i, l in ipairs(st.layers) do
      if l.name == names[j] then
        return i
      end
    end
  end
  if names and vim.tbl_contains(names, UNCOMMITTED) then
    return #st.layers
  end
end

---Every thread comments_view placed for the view below (local comments, minus those whose GitHub
---thread is shown, and the GitHub threads `gH` shows), ordered: layer (full stack), file in diff
---order (files not in the review last), file-level first, line, creation.
---@return revuey.ListEntry[]
function M.entries(s)
  local c = s.cm or {}
  local store = cv().sync_store(s)
  local U = require('revuey.review').units(s.review)
  local full = s.review.stack and s.review.scope and s.review.scope.kind == 'full'
  local out = {}
  local function add(cmt, p)
    p = p or {}
    local path = p.path or cmt.anchor.path
    local e = { c = cmt, p = p, path = path, fi = U.by_path[path] or math.huge }
    if full then
      e.layer = layer_of(s, e)
    end
    out[#out + 1] = e
  end
  for _, cmt in ipairs(comments.list(store, { include_resolved = true, include_drafts = true })) do
    if not (c.superseded and c.superseded[cmt.id]) then
      add(cmt, c.place and c.place[cmt.id] or { outdated = cmt.outdated })
    end
  end
  for id, it in pairs(c.forge_items or {}) do
    add(it, c.forge_place and c.forge_place[id])
  end
  table.sort(out, function(x, y)
    local lx, ly = x.layer or math.huge, y.layer or math.huge
    if lx ~= ly then
      return lx < ly
    end
    if x.fi ~= y.fi then
      return x.fi < y.fi
    end
    if x.path ~= y.path then
      return x.path < y.path
    end
    local kx, ky = line_key(x), line_key(y)
    if kx ~= ky then
      return kx < ky
    end
    local cx, cy = x.c.created_at or 0, y.c.created_at or 0
    if cx ~= cy then
      return cx < cy
    end
    return x.c.id < y.c.id
  end)
  return out
end

---Counts for the header and the panel: open and resolved threads, and your comments that could
---go to GitHub but are not in the review (`ci`).
function M.counts(entries)
  local n = { open = 0, resolved = 0, not_in_review = 0 }
  local post = require('revuey.forge_post')
  for _, e in ipairs(entries) do
    local st = M.status(e)
    if CLOSED[st] then
      n.resolved = n.resolved + 1
    else
      n.open = n.open + 1
    end
    if not e.c.forge and not e.c.in_review and post.includable(e.c) then
      n.not_in_review = n.not_in_review + 1
    end
  end
  return n
end

local function counts_text(n)
  local parts = { n.open .. ' open', n.resolved .. ' resolved' }
  if n.not_in_review > 0 then
    parts[#parts + 1] = n.not_in_review .. ' of yours not in the review'
  end
  return table.concat(parts, ' · ')
end

-- ---------------------------------------------------------------------------
-- One thread's lines
-- ---------------------------------------------------------------------------

---Where a thread is: `file`, `18`, `12-13`, with `(old)` for the old side: its placed lines when
---it is on shown lines, else the lines it was made on.
local function where(e)
  local c, p = e.c, e.p or {}
  if c.file_level then
    return 'file'
  end
  local a = c.anchor or {}
  local first, last = a.start_line, a.end_line
  if not p.outdated and p.how ~= 'outside' and p.how ~= 'missing' and p.start_line then
    first, last = p.start_line, p.end_line
  end
  local t = tostring(first or '?')
  if last and last ~= first then
    t = t .. '-' .. last
  end
  if (p.side or a.side) == 'old' then
    t = t .. ' (old)'
  end
  return t
end

---Why a thread is not on its line here, or nil.
local function off_diff(e)
  local p = e.p or {}
  if p.how == 'missing' then
    return 'file not in this review'
  elseif p.how == 'outside' then
    return 'not on a shown line'
  elseif p.outdated then
    return 'outdated here'
  end
end

---The code line a thread is on (shown rows only, never a git call), or nil.
local function code_line(s, e)
  local c, p = e.c, e.p or {}
  if c.file_level then
    return nil
  end
  local placed = not p.outdated and p.how ~= 'outside' and p.how ~= 'missing' and p.start_line
  if placed then
    local ok, ctx = pcall(cv().context, s)
    local r = ok and ctx.rows(e.path, p.side or c.anchor.side).by_lnum[p.start_line]
    if r and r.text then
      return r.text
    end
  end
  local snip = c.anchor and c.anchor.snippet
  if type(snip) == 'table' and snip[1] then
    return (snip[1]:gsub('^[-+ ]', ''))
  end
end

local function width_of(text)
  return api.nvim_strwidth(text)
end

---Cut `text` to `w` cells (an ellipsis when cut).
local function cut(text, w)
  if w <= 0 then
    return ''
  end
  if width_of(text) <= w then
    return text
  end
  local out = vim.fn.strcharpart(text, 0, math.max(w - 1, 0))
  while width_of(out) > w - 1 and #out > 0 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. '…'
end

---Lines of one thread, as chunk lists ({text, hl}), for a host `width` cells wide.
---`o.compact`: one line (location, status, author, first line, replies). Otherwise the location
---line (where, status, why it is not on its line, the code there) and the thread box the diff
---draws (comments_view.thread_lines: author, chips, body wrapped to the width, replies).
---`o.cut`: where a thread cut short is recorded (the host's own set; `cz` expands it).
---`o.no_tags`: the tags are left out of the location line (a host that shows them itself).
---@param o {width:integer, compact?:boolean, indent?:string, cut?:table<string, true>, no_tags?:boolean}
---@return table[] lines
function M.thread_lines(s, e, o)
  local indent = o.indent or '  '
  local width = math.max(20, o.width - width_of(indent))
  local st, st_hl = M.status(e)
  local head = { { indent, 'Normal' }, { where(e), 'RevueyCommentMeta' }, { '  ' }, { st, st_hl } }
  local used = width_of(where(e)) + 2 + width_of(st)
  local why = off_diff(e)
  if why and not (st == 'outdated' and why == 'outdated here') then
    head[#head + 1] = { ' · ' .. why, 'RevueyCommentOutdated' }
    used = used + 3 + width_of(why)
  end
  local c = e.c
  -- its tags (AI findings and agent comments: the skill or run, and the ones set)
  local tg = not c.forge and require('revuey.tags').text(require('revuey.tags').of(c)) or ''
  if tg ~= '' and not o.no_tags then
    tg = cut(tg, math.max(width - used - 2, 8))
    head[#head + 1] = { '  ' .. tg, 'RevueyCommentTag' }
    used = used + 2 + width_of(tg)
  end
  if o.compact then
    local who = cv().author_label(c.author)
    local first = comments.first_line(c.body):gsub('^%*%*(.-)%*%*$', '%1')
    local n = 0
    for _, r in ipairs(c.thread or {}) do
      n = n + (r.deleted and 0 or 1)
    end
    n = n + (c.forge and c.forge.hidden or 0)
    local tail = n > 0 and (' · ' .. n .. (n == 1 and ' reply' or ' replies')) or ''
    head[#head + 1] = { '  ' }
    head[#head + 1] = { who, cv().author_hl(c.author) }
    used = used + 2 + width_of(who)
    local room = width - used - 2 - width_of(tail)
    head[#head + 1] = { ': ' .. cut(first, math.max(room, 1)), 'RevueyCommentText' }
    if tail ~= '' then
      head[#head + 1] = { tail, 'RevueyCommentMeta' }
    end
    return { head }
  end
  local code = code_line(s, e)
  if code then
    code = vim.trim(code)
    local room = width - used - 4
    if room >= 8 and code ~= '' then
      head[#head + 1] = { '  │ ', 'RevueyCommentBorder' }
      head[#head + 1] = { cut(code, room), 'RevueyCommentsCode' }
    end
  end
  local lines = { head }
  for _, l in ipairs(cv().thread_lines(s, c, e.p or {}, width, o.cut or {})) do
    local ch = { { indent, 'Normal' } }
    vim.list_extend(ch, l)
    lines[#lines + 1] = ch
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- The whole list
-- ---------------------------------------------------------------------------

local function layer_title(s, i)
  local l = s.review.stack.layers[i]
  local pr = require('revuey.forge_view').pr(s, l.name)
  return l.name, pr and ('GitHub #' .. pr.number) or nil
end

---The view's lines for a host `width` cells wide: {chunks, id?, start?, last?} per line (`id`: the
---thread the line belongs to, `start`: its first line, `last`: its last), and the counts.
---`o.cut` collects the threads shown cut (collapsed or shortened: `cz` expands them); never the
---diff's own set, since the view's width and one-line form cut other threads.
---@param o {width:integer, compact?:boolean, cut?:table<string, true>}
function M.build(s, o)
  o.cut = o.cut or {}
  local entries = M.entries(s)
  local n = M.counts(entries)
  -- the agent reviews view's tag filter applies here too (`t` picks it, `F` clears it)
  local tf = require('revuey.ai_reviews_view').filter(s).tag
  if tf then
    local tags = require('revuey.tags')
    entries = vim.tbl_filter(function(e)
      return not e.c.forge and tags.has(e.c, tf)
    end, entries)
  end
  local out = {}
  local function line(chunks, id)
    out[#out + 1] = { chunks = chunks, id = id }
  end
  local scope = require('revuey.guide_view').scope_title(s.review)
  line({ { ' ' .. counts_text(n), 'RevueyCommentsHeader' } })
  if tf then
    local kt, kc = key('reviews_tag_filter'), key('reviews_clear_filter')
    line({ { ' Only #' .. tf .. ' (' .. #entries .. ')', 'RevueyCommentTag' },
      { (kt and ('  ' .. kt .. ' another tag') or '') .. (kc and ('  ' .. kc .. ' all') or ''), 'RevueyCommentMeta' } })
  end
  local fv = require('revuey.forge_view')
  if fv.has_threads(s) then
    local show = s.cm and s.cm.forge_show or 'all'
    local text = ({ all = 'all', open = 'open only', none = 'hidden' })[show] or show
    local k = key('forge_threads')
    line({ { ' GitHub threads: ' .. text .. (k and (' (' .. k .. ' cycles)') or ''), 'RevueyCommentMeta' } })
  end
  -- the latest AI review's verdict and summary
  local rec = require('revuey.ai_review_view').record(s)
  if rec then
    line({ { ' ' .. require('revuey.ai_review_view').verdict_line(rec), 'RevueyCommentTitle' } })
    for _, l in ipairs(require('revuey.panel').wrap(rec.summary ~= '' and rec.summary or '(no summary)', math.max(o.width - 4, 20), '   ')) do
      line({ { l, 'RevueyCommentMeta' } })
    end
  end
  line({ { '' } })
  if #entries == 0 and tf then
    line({ { ' No comment tagged #' .. tf .. '.', 'RevueyCommentMeta' } })
  elseif #entries == 0 then
    local k = key('comment_add') or 'gc'
    line({ { ' No comments' .. (scope and (' in ' .. scope) or '') .. ' yet: ' .. k .. ' on a line (or a selection) adds one.', 'RevueyCommentMeta' } })
  end
  local layer, path = false, nil
  for _, e in ipairs(entries) do
    if e.layer ~= layer and s.review.stack and s.review.scope and s.review.scope.kind == 'full' then
      layer, path = e.layer, nil
      if #out > 0 and out[#out].chunks[1][1] ~= '' then
        line({ { '' } })
      end
      if e.layer then
        local name, pr = layer_title(s, e.layer)
        line({ { ' ' .. name, 'RevueyCommentsLayer' }, pr and { '  ' .. pr, 'RevueyForgeNumber' } or nil })
      else
        line({ { ' Not attributed to a layer', 'RevueyCommentsLayer' } })
      end
    end
    if e.path ~= path then
      path = e.path
      if out[#out].chunks[1][1] ~= '' and not (out[#out].chunks[1][2] == 'RevueyCommentsLayer') then
        line({ { '' } })
      end
      local ch = { { ' ' .. path, 'RevueyFilePath' } }
      if e.fi == math.huge then
        ch[#ch + 1] = { '  not in this review', 'RevueyCommentOutdated' }
      end
      line(ch)
    end
    local compact = o.compact or collapsed(s, e)
    local tl = M.thread_lines(s, e, { width = o.width, compact = compact, cut = o.cut })
    if compact and not o.compact then
      o.cut[e.c.id] = true -- `cz` expands it (the key hint offers it)
    end
    local first = #out + 1
    for _, l in ipairs(tl) do
      line(l, e.c.id)
    end
    out[first].start = true
    out[#out].last = true
  end
  return out, n, entries
end

---Plain text of the view's lines (tests, a later sidebar's checks).
function M.texts(s, width)
  local out = {}
  for _, l in ipairs((M.build(s, { width = width or 100 }))) do
    local t = {}
    for _, ch in ipairs(l.chunks) do
      t[#t + 1] = ch[1]
    end
    out[#out + 1] = table.concat(t)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The view (a float over the diff window: list_float.lua)
-- ---------------------------------------------------------------------------

local F = require('revuey.list_float')

local function valid(s)
  return F.valid(s, 'clist')
end

---Is the comments view open for session `s`?
function M.active(s)
  return valid(s) ~= nil
end

local at_cursor = F.at_cursor

local SPEC
SPEC = {
  field = 'clist',
  last = 'clist_last',
  name = 'revuey://comments',
  filetype = 'revuey-comments',
  augroup = 'revuey.comments.list.',
  ns = M.ns,
  build = function(s, width, v)
    local cut = {}
    local lines, n = M.build(s, { width = width, cut = cut })
    v.cut = cut
    v.counts = n
    return lines
  end,
  keymaps = function(s, v)
    M.keymaps(s, v)
  end,
}

---Draw the list into the view's buffer (every comments render while it is open). The cursor
---stays on the thread it was on, at the same line of it (the next thread when it went).
function M.render(s)
  F.render(s, SPEC)
end

---Where an action's editor opens: under the thread's last line in the view.
local function target(s)
  local v = valid(s)
  if not v then
    return nil
  end
  local id, _, last = at_cursor(v)
  if not id then
    vim.notify('revuey: move to a comment thread', vim.log.levels.INFO)
    return nil
  end
  return { id = id, win = v.win, row = last, col = 4 }
end

---`<CR>`: the comment in the diff, or in the guide when the view was opened from it and the guide
---shows it.
function M.show(s)
  local v = valid(s)
  if not v then
    return
  end
  local id = at_cursor(v)
  if not id then
    return
  end
  M.close(s)
  M.jump(s, id)
end

---Show comment `id` in the diff (in the guide when it is the view and shows it).
function M.jump(s, id)
  if (s.view_mode or 'diff') == 'guide' then
    if cv().jump(s, id, true) then
      return
    end
    require('revuey.view').set_view('diff')
  end
  cv().jump(s, id)
end

---`]c` / `[c` in the view: the next or previous thread start (takes a count), as `]c` in the
---diff: inside a thread `[c` goes to its start first; past the last (before the first) thread
---nothing moves.
function M.next(s, dir)
  F.next(s, 'clist', dir)
end

---Close the view; the diff (or guide) below is as it was. Focus goes back to the window it was
---opened from while that is still there (the panel, the stack tree's float), else to the diff.
---Remembers the thread under the cursor for the next open. `quiet`: another list replaces it.
function M.close(s, quiet)
  F.close(s, SPEC, quiet)
end

---Review cleanup.
function M.detach(s)
  M.close(s)
end

function M.keymaps(s, v)
  local k = config.options.keymaps
  local map = F.mapper(v)
  local function act(fn)
    return function()
      local at = target(s)
      if at then
        fn(s, at)
      end
    end
  end
  map({ '<CR>', '<2-LeftMouse>' }, function()
    M.show(s)
  end, 'comments view: show the comment in the diff')
  map({ 'q', '<Esc>' }, function()
    M.close(s)
  end, 'comments view: back to the diff')
  map(k.comment_list, function()
    M.close(s)
  end, 'comments view: back to the diff')
  map(k.ai_reviews, function()
    require('revuey.ai_reviews_view').open(s)
  end, 'the agent reviews view: findings by run')
  map(k.comment_next, function()
    M.next(s, 1)
  end, 'comments view: next thread')
  map(k.comment_prev, function()
    M.next(s, -1)
  end, 'comments view: previous thread')
  local C = cv()
  map(k.comment_reply, act(C.reply), 'reply to the thread (on a GitHub thread: a local reply)')
  map(k.comment_edit, act(C.edit), 'edit the comment')
  map(k.comment_delete, act(C.delete), 'delete the comment')
  map(k.comment_resolve, act(C.resolve), 'resolve / reopen the comment')
  map(k.comment_include, act(C.toggle_include), 'add the comment to the GitHub review / take it out')
  map(k.comment_accept, act(C.accept), 'accept the AI finding or agent comment')
  map(k.comment_dismiss, act(C.dismiss), 'dismiss / restore the AI finding or agent comment')
  map(k.send_comment, act(C.send_existing), 'send the comment to the agent')
  map(k.comment_expand, act(C.toggle_expand), 'expand / collapse the thread')
  map(k.comment_tag, act(C.tag), 'tag the comment')
  map(k.forge_open, act(function(_, at)
    local it = C.by_id(s, at.id)
    if it and it.forge then
      require('revuey.forge_view').open_item(it)
    else
      vim.notify('revuey: not a GitHub thread', vim.log.levels.INFO)
    end
  end), 'open the GitHub thread in the browser')
  map(k.forge_threads, function()
    C.toggle_forge(s)
  end, 'GitHub threads: all / open only / hidden')
  local arv = require('revuey.ai_reviews_view')
  map(k.reviews_tag_filter, function()
    arv.pick_filter(s, 'tag', M.render)
  end, 'only the comments with a tag')
  map(k.reviews_clear_filter, function()
    arv.clear_filter(s)
  end, 'every comment again (no tag filter)')
  F.common_keys(s, map)
end

---The comment action target under the view's cursor (`:RevueyTag` from the view), or nil.
function M.target(s)
  local v = valid(s)
  if v and vim.api.nvim_get_current_win() == v.win then
    return target(s)
  end
end

---Open the comments view over the diff window (`cl`, `:RevueyComments`); focus it when open.
function M.open(s)
  return F.open(s, SPEC)
end

---`cl`: open the comments view, or back to the diff (guide) from it.
function M.toggle(s)
  if M.active(s) then
    return M.close(s)
  end
  return M.open(s)
end

-- ---------------------------------------------------------------------------
-- Winbar and panel
-- ---------------------------------------------------------------------------

---The diff window's winbar while the view is open: `Comments · <scope>` and the counts, or the
---keys that work on the thread under the cursor while the view has focus.
function M.winbar(s, win)
  local v = valid(s)
  local esc = function(str)
    return (str:gsub('%%', '%%%%'))
  end
  local scope = require('revuey.guide_view').scope_title(s.review)
  local left = ' %#RevueyGuideSectionNumber#Comments' .. (scope and esc(' · ' .. scope) or '') .. ' '
  local n = v and v.counts or { open = 0, resolved = 0, not_in_review = 0 }
  local right = '%#Comment#' .. esc(counts_text(n)) .. ' '
  if v and api.nvim_get_current_win() == v.win then
    local id = at_cursor(v)
    local items = id and require('revuey.key_help').comment_items(s, { id }, v.cut) or {}
    if #items > 0 then
      local k = require('revuey.key_help')
      return k.compose(left, '', vim.list_extend({ { key = '<CR>', label = 'show' } }, items), api.nvim_win_get_width(win))
    end
  end
  return left .. '%*%=' .. right
end

---The panel's comments section while the view is open (as the guide's): the counts.
function M.panel(s, add, add_virt)
  local v = valid(s)
  if not v then
    return
  end
  local title = ' Comments'
  local row = add(title, { { 0, #title, 'RevueyPanelTitle' } })
  local n = v.counts or M.counts(M.entries(s))
  add_virt(row, { { ('%d open · %d resolved'):format(n.open, n.resolved), 'Comment' } })
  if n.not_in_review > 0 then
    local t = (' %d of yours not in the review'):format(n.not_in_review)
    add(t, { { 0, #t, 'Comment' } })
  end
  add('')
end

---The panel's key lines while the view is open (keys.line templates).
M.HELP = {
  ' <CR> show  {comment_next} {comment_prev} thread  q back',
  ' {comment_reply} reply  {comment_edit} edit  {comment_resolve} resolve',
  ' {comment_include} review  {comment_accept} accept  {comment_dismiss} dismiss',
  ' {comment_expand} expand  {send_comment} agent  {comment_delete} delete',
  ' {comment_tag} tag  {reviews_tag_filter} tag filter  {ai_reviews} by run',
}

return M
