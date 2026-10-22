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
local git = require('revuey.git')
local prose = require('revuey.prose')
local editor = require('revuey.comment_editor')

local M = {}

M.ns = api.nvim_create_namespace('revuey.comments')

---Pluggable actions. `send` is the editor's send key: the later "send to an AI / the launching
---agent session" plugs in here. It gets {session, comment?, anchor, text, kind} and returns
---true when it took the text (the editor then closes).
M.actions = {
  send = function(_)
    vim.notify('revuey: sending a comment to an AI or agent session is not available yet', vim.log.levels.INFO)
    return false
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

-- ---------------------------------------------------------------------------
-- Review info, store, watcher
-- ---------------------------------------------------------------------------

---What the comments file and events record about the review (export headers, CLI filters).
function M.review_info(s)
  local r = s.review
  local info = {
    repo = r.state.repo,
    branch = r.branch,
    base = r.base,
    state_branch = r.state.branch,
    state_base = r.state.base,
    head = r.head,
    merge_base = r.merge_base,
    mode = r.mode,
    scope = 'branch',
  }
  if r.stack and r.scope then
    if r.scope.kind == 'full' then
      info.scope = 'full'
      info.layers = vim.tbl_map(function(l)
        return l.name
      end, r.stack.layers)
    else
      info.scope = 'layer'
    end
  end
  return info
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
  local ok, changed = pcall(comments.reload, c.store)
  if ok and changed then
    M.refresh(s)
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
  if not f or f.binary then
    return nil
  end
  local c = cm(s)
  c.blobs = c.blobs or {}
  if side == 'new' then
    if f.new_text then
      return f.new_text
    end
    if not f.new_blob or f.status == 'D' then
      return nil
    end
    return require('revuey.view').head_text(s, f)
  end
  local blob = f.old_blob
  if not blob or f.status == 'A' then
    return nil
  end
  if c.blobs[blob] == nil then
    c.blobs[blob] = git.blob(blob, s.review.root) or false
  end
  return c.blobs[blob] or nil
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
  return a.name or ({ ai = 'AI', agent = 'Agent' })[a.kind] or a.kind
end

---Virtual lines of one thread.
---@param p revuey.CommentPlacement
local function thread_lines(s, c, p, width)
  local expanded = cm(s).expanded[c.id]
  local max = opt('max_lines', 6)
  local B = 'RevueyCommentBorder'
  local lines = {}
  local head = { { '╭─ ', B }, { author_label(c.author), 'RevueyCommentAuthor' }, { ' · ' .. ago(c.updated_at or c.created_at), 'RevueyCommentMeta' } }
  local used = 3 + api.nvim_strwidth(author_label(c.author)) + api.nvim_strwidth(head[3][1])
  local function chip(text, hl)
    head[#head + 1] = { ' · ', 'RevueyCommentMeta' }
    head[#head + 1] = { text, hl }
    used = used + 3 + api.nvim_strwidth(text)
  end
  if c.file_level then
    chip('file', 'RevueyCommentMeta')
  end
  if c.status == 'draft' then
    chip('draft', 'RevueyCommentDraft')
  elseif c.status == 'resolved' then
    chip('resolved', 'RevueyCommentResolved')
  end
  if c.draft or c.reply_draft then
    chip('unsaved edit', 'RevueyCommentDraft')
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
  local resolved = c.status == 'resolved' and not expanded
  add_text(c.body, '│ ', '│ ')
  for _, r in ipairs(c.thread or {}) do
    if not r.deleted then
      body[#body + 1] = {
        { '│ ↳ ', B },
        { author_label(r.author), 'RevueyCommentAuthor' },
        { ' · ' .. ago(r.created_at), 'RevueyCommentMeta' },
      }
      add_text(r.body, '│   ', '│   ')
    end
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
  return lines
end

local SIGN_HL = { draft = 'RevueyCommentDraft', resolved = 'RevueyCommentResolved' }

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
    if o.persist and comments.apply_placement(cmt, p) then
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
  local width = thread_width(s)
  if not c.hidden then
    for row, items in pairs(attach) do
      local vl = {}
      local headed = {}
      -- in-file items first, then outdated, then the end-of-review groups
      local rank = { outdated = 1, missing = 2, hidden = 3 }
      table.sort(items, function(x, y)
        local rx, ry = rank[x.group] or 0, rank[y.group] or 0
        if rx ~= ry then
          return rx < ry
        end
        return x.c.id < y.c.id
      end)
      local titles = {
        outdated = 'Outdated comments',
        missing = 'Comments on files no longer in this review',
        hidden = 'Comments on files not shown in this view',
      }
      for _, it in ipairs(items) do
        if it.group and not headed[it.group] then
          headed[it.group] = true
          vl[#vl + 1] = { { '' } }
          vl[#vl + 1] = { { titles[it.group], 'RevueyCommentOutdated' } }
        end
        if it.group == 'missing' or it.group == 'hidden' then
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
local function save_and_emit(s, kind, cmt, extra, store)
  local c = cm(s)
  store = store or c.store
  local current = store == c.store
  local info = current and M.review_info(s) or nil
  local ok, err = pcall(comments.save, store, info)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  if kind then
    local events = (store.path:gsub('%.comments%.json$', '.events.jsonl'))
    comments.append_event(events, comments.event(kind, cmt, info or store.review, extra))
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

local function send_hook(s, kind, anchor, cmt)
  return function(text)
    return M.actions.send({ session = s, kind = kind, anchor = anchor, comment = cmt, text = text })
  end
end

---`gc`: comment on rows first..last of the diff or guide (a file header or hunk header: the
---whole file).
function M.add(s, first, last)
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
  editor.open({
    session = s,
    title = title(anchor, file_level),
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
    on_send = send_hook(s, 'comment', anchor, nil),
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
    local cmt = comments.get(c.store, id)
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
      return comments.location(x) .. '  ' .. comments.first_line(x.body)
    end,
  }, function(choice)
    if choice then
      fn(choice)
    end
  end)
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
      on_send = send_hook(s, 'comment', cmt.anchor, cmt),
    })
  end)
end

---`cr`: reply to a comment's thread.
function M.reply(s)
  M.with_comment(s, function(cmt)
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
      on_send = send_hook(s, 'reply', cmt.anchor, cmt),
    })
  end)
end

---`cx`: resolve, or reopen a resolved comment.
function M.resolve(s)
  M.with_comment(s, function(cmt)
    if cmt.status == 'draft' then
      return vim.notify('revuey: save the draft first', vim.log.levels.INFO)
    end
    local cur = still_there(cm(s).store, cmt.id)
    if not cur then
      return M.refresh(s)
    end
    local copy = vim.deepcopy(cur)
    copy.status = cur.status == 'resolved' and 'saved' or 'resolved'
    comments.put(cm(s).store, copy)
    save_and_emit(s, 'resolved', copy)
  end)
end

---Ask before deleting; tests replace this.
function M.confirm_delete(msg)
  return vim.fn.confirm(msg, '&Delete\n&Cancel', 2) == 1
end

---`cd`: delete a comment (asks first).
function M.delete(s)
  M.with_comment(s, function(cmt)
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
    if cmt.status == 'resolved' then
      tags[#tags + 1] = '✓ resolved'
    elseif cmt.status == 'draft' then
      tags[#tags + 1] = 'draft'
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
    local tag = #tags > 0 and ('  [' .. table.concat(tags, ', ') .. ']') or ''
    local text = where .. '  ' .. comments.first_line(cmt.body) .. tag
    out[#out + 1] = {
      text = text,
      id = cmt.id,
      hls = { { 0, #where, 'RevueyCommentMeta' }, { #text - #tag, #text, 'RevueyCommentOutdated' } },
    }
  end
  if #out == 0 then
    local k = config.options.keymaps.comment_add or 'gc'
    out[1] = { text = 'No comments yet: ' .. k .. ' on a line (or a selection) adds one.' }
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
