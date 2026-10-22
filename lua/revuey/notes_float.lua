-- Details float for stack notes (panel key `!`): every note in full, grouped by kind, with what it
-- means, whether it affects the review, and the branches involved. Actions per branch row: set as
-- parent, clear a parent setting, ignore the branch, ignore a pattern, un-ignore. After an action
-- the review refreshes, and the float re-renders from the new notes (panel.render calls update).
local api = vim.api
local notes_mod = require('revuey.stack_notes')

local M = {}

local ns = api.nvim_create_namespace('revuey.notes')

---@type {s:table, win:integer, buf:integer, rows:table<integer, table>}?
M.state = nil

-- footer: only the keys some row offers, then <CR> and q
local KEYS = {
  { 'p', 'p set as parent' },
  { 'c', 'c clear parent setting' },
  { 'x', 'x ignore branch' },
  { 'X', 'X ignore pattern' },
  { 'u', 'u stop ignoring' },
}

local function footer(rows)
  local used = {}
  for _, e in pairs(rows) do
    for _, a in ipairs(e.actions or {}) do
      used[a.key] = true
    end
  end
  local parts = {}
  for _, k in ipairs(KEYS) do
    if used[k[1]] then
      parts[#parts + 1] = k[2]
    end
  end
  if #parts > 0 then
    parts[#parts + 1] = '<CR> choose'
  end
  parts[#parts + 1] = 'q close'
  return table.concat(parts, ' · ')
end

function M.is_open()
  return M.state ~= nil and api.nvim_win_is_valid(M.state.win)
end

function M.close()
  local st = M.state
  M.state = nil
  if st and api.nvim_win_is_valid(st.win) then
    pcall(api.nvim_win_close, st.win, true)
  end
end

local function width()
  return math.max(30, math.min(88, vim.o.columns - 6))
end

local function render(st)
  local s = st.s
  local key = require('revuey.panel').notes_key()
  local notes, ignored, ctx = notes_mod.of_review(s.review, key)
  local patterns = require('revuey.stack_ignore').for_root(s.review.root, s.opts.state_dir)
  local w = width()
  local model = notes_mod.details(notes, ignored, patterns, ctx, w - 2)
  local lines = model.lines
  lines[#lines + 1] = ''
  local foot_from = #lines + 1
  vim.list_extend(lines, notes_mod.wrap(footer(model.rows), w - 2, ''))
  vim.bo[st.buf].modifiable = true
  api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  for _, h in ipairs(model.hls) do
    pcall(api.nvim_buf_set_extmark, st.buf, ns, h[1] - 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  for row = foot_from, #lines do
    api.nvim_buf_set_extmark(st.buf, ns, row - 1, 0, { end_col = #lines[row], hl_group = 'RevueyStackNote' })
  end
  for row, hint in pairs(model.hints) do
    if vim.fn.strdisplaywidth(lines[row]) + vim.fn.strdisplaywidth(hint) + 2 <= w then
      api.nvim_buf_set_extmark(st.buf, ns, row - 1, 0, { virt_text = { { hint, 'RevueyStackNote' } }, virt_text_pos = 'right_align' })
    end
  end
  st.rows = model.rows
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  api.nvim_win_set_config(st.win, {
    relative = 'editor',
    width = w,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - w) / 2),
    title = ctx.stack and ' Stack notes ' or ' Branch notes ',
    title_pos = 'center',
  })
  local cur = api.nvim_win_get_cursor(st.win)[1]
  if cur > #lines or not st.rows[cur] then
    -- first branch row at or after the cursor, else the first one
    local best
    for row in pairs(st.rows) do
      if (row >= math.min(cur, #lines)) and (not best or row < best) then
        best = row
      end
    end
    if not best then
      for row in pairs(st.rows) do
        best = (not best or row < best) and row or best
      end
    end
    pcall(api.nvim_win_set_cursor, st.win, { best or 1, 4 })
  end
end

---Re-render when open (called after every panel render). Closes when the review went away.
function M.update(s)
  local st = M.state
  if not st then
    return
  end
  if not M.is_open() or st.s ~= s or s.cleaned then
    return M.close()
  end
  render(st)
end

local function entry()
  local st = M.state
  if not st then
    return nil
  end
  return st.rows[api.nvim_win_get_cursor(st.win)[1]]
end

local function run(a)
  local view = require('revuey.view')
  if a.id == 'parent' then
    view.set_stack_parent(a.branch, a.parent)
  elseif a.id == 'clear' then
    view.set_stack_parent(a.branch, '')
  elseif a.id == 'ignore' then
    view.stack_ignore(a.pattern)
  elseif a.id == 'unignore' then
    view.stack_ignore(a.pattern, true)
  elseif a.id == 'pattern' then
    -- say how broad the suggestion is when it covers more than a few branches
    local prompt = 'Ignore branches matching: '
    local st = M.state
    local root = st and st.s.review.root
    local out = root and require('revuey.git').git({ 'for-each-ref', '--format=%(refname:short)', 'refs/heads' }, root)
    if out then
      local n = require('revuey.stack_ignore').count(a.pattern, vim.split(out, '\n', { trimempty = true }))
      if n > 3 then
        prompt = ('Ignore branches matching (the suggestion matches %d branches): '):format(n)
      end
    end
    vim.ui.input({ prompt = prompt, default = a.pattern }, function(input)
      input = input and vim.trim(input) or ''
      if input ~= '' then
        view.stack_ignore(input)
      end
    end)
  end
end

---Run the action `id` for the branch row under the cursor.
function M.act(id)
  local e = entry()
  for _, a in ipairs(e and e.actions or {}) do
    if a.id == id then
      return run(a)
    end
  end
  vim.notify('revuey: ' .. (e and 'that action does not apply to this row' or 'put the cursor on a branch row first'), vim.log.levels.INFO)
end

---Pick one of the row's actions from a list.
function M.choose()
  local e = entry()
  local acts = e and e.actions or {}
  if #acts == 0 then
    return vim.notify('revuey: ' .. (e and 'no actions for this row' or 'put the cursor on a branch row first'), vim.log.levels.INFO)
  end
  vim.ui.select(acts, {
    prompt = (e.branch or (e.pattern_entry and e.pattern_entry.pattern) or '') .. ':',
    format_item = function(a)
      return a.label
    end,
  }, function(a)
    if a then
      run(a)
    end
  end)
end

---Open the float for session `s` (focuses it when already open).
function M.open(s)
  if not s then
    return vim.notify('revuey: no review open', vim.log.levels.INFO)
  end
  if M.is_open() and M.state.s == s then
    api.nvim_set_current_win(M.state.win)
    return
  end
  M.close()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'revuey-notes'
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width(),
    height = 1,
    row = 1,
    col = 1,
    border = 'rounded',
    style = 'minimal',
    title = ' Stack notes ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  M.state = { s = s, win = win, buf = buf, rows = {} }
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'revuey notes: ' .. desc })
  end
  map('q', M.close, 'close')
  map('<Esc>', M.close, 'close')
  local nk = require('revuey.panel').notes_key()
  if nk then
    map(nk, M.close, 'close')
  end
  map('p', function()
    M.act('parent')
  end, 'set as parent')
  map('c', function()
    M.act('clear')
  end, 'clear parent setting')
  map('x', function()
    M.act('ignore')
  end, 'ignore branch')
  map('X', function()
    M.act('pattern')
  end, 'ignore pattern')
  map('u', function()
    M.act('unignore')
  end, 'stop ignoring')
  map('<CR>', M.choose, 'choose an action')
  local group = api.nvim_create_augroup('revuey.notes_float', { clear = true })
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if M.is_open() and M.state.buf == buf then
        render(M.state)
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      if M.state and M.state.buf == buf then
        M.state = nil
      end
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  render(M.state)
end

---Toggle the float.
function M.toggle(s)
  if M.is_open() then
    return M.close()
  end
  M.open(s)
end

return M
