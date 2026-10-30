-- Finding the keys: the winbar's hint of the keys that work on the cursor row (a comment, an AI
-- finding, an agent's comment, a GitHub thread, a guide line note; a folder header in the file
-- panel), and the `g?` float listing every key (keys.lua). The hint asks comments_view.can, the
-- rules the actions apply, so it offers only what would work; it reads the row's cached cover
-- lists (no git, no network).
local api = vim.api
local keys = require('revuey.keys')

local M = {}

-- What each kind of item offers, in order: the first ones stay when the window is narrow.
-- {keymap option, comments_view.can action}
local OWN = { { 'comment_edit', 'edit' }, { 'comment_reply', 'reply' }, { 'comment_include', 'include' },
  { 'comment_resolve', 'resolve' }, { 'comment_expand', 'expand' }, { 'comment_delete', 'delete' } }
-- an AI finding or an agent's comment, not accepted yet: triage first (cx only reopens)
local TRIAGE = { { 'comment_accept', 'accept' }, { 'comment_dismiss', 'dismiss' },
  { 'comment_resolve', 'resolve', resolved = true }, { 'send_comment', 'send' }, { 'comment_expand', 'expand' } }
local FORGE = { { 'comment_reply', 'reply' }, { 'forge_open', 'open' }, { 'comment_expand', 'expand' } }

---Hint items for the comments and GitHub threads covering `row`: {key, label} per key, the first
---item's label when several items on the row take the key.
local function comment_items(s, row, out, seen)
  local c = s.cm
  local ids = c and c.cover and c.cover[row]
  if not ids then
    return
  end
  local comments = require('revuey.comments')
  local cv = require('revuey.comments_view')
  local ai_review = require('revuey.ai_review')
  for _, id in ipairs(ids) do
    local cmt = (c.store and comments.get(c.store, id)) or (c.forge_items and c.forge_items[id])
    if cmt then
      -- accepted (and maybe resolved since), a finding or agent comment is yours: not triage
      local triage = ai_review.origin(cmt) and cmt.status ~= 'accepted' and not ai_review.accepted_from(cmt)
      local list = cmt.forge and FORGE or (triage and TRIAGE or OWN)
      for _, a in ipairs(list) do
        local key = keys.first(a[1])
        if key and not seen[key] and (not a.resolved or cmt.status == 'resolved') then
          local ok, label = cv.can(s, cmt, a[2])
          if ok then
            seen[key] = true
            out[#out + 1] = { key = key, label = label }
          end
        end
      end
    end
  end
end

---Hint items for a guide line note on `row` (guide view): the notes around it, show / hide.
local function note_items(s, row, out)
  if s.view_mode ~= 'guide' or not (s.guide_note_cover and s.guide_note_cover[row]) then
    return
  end
  local below, above = false, false
  for _, r in ipairs(s.guide_note_rows or {}) do
    below = below or r > row
    above = above or r < row
  end
  local nx = below and keys.first('next_note')
  local pv = above and keys.first('prev_note')
  if nx and pv then
    out[#out + 1] = { key = nx .. '/' .. pv, label = 'next/prev' }
  elseif nx or pv then
    out[#out + 1] = { key = nx or pv, label = nx and 'next' or 'prev' }
  end
  local t = keys.first('toggle_notes')
  if t then
    out[#out + 1] = { key = t, label = s.guide_notes_collapsed and 'show notes' or 'hide notes' }
  end
end

---The keys that work on row `row` of the review buffer, in priority order.
---@return {key:string, label:string}[]
function M.items(s, row)
  local out, seen = {}, {}
  comment_items(s, row, out, seen)
  note_items(s, row, out)
  return out
end

local function signature(items)
  local t = {}
  for _, it in ipairs(items) do
    t[#t + 1] = it.key .. ' ' .. it.label
  end
  return table.concat(t, '\n')
end

---Recompute the hint for the diff window's cursor row (CursorMoved, after comments or notes are
---drawn) and redraw the winbar when it changed (`quiet`: never, the winbar is being drawn).
function M.update(s, quiet)
  if not s or s.cleaned or not s.layout or not s.diff_win or not api.nvim_win_is_valid(s.diff_win) then
    return
  end
  local row = api.nvim_win_get_cursor(s.diff_win)[1]
  local items = M.items(s, row)
  local sig = signature(items)
  local changed = not s.key_hint or s.key_hint.sig ~= sig
  s.key_hint = { row = row, items = items, sig = sig }
  if changed and not quiet and #api.nvim_list_uis() > 0 then
    pcall(api.nvim__redraw, { win = s.diff_win, winbar = true })
  end
end

---Hint items while the file panel has focus, for the diff window's winbar (the panel is too narrow
---for them): on a folder header, `<CR>` and the folder's full path (its header may be abbreviated).
function M.panel_items(s)
  local win = s.panel_win
  if not (win and api.nvim_win_is_valid(win) and api.nvim_get_current_win() == win) then
    return {}
  end
  local g = s.panel_dirs and s.panel_dirs[api.nvim_win_get_cursor(win)[1]]
  if not g then
    return {}
  end
  return { { key = '<CR>', label = 'first file in ' .. g.path } }
end

---Redraw the diff window's winbar when the panel's hint changed (panel CursorMoved, focus).
function M.update_panel(s)
  if not s or s.cleaned or not s.diff_win or not api.nvim_win_is_valid(s.diff_win) then
    return
  end
  local sig = signature(M.panel_items(s))
  if s.key_hint_panel == sig then
    return
  end
  s.key_hint_panel = sig
  if #api.nvim_list_uis() > 0 then
    pcall(api.nvim__redraw, { win = s.diff_win, winbar = true })
  end
end

---Hint items for the winbar of `win`: only while it is the current window (the keys act there),
---or while the file panel is (panel_items).
function M.current(s, win)
  if win == s.diff_win and s.panel_win and api.nvim_get_current_win() == s.panel_win then
    return M.panel_items(s)
  end
  if win ~= api.nvim_get_current_win() or win ~= s.diff_win then
    return {}
  end
  local row = api.nvim_win_get_cursor(win)[1]
  if not s.key_hint or s.key_hint.row ~= row then
    -- the cursor moved and CursorMoved has not run yet
    M.update(s, true)
  end
  return s.key_hint and s.key_hint.items or {}
end

---Display width of a statusline string (highlights and %% removed).
function M.plain_width(str)
  local plain = str:gsub('%%#[^#]*#', ''):gsub('%%[*<=]', ''):gsub('%%%%', '%%')
  return api.nvim_strwidth(plain)
end

M.SEP = ' · '

---The hint as statusline text, keeping the first items that fit in `avail` cells (at least one).
---@return string text, integer width
function M.format(items, avail)
  local n, used = 0, 0
  for i, it in ipairs(items) do
    local w = api.nvim_strwidth(it.key .. ' ' .. it.label) + (i > 1 and api.nvim_strwidth(M.SEP) or 0)
    if i > 1 and used + w > avail then
      break
    end
    n, used = i, used + w
  end
  local parts = {}
  for i = 1, n do
    local it = items[i]
    parts[#parts + 1] = '%#RevueyKeyHintKey#' .. it.key:gsub('%%', '%%%%') .. '%#RevueyKeyHint# ' .. it.label
  end
  return table.concat(parts, '%#RevueyKeyHint#' .. M.SEP), used
end

-- Cells of the left part (file or section at the top) the hint never takes: in a 79-cell diff
-- window (120 columns, the panel at 40) a file name like `A src/cart.ts +27 −0` stays whole and
-- your comment's first four keys fit; the last ones (`cd delete`: it asks first anyway) are the
-- ones left out, and `g?` has them all.
M.LEFT_MIN = 20

---A winbar: `left` (with a `%<` where it may be cut), then on the right `right` (kept) and the
---hint, cut to the window's width.
function M.compose(left, right, items, width)
  local avail = width - math.min(M.plain_width(left), M.LEFT_MIN) - M.plain_width(right) - 2
  local hint = M.format(items, avail)
  return left .. '%*%= ' .. right .. hint .. '%* '
end

-- ---------------------------------------------------------------------------
-- g?: every key in a float
-- ---------------------------------------------------------------------------

---Lines of the cheat sheet: {text, hls} (hls: {start, end, group}), from the keymap options.
function M.sheet_lines()
  local rows, kw = {}, 0
  for _, g in ipairs(keys.GROUPS) do
    local list = {}
    for _, e in ipairs(g) do
      local k = keys.text(e)
      if k then
        list[#list + 1] = { k, e.desc }
        kw = math.max(kw, api.nvim_strwidth(k))
      end
    end
    if #list > 0 then
      rows[#rows + 1] = { group = g.name, list = list }
    end
  end
  local out = {}
  for i, r in ipairs(rows) do
    if i > 1 then
      out[#out + 1] = { text = '', hls = {} }
    end
    out[#out + 1] = { text = ' ' .. r.group, hls = { { 1, 1 + #r.group, 'RevueyKeyHelpGroup' } } }
    for _, x in ipairs(r.list) do
      local k = x[1] .. string.rep(' ', kw - api.nvim_strwidth(x[1]))
      local text = '   ' .. k .. '  ' .. x[2]
      out[#out + 1] = { text = text, hls = { { 3, 3 + #x[1], 'RevueyKeyHintKey' } } }
    end
  end
  return out
end

M.state = nil

function M.close()
  local st = M.state
  M.state = nil
  if st and api.nvim_win_is_valid(st.win) then
    pcall(api.nvim_win_close, st.win, true)
  end
end

---`g?`: open the cheat sheet (or close it when open). Works without a review too.
function M.toggle()
  if M.state and api.nvim_win_is_valid(M.state.win) then
    return M.close()
  end
  local lines = M.sheet_lines()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(l)
    return l.text
  end, lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'revuey-keys'
  local ns = api.nvim_create_namespace('revuey.keys')
  local widest = 20
  for i, l in ipairs(lines) do
    widest = math.max(widest, api.nvim_strwidth(l.text))
    for _, h in ipairs(l.hls) do
      pcall(api.nvim_buf_set_extmark, buf, ns, i - 1, h[1], { end_col = h[2], hl_group = h[3] })
    end
  end
  local width = math.max(1, math.min(widest + 1, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local close_keys = { 'q', '<Esc>' }
  vim.list_extend(close_keys, keys.list('help'))
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = 'rounded',
    style = 'minimal',
    title = ' revuey keys ',
    title_pos = 'left',
    footer = ' ' .. table.concat(close_keys, ' ') .. ' close ',
    footer_pos = 'right',
    zindex = 55,
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  M.state = { win = win, buf = buf }
  for _, k in ipairs(close_keys) do
    vim.keymap.set('n', k, M.close, { buffer = buf, nowait = true, silent = true, desc = 'revuey: close the key list' })
  end
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if M.state and M.state.buf == buf then
          M.close()
        end
      end)
    end,
  })
  return M.state
end

return M
