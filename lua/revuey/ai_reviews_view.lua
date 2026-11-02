-- The agent reviews view: the AI review findings and the coding agent's comments of the review
-- scope, grouped by the run that made them (a fresh session, the connected agent, an import; the
-- agent's own comments as a group per agent), newest run first, over the whole diff window (the
-- comments view's float, list_float.lua). Each run's heading says who ran it, with which skill,
-- when, its verdict, the first line of its summary and its counts; under it each finding on one
-- line (severity, title, location, status, tags), `cz` showing it in full (the comments view's
-- thread lines). Filters by tag, run, status and severity. The comment keys act on the finding
-- under the cursor (comments_view's actions by id); on a run, `cA`/`cN` accept or dismiss its
-- untriaged findings, `cD` deletes it, `ct` tags all of its findings.
--
-- Nothing is gathered here: the findings are the comments view's entries (what comments_view
-- placed), the runs the scope's run file (ai_review_view.runs); every comments render redraws it.
local api = vim.api
local comments = require('revuey.comments')
local config = require('revuey.config')
local ai_review = require('revuey.ai_review')
local tags = require('revuey.tags')
local F = require('revuey.list_float')

local M = {}

M.ns = api.nvim_create_namespace('revuey.ai_reviews')

local function cv()
  return require('revuey.comments_view')
end

local function cl()
  return require('revuey.comments_list')
end

local function key(name)
  return require('revuey.keys').first(name)
end


-- ---------------------------------------------------------------------------
-- Filters (per session; the tag filter applies to the comments view too)
-- ---------------------------------------------------------------------------

---The session's filter: {tag?, run?, status?, severity?}.
function M.filter(s)
  s.ar_filter = s.ar_filter or {}
  return s.ar_filter
end

local function any_filter(f)
  return f.tag ~= nil or f.run ~= nil or f.status ~= nil or f.severity ~= nil
end

local function rerender(s)
  if s.arlist then
    M.render(s)
  end
  if s.clist then
    cl().render(s)
  end
  require('revuey.panel').render(s)
end

---Clear every filter.
function M.clear_filter(s)
  s.ar_filter = {}
  rerender(s)
end

---Set filter `kind` to `value` (nil clears it).
function M.set_filter(s, kind, value)
  M.filter(s)[kind] = value
  rerender(s)
end

---Ask for the value of filter `kind` (tag, run, status, severity) with vim.ui.select over what
---is in use, plus "Any".
function M.pick_filter(s, kind)
  local groups, entries = M.data(s)
  local items, labels = {}, {}
  local function add(v, label)
    items[#items + 1] = v
    labels[v] = label
  end
  local ANY = '\0any'
  add(ANY, 'Any')
  if kind == 'tag' then
    local list = {}
    for _, e in ipairs(entries) do
      list[#list + 1] = e.c
    end
    -- the comments view shows other comments too: their tags count there
    if s.clist and not s.arlist then
      for _, e in ipairs(cl().entries(s)) do
        if not e.c.forge and not vim.tbl_contains(list, e.c) then
          list[#list + 1] = e.c
        end
      end
    end
    for _, x in ipairs(tags.in_use(list)) do
      add(x.tag, '#' .. x.tag .. ' (' .. x.n .. ')')
    end
  elseif kind == 'run' then
    for _, g in ipairs(groups) do
      add(g.id, M.run_title(g))
    end
  elseif kind == 'status' then
    for _, st in ipairs(ai_review.STATUSES) do
      add(st, st)
    end
  elseif kind == 'severity' then
    for _, sv in ipairs(require('revuey.ai_review_prompt').SEVERITIES) do
      add(sv, sv)
    end
  end
  if kind == 'tag' and #items == 1 then
    return vim.notify('revuey: no tags in use (' .. (key('comment_tag') or 'ct') .. ' tags a comment)', vim.log.levels.INFO)
  end
  vim.ui.select(items, {
    prompt = 'Only the findings with ' .. kind,
    format_item = function(v)
      return labels[v]
    end,
  }, function(choice)
    if choice == nil or s.cleaned then
      return
    end
    M.set_filter(s, kind, choice ~= ANY and choice or nil)
  end)
end

---`f`: which filter to set, then its value.
function M.pick_any_filter(s)
  local f = M.filter(s)
  local kinds = { 'tag', 'run', 'status', 'severity' }
  local items = vim.list_extend({}, kinds)
  if any_filter(f) then
    items[#items + 1] = 'clear'
  end
  vim.ui.select(items, {
    prompt = 'Filter the findings by',
    format_item = function(k)
      if k == 'clear' then
        return 'Clear every filter'
      end
      local cur = f[k]
      if k == 'run' and cur then
        cur = 'one run'
      end
      return k:sub(1, 1):upper() .. k:sub(2) .. (cur and (' (now: ' .. cur .. ')') or '')
    end,
  }, function(choice)
    if not choice or s.cleaned then
      return
    end
    if choice == 'clear' then
      return M.clear_filter(s)
    end
    M.pick_filter(s, choice)
  end)
end

-- ---------------------------------------------------------------------------
-- Groups and lines
-- ---------------------------------------------------------------------------

---The run groups (ai_review.groups) of the scope with the comments view's entries of their
---findings (diff order), and those entries.
---@return table[] groups, revuey.ListEntry[] entries
function M.data(s)
  local all = cl().entries(s)
  local entries, list, by = {}, {}, {}
  for _, e in ipairs(all) do
    if not e.c.forge and ai_review.origin(e.c) then
      entries[#entries + 1] = e
      list[#list + 1] = e.c
      by[e.c.id] = e
    end
  end
  local groups = ai_review.groups(require('revuey.ai_review_view').runs(s), list)
  for _, g in ipairs(groups) do
    g.entries = {}
    for _, c in ipairs(g.findings) do
      g.entries[#g.entries + 1] = by[c.id]
    end
  end
  return groups, entries
end

---Does entry `e` of group `g` pass the filter?
local function shown(f, g, e)
  local c = e.c
  if f.run and f.run ~= g.id then
    return false
  end
  if f.tag and not tags.has(c, f.tag) then
    return false
  end
  if f.status and ai_review.triage_status(c) ~= f.status then
    return false
  end
  if f.severity and not (c.ai and c.ai.severity == f.severity) then
    return false
  end
  return true
end

---A run's title: who ran it, and the skill.
function M.run_title(g)
  local run = g.run or {}
  if g.comments then
    return 'Comments from ' .. (require('revuey.requests').clean_name(run.name) or 'agent') .. ' (agent)'
  end
  local t = ai_review.run_who(run)
  if run.skill and run.skill ~= '' then
    t = t .. ' · skill ' .. require('revuey.guide').one_line(run.skill)
  end
  return t
end

local function width_of(text)
  return api.nvim_strwidth(text)
end

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

local function counts_text(n)
  local parts = { n.untriaged .. ' untriaged', n.accepted .. ' accepted', n.dismissed .. ' dismissed' }
  if (n.resolved or 0) > 0 then
    parts[#parts + 1] = n.resolved .. ' resolved'
  end
  return table.concat(parts, ' · ')
end

local VERDICT_HL = { approve = 'RevueyAiApprove', comment = 'RevueyAiComment', request_changes = 'RevueyAiChanges' }
local STATUS_HL = { untriaged = 'RevueyCommentDraft', accepted = 'RevueyCommentMeta', dismissed = 'RevueyCommentResolved', resolved = 'RevueyCommentResolved' }

---A run's heading lines: title, when and verdict; its summary's first line; its counts.
local function run_lines(g, width)
  local out = {}
  local rec = g.record
  local title = M.run_title(g)
  local right = {}
  if rec then
    local when = rec.finished_at and rec.finished_at > 0 and cv().ago(rec.finished_at) or nil
    if when then
      right[#right + 1] = { '  ' .. when, 'RevueyCommentMeta' }
    end
    right[#right + 1] = { '  ' .. (ai_review.VERDICT_GLYPH[rec.verdict] or '●') .. ' ' .. (ai_review.VERDICT_LABEL[rec.verdict] or rec.verdict), VERDICT_HL[rec.verdict] or 'Comment' }
  elseif g.orphan then
    right[#right + 1] = { '  run record gone', 'RevueyCommentOutdated' }
  end
  local rw = 0
  for _, ch in ipairs(right) do
    rw = rw + width_of(ch[1])
  end
  local head = { { ' ▍', 'RevueyReviewsRun' }, { cut(title, math.max(width - 2 - rw, 12)), 'RevueyReviewsRun' } }
  vim.list_extend(head, right)
  out[#out + 1] = head
  if rec and rec.summary ~= '' then
    local first = comments.first_line(rec.summary)
    out[#out + 1] = { { ' ▍ ', 'RevueyReviewsRun' }, { cut(first, math.max(width - 3, 10)), 'RevueyCommentText' } }
  end
  local n = g.counts
  local ct = { { ' ▍ ', 'RevueyReviewsRun' }, { counts_text(n), n.untriaged > 0 and 'Normal' or 'RevueyCommentMeta' } }
  if rec and (rec.dropped or 0) > 0 then
    ct[#ct + 1] = { ' · ' .. rec.dropped .. ' dropped', 'RevueyCommentOutdated' }
  end
  out[#out + 1] = ct
  return out
end

---"src/cart.ts:12-13" (old side marked) of an entry, as placed.
local function where(e)
  local c, p = e.c, e.p or {}
  if c.file_level then
    return e.path .. ' (file)'
  end
  local a = c.anchor or {}
  local first, last = a.start_line, a.end_line
  if not p.outdated and p.how ~= 'outside' and p.how ~= 'missing' and p.start_line then
    first, last = p.start_line, p.end_line
  end
  local t = e.path .. ':' .. tostring(first or '?')
  if last and last ~= first then
    t = t .. '-' .. last
  end
  if (p.side or a.side) == 'old' then
    t = t .. ' (old)'
  end
  return t
end

local INDENT, SEV_W, STATUS_W = '   ', 9, 9

---The columns of the finding lines for `entries` at `width`: {title, loc, tags} widths. The
---title keeps at least 20 cells: the tags give way first, then the location.
local function columns(entries, width)
  local loc_w, tags_w, longest = 0, 0, 6
  for _, e in ipairs(entries) do
    loc_w = math.max(loc_w, width_of(where(e)))
    tags_w = math.max(tags_w, width_of(tags.text(tags.of(e.c))))
    longest = math.max(longest, width_of(e.c.ai and e.c.ai.title or comments.first_line(e.c.body)))
  end
  loc_w, tags_w = math.min(loc_w, 32), math.min(tags_w, 32)
  local fixed = width_of(INDENT) + SEV_W + 2 + 2 + STATUS_W
  local function title_w()
    return width - fixed - (loc_w > 0 and (loc_w + 2) or 0) - (tags_w > 0 and (tags_w + 2) or 0) + 2
  end
  if title_w() < 20 and tags_w > 0 then
    tags_w = math.max(tags_w - (20 - title_w()), 0)
    tags_w = tags_w >= 6 and tags_w or 0
  end
  if title_w() < 20 and loc_w > 0 then
    loc_w = math.max(loc_w - (20 - title_w()), 0)
    loc_w = loc_w >= 8 and loc_w or 0
  end
  -- no wider than the longest title, so the columns stay near it on a wide screen
  return { title = math.max(math.min(title_w(), longest), 6), loc = loc_w, tags = tags_w }
end

local function pad(text, w)
  text = cut(text, w)
  return text .. string.rep(' ', math.max(w - width_of(text), 0))
end

---One finding's line: severity, title, location, status, tags, in `cols` (columns()).
local function finding_line(e, cols)
  local c = e.c
  local sev = c.ai and (c.ai.severity or 'minor') or 'comment'
  local sev_hl = c.ai and (cv().SEVERITY_HL[sev] or 'RevueyAiMinor') or 'RevueyCommentAgent'
  local title = (c.ai and c.ai.title or comments.first_line(c.body)):gsub('^%*%*(.-)%*%*$', '%1')
  local st = ai_review.triage_status(c)
  local ch = {
    { INDENT, 'Normal' },
    { pad(sev, SEV_W), sev_hl },
    { pad(title, cols.title), st == 'untriaged' and 'RevueyCommentText' or 'RevueyCommentMeta' },
    { '  ' },
  }
  if cols.loc > 0 then
    ch[#ch + 1] = { pad(where(e), cols.loc), 'RevueyFilePath' }
    ch[#ch + 1] = { '  ' }
  end
  local tg = cols.tags > 0 and tags.text(tags.of(c)) or ''
  ch[#ch + 1] = { tg ~= '' and pad(st, STATUS_W) or st, STATUS_HL[st] or 'RevueyCommentMeta' }
  if tg ~= '' then
    ch[#ch + 1] = { '  ' .. cut(tg, cols.tags), 'RevueyCommentTag' }
  end
  return ch
end

---The view's lines for a host `width` cells wide ({chunks, id?, start?, kind?}), and the totals.
---`o.cut`: findings shown on one line (`cz` expands them).
---@param o {width:integer, cut?:table<string, true>}
function M.build(s, o)
  o.cut = o.cut or {}
  local width = o.width
  local groups = M.data(s)
  local f = M.filter(s)
  local total = { untriaged = 0, accepted = 0, dismissed = 0, resolved = 0 }
  local runs = 0
  for _, g in ipairs(groups) do
    for k, v in pairs(g.counts) do
      total[k] = total[k] + v
    end
    if not g.comments then
      runs = runs + 1
    end
  end
  local out = {}
  local function line(chunks, id, kind)
    out[#out + 1] = { chunks = chunks, id = id, kind = kind }
    return out[#out]
  end
  local nf = total.untriaged + total.accepted + total.dismissed + total.resolved
  line({ { (' %d run%s · %d finding%s: '):format(runs, runs == 1 and '' or 's', nf, nf == 1 and '' or 's') .. counts_text(total), 'RevueyCommentsHeader' } })
  -- the active filter, or how to set one
  local kf, kt, kc = key('reviews_filter'), key('reviews_tag_filter'), key('reviews_clear_filter')
  if any_filter(f) then
    local parts = {}
    if f.tag then
      parts[#parts + 1] = '#' .. f.tag
    end
    if f.run then
      local name = f.run
      for _, g in ipairs(groups) do
        if g.id == f.run then
          name = M.run_title(g)
        end
      end
      parts[#parts + 1] = 'run ' .. name
    end
    if f.status then
      parts[#parts + 1] = f.status
    end
    if f.severity then
      parts[#parts + 1] = f.severity
    end
    local how = (kf and ('  ' .. kf .. ' filter') or '') .. (kc and ('  ' .. kc .. ' clear') or '')
    line({ { ' Only ', 'RevueyCommentMeta' }, { cut(table.concat(parts, ' · '), math.max(width - 7 - width_of(how), 10)), 'RevueyReviewsFilter' }, { how, 'RevueyCommentMeta' } })
  else
    local hint = {}
    local ktag = key('comment_tag')
    for _, x in ipairs({ { kf, 'filter' }, { kt, 'tag filter' }, { ktag, 'tag' } }) do
      if x[1] then
        hint[#hint + 1] = x[1] .. ' ' .. x[2]
      end
    end
    local run_keys = {}
    for _, x in ipairs({ { 'run_accept', 'accept all' }, { 'run_dismiss', 'dismiss all' }, { 'run_delete', 'delete' } }) do
      local kk = key(x[1])
      if kk then
        run_keys[#run_keys + 1] = kk .. ' ' .. x[2]
      end
    end
    if #run_keys > 0 then
      hint[#hint + 1] = 'on a run: ' .. table.concat(run_keys, ', ')
    end
    line({ { ' ' .. cut(table.concat(hint, ' · '), width - 1), 'RevueyCommentMeta' } })
  end
  line({ { '' } })
  if #groups == 0 then
    local k = key('ai_reviews')
    line({ { ' No AI review of this scope yet: :RevueyAIReview runs one (the connected agent can import one too).', 'RevueyCommentMeta' } })
    return out, total, k
  end
  local expanded = s.cm and s.cm.expanded or {}
  local any = false
  -- one set of columns for every finding shown, so they line up
  local lists, every = {}, {}
  for gi, g in ipairs(groups) do
    lists[gi] = {}
    for _, e in ipairs(g.entries) do
      if shown(f, g, e) then
        table.insert(lists[gi], e)
        every[#every + 1] = e
      end
    end
  end
  local cols = columns(every, width)
  for gi, g in ipairs(groups) do
    local list = lists[gi]
    local hide = (#list == 0 and any_filter(f) and f.run ~= g.id)
    if not hide then
      any = true
      if #out > 0 and out[#out].chunks[1][1] ~= '' then
        line({ { '' } })
      end
      local id = 'run:' .. g.id
      for i, ch in ipairs(run_lines(g, width)) do
        local l = line(ch, id, 'group')
        l.start = i == 1
      end
      if #list == 0 then
        line({ { '   ' .. (#g.entries == 0 and 'No findings.' or 'No finding passes the filter.'), 'RevueyCommentMeta' } }, id, 'group')
      end
      for _, e in ipairs(list) do
        local first = line(finding_line(e, cols), e.c.id)
        first.start = true
        if expanded[e.c.id] then
          local tl = cl().thread_lines(s, e, { width = width, indent = '     ', cut = o.cut, no_tags = true })
          for i = 2, #tl do
            line(tl[i], e.c.id)
          end
        else
          o.cut[e.c.id] = true -- `cz` shows it in full
        end
      end
    end
  end
  if not any then
    line({ { ' No finding passes the filter' .. (kc and (' (' .. kc .. ' clears it)') or '') .. '.', 'RevueyCommentMeta' } })
  end
  return out, total
end

---Plain text of the view's lines (tests).
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
-- The view
-- ---------------------------------------------------------------------------

local function valid(s)
  return F.valid(s, 'arlist')
end

---Is the agent reviews view open for session `s`?
function M.active(s)
  return valid(s) ~= nil
end

local SPEC = {
  field = 'arlist',
  last = 'arlist_last',
  name = 'revuey://ai-reviews',
  filetype = 'revuey-ai-reviews',
  augroup = 'revuey.ai_reviews.',
  ns = M.ns,
  build = function(s, width, v)
    local cut = {}
    local lines, total = M.build(s, { width = width, cut = cut })
    v.cut = cut
    v.counts = total
    return lines
  end,
  keymaps = function(s, v)
    M.keymaps(s, v)
  end,
}

---Draw the view (every comments render while it is open).
function M.render(s)
  F.render(s, SPEC)
end

---The run group id under the cursor (its heading, or a finding of it), and the finding id when
---the cursor is on one.
local function at(s)
  local v = valid(s)
  if not v then
    return nil
  end
  local id, _, last = F.at_cursor(v)
  if not id then
    return nil
  end
  if id:sub(1, 4) == 'run:' then
    return id:sub(5), nil, last
  end
  -- the finding's run: the nearest heading above
  local row = api.nvim_win_get_cursor(v.win)[1]
  for r = row, 1, -1 do
    local x = v.rows[r]
    if x and x:sub(1, 4) == 'run:' then
      return x:sub(5), id, last
    end
  end
  return nil, id, last
end

---The group `gid` of the scope, or nil.
local function group(s, gid)
  for _, g in ipairs((M.data(s))) do
    if g.id == gid then
      return g
    end
  end
end

---The comment action target under the cursor (a finding), or nil (said).
local function target(s, quiet)
  local v = valid(s)
  local gid, id, last = at(s)
  if not id then
    if not quiet then
      local k = key('run_accept')
      vim.notify(gid and ('revuey: on a run: ' .. (k and (k .. ' accepts its findings, ') or '') .. 'or move to a finding') or 'revuey: move to a finding', vim.log.levels.INFO)
    end
    return nil
  end
  return { id = id, win = v.win, row = last, col = 6 }
end

---Ask before a run-wide action; tests replace this.
function M.confirm(msg, what)
  return vim.fn.confirm(msg, '&' .. what .. '\n&Cancel', 2) == 1
end

---The findings of run `gid` the filter shows (all of them with `all`).
local function run_findings(s, gid, all)
  local g = group(s, gid)
  if not g then
    return nil
  end
  local f = M.filter(s)
  local list = {}
  for _, e in ipairs(g.entries) do
    if all or shown(vim.tbl_extend('force', f, { run = nil }), g, e) then
      list[#list + 1] = e.c
    end
  end
  return g, list
end

---`cA` / `cN`: accept or dismiss every untriaged finding of the run under the cursor that the
---filter shows (asks first).
function M.triage_run(s, what)
  local gid = at(s)
  if not gid then
    return vim.notify('revuey: move to a run', vim.log.levels.INFO)
  end
  local g, list = run_findings(s, gid)
  if not g then
    return
  end
  local ids = {}
  for _, c in ipairs(list) do
    if ai_review.triage_status(c) == 'untriaged' and c.status == 'saved' then
      ids[#ids + 1] = c.id
    end
  end
  if #ids == 0 then
    return vim.notify('revuey: nothing untriaged in this run' .. (any_filter(M.filter(s)) and ' (with this filter)' or ''), vim.log.levels.INFO)
  end
  local verb = what == 'accept' and 'Accept' or 'Dismiss'
  if not M.confirm(('revuey: %s %d untriaged finding%s of %s?'):format(verb:lower(), #ids, #ids == 1 and '' or 's', M.run_title(g)), verb) then
    return
  end
  local store = cv().sync_store(s)
  pcall(comments.reload, store)
  local now = comments.now_ms()
  local done = {}
  for _, id in ipairs(ids) do
    local cur = comments.get(store, id)
    if cur and ai_review.triage_status(cur) == 'untriaged' and cur.status == 'saved' then
      local c = what == 'accept' and ai_review.accept(store, id, now) or ai_review.toggle_dismiss(store, id, now)
      if c then
        done[#done + 1] = c
      end
    end
  end
  if #done == 0 then
    return cv().refresh(s)
  end
  local info = cv().review_info(s)
  local ok, err = pcall(comments.save, store, info)
  if not ok then
    return vim.notify(tostring(err), vim.log.levels.ERROR)
  end
  local events = comments.events_path_for(s.review.state._path)
  for _, c in ipairs(done) do
    comments.append_event(events, comments.event(what == 'accept' and 'accepted' or 'dismissed', c, info))
  end
  vim.notify(('revuey: %s %d finding%s'):format(what == 'accept' and 'accepted' or 'dismissed', #done, #done == 1 and '' or 's'), vim.log.levels.INFO)
  cv().refresh(s)
end

---`cD`: delete the run under the cursor: its record and its findings (accepted ones are your
---comments: they stay). Asks first. A later run may find the deleted findings again.
function M.delete_run(s)
  local gid = at(s)
  if not gid then
    return vim.notify('revuey: move to a run', vim.log.levels.INFO)
  end
  local g, list = run_findings(s, gid, true)
  if not g then
    return
  end
  local gone, kept = {}, 0
  for _, c in ipairs(list) do
    if ai_review.triage_status(c) == 'accepted' then
      kept = kept + 1
    else
      gone[#gone + 1] = c.id
    end
  end
  local msg = ('revuey: delete %s and its %d finding%s?'):format(M.run_title(g), #gone, #gone == 1 and '' or 's')
  if kept > 0 then
    msg = msg .. (' (%d accepted stay as your comments)'):format(kept)
  end
  if not M.confirm(msg, 'Delete') then
    return
  end
  local store = cv().sync_store(s)
  pcall(comments.reload, store)
  local now = comments.now_ms()
  local deleted = {}
  for _, id in ipairs(gone) do
    local c = comments.delete(store, id, now)
    if c then
      -- forgotten, not triaged: a later run may find it again
      store.comments[id].ai = nil
      deleted[#deleted + 1] = c
    end
  end
  local info = cv().review_info(s)
  local ok, err = pcall(comments.save, store, info)
  if not ok then
    return vim.notify(tostring(err), vim.log.levels.ERROR)
  end
  local events = comments.events_path_for(s.review.state._path)
  for _, c in ipairs(deleted) do
    comments.append_event(events, comments.event('deleted', c, info))
  end
  if g.record then
    local rok, rerr = pcall(ai_review.remove_run, ai_review.record_path(require('revuey.ai_review_view').key(s)), g.record.id)
    if not rok then
      vim.notify('revuey: the run was not removed: ' .. tostring(rerr), vim.log.levels.ERROR)
    end
  end
  if M.filter(s).run == gid then
    M.filter(s).run = nil
  end
  vim.notify(('revuey: deleted %s (%d finding%s)'):format(M.run_title(g), #deleted, #deleted == 1 and '' or 's'), vim.log.levels.INFO)
  cv().refresh(s)
end

---`ct`: tag the finding under the cursor; on a run's heading, every finding of the run the filter
---shows.
function M.tag(s)
  local gid, id = at(s)
  if id then
    return cv().ask_tags(s, { id })
  end
  if not gid then
    return vim.notify('revuey: move to a finding or a run', vim.log.levels.INFO)
  end
  local _, list = run_findings(s, gid)
  local ids = vim.tbl_map(function(c)
    return c.id
  end, list or {})
  if #ids == 0 then
    return vim.notify('revuey: no findings in this run', vim.log.levels.INFO)
  end
  cv().ask_tags(s, ids)
end

---The tag targets under the cursor for `:RevueyTag` (a finding, or every finding of the run on
---its heading), or nil when the view does not have focus.
function M.tag_targets(s)
  local v = valid(s)
  if not (v and api.nvim_get_current_win() == v.win) then
    return nil
  end
  local gid, id = at(s)
  if id then
    return { id }
  end
  if not gid then
    return {}
  end
  local _, list = run_findings(s, gid)
  return vim.tbl_map(function(c)
    return c.id
  end, list or {})
end

---`<CR>`: the finding in the diff (in the guide when the view was opened from it and it shows
---it); on a run's heading: only that run (again: every run).
function M.show(s)
  local gid, id = at(s)
  if id then
    M.close(s)
    return cl().jump(s, id)
  end
  if gid then
    M.set_filter(s, 'run', M.filter(s).run ~= gid and gid or nil)
  end
end

function M.next(s, dir, kind)
  F.next(s, 'arlist', dir, kind)
end

---Close the view (focus back where it was opened from). `quiet`: another list replaces it.
function M.close(s, quiet)
  F.close(s, SPEC, quiet)
end

function M.detach(s)
  M.close(s)
end

function M.keymaps(s, v)
  local k = config.options.keymaps
  local map = F.mapper(v)
  local C = cv()
  local function act(fn)
    return function()
      local t = target(s)
      if t then
        fn(s, t)
      end
    end
  end
  map({ '<CR>', '<2-LeftMouse>' }, function()
    M.show(s)
  end, 'agent reviews: show the finding in the diff (on a run: only that run)')
  map({ 'q', '<Esc>' }, function()
    M.close(s)
  end, 'agent reviews: back to the diff')
  map(k.ai_reviews, function()
    M.close(s)
  end, 'agent reviews: back to the diff')
  map(k.comment_list, function()
    cl().open(s)
  end, 'the comments view: every thread in one list')
  map(k.comment_next, function()
    M.next(s, 1)
  end, 'agent reviews: next finding')
  map(k.comment_prev, function()
    M.next(s, -1)
  end, 'agent reviews: previous finding')
  map(k.next_section, function()
    M.next(s, 1, 'group')
  end, 'agent reviews: next run')
  map(k.prev_section, function()
    M.next(s, -1, 'group')
  end, 'agent reviews: previous run')
  map(k.comment_reply, act(C.reply), 'reply to the finding')
  map(k.comment_edit, act(C.edit), 'edit the finding')
  map(k.comment_delete, act(C.delete), 'delete the finding')
  map(k.comment_resolve, act(C.resolve), 'resolve / reopen the finding')
  map(k.comment_include, act(C.toggle_include), 'add the finding to the GitHub review / take it out')
  map(k.comment_accept, act(C.accept), 'accept the finding')
  map(k.comment_dismiss, act(C.dismiss), 'dismiss / restore the finding')
  map(k.send_comment, act(C.send_existing), 'send the finding to the agent')
  map(k.comment_expand, act(C.toggle_expand), 'expand / collapse the finding')
  map(k.comment_tag, function()
    M.tag(s)
  end, 'tag the finding (on a run: all its findings)')
  map(k.run_accept, function()
    M.triage_run(s, 'accept')
  end, 'accept every untriaged finding of the run')
  map(k.run_dismiss, function()
    M.triage_run(s, 'dismiss')
  end, 'dismiss every untriaged finding of the run')
  map(k.run_delete, function()
    M.delete_run(s)
  end, 'delete the run and its findings')
  map(k.reviews_filter, function()
    M.pick_any_filter(s)
  end, 'filter the findings: tag, run, status, severity')
  map(k.reviews_tag_filter, function()
    M.pick_filter(s, 'tag')
  end, 'only the findings with a tag')
  map(k.reviews_clear_filter, function()
    M.clear_filter(s)
  end, 'every finding again (no filter)')
  F.common_keys(s, map)
end

---Open the view (`gA`, `:RevueyAIReviews`, `<CR>` on the panel's AI review block).
function M.open(s)
  return F.open(s, SPEC)
end

---`gA`: open the view, or back to the diff from it.
function M.toggle(s)
  if M.active(s) then
    return M.close(s)
  end
  return M.open(s)
end

-- ---------------------------------------------------------------------------
-- Winbar and panel
-- ---------------------------------------------------------------------------

---The diff window's winbar while the view is open: `AI reviews · <scope>` and the counts, or the
---keys that work under the cursor while the view has focus.
function M.winbar(s, win)
  local v = valid(s)
  local esc = function(str)
    return (str:gsub('%%', '%%%%'))
  end
  local scope = require('revuey.guide_view').scope_title(s.review)
  local left = ' %#RevueyGuideSectionNumber#AI reviews' .. (scope and esc(' · ' .. scope) or '') .. ' '
  local n = v and v.counts or { untriaged = 0, accepted = 0, dismissed = 0 }
  local right = '%#Comment#' .. esc(counts_text(n)) .. ' '
  if v and api.nvim_get_current_win() == v.win then
    local gid, id = at(s)
    local kh = require('revuey.key_help')
    local items
    if id then
      items = vim.list_extend({ { key = '<CR>', label = 'show' } }, kh.comment_items(s, { id }, v.cut))
      local kt = key('comment_tag')
      if kt and not vim.iter(items):any(function(x)
        return x.key == kt
      end) then
        items[#items + 1] = { key = kt, label = 'tag' }
      end
    elseif gid then
      items = { { key = '<CR>', label = M.filter(s).run == gid and 'every run' or 'only this run' } }
      for _, x in ipairs({ { 'run_accept', 'accept all' }, { 'run_dismiss', 'dismiss all' }, { 'comment_tag', 'tag all' }, { 'run_delete', 'delete run' } }) do
        local kk = key(x[1])
        if kk then
          items[#items + 1] = { key = kk, label = x[2] }
        end
      end
    end
    if items and #items > 0 then
      return kh.compose(left, '', items, api.nvim_win_get_width(win))
    end
  end
  return left .. '%*%=' .. right
end

---The panel's section while the view is open: the counts.
function M.panel(s, add, add_virt)
  local v = valid(s)
  if not v then
    return
  end
  local title = ' AI reviews'
  local row = add(title, { { 0, #title, 'RevueyPanelTitle' } })
  local n = v.counts or { untriaged = 0, accepted = 0, dismissed = 0 }
  add_virt(row, { { ('%d untriaged'):format(n.untriaged), 'Comment' } })
  local f = M.filter(s)
  if any_filter(f) then
    local t = ' filtered' .. (f.tag and (' #' .. f.tag) or '')
    add(t, { { 0, #t, 'RevueyReviewsFilter' } })
  end
  add('')
end

---The panel's key lines while the view is open (keys.line templates).
M.HELP = {
  ' <CR> show  {comment_next} {comment_prev} finding  {next_section} {prev_section} run',
  ' {comment_accept} accept  {comment_dismiss} dismiss  {comment_tag} tag  q back',
  ' {run_accept} {run_dismiss} all of the run  {run_delete} delete run',
  ' {reviews_filter} filter  {reviews_tag_filter} tag filter  {reviews_clear_filter} clear',
}

return M
