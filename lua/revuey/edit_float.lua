-- The edit float: the real working-tree file in a floating window over the review, folded to the
-- hunk plus a little context. It is the file's one buffer, the same one `:edit` gives (revuey's
-- hidden LSP buffer handed over to the user when it had loaded it), so undo, LSP, completion,
-- formatters, swap files, the user's autocmds and `:checktime` behave as anywhere else. Saving
-- goes through the normal BufWritePost, which the review's working-tree auto-refresh picks up.
--
-- Nothing leaks into the user's other windows: folds are manual and local to the float, and the
-- float's window options and folds are reset before it closes (Neovim copies a closing window's
-- options and folds to the next window that shows the buffer). The close keys are buffer-local
-- (Neovim has no window-local mappings) but only act in the float; elsewhere they fall through,
-- and they are removed (and any mapping they shadowed restored) when the float closes.
local api = vim.api
local edit = require('revuey.edit')
local lsp = require('revuey.lsp')

local M = {}

---@class revuey.EditFloat
---@field win integer
---@field buf integer
---@field path string repo-relative path
---@field session table
---@field seq integer undo sequence when opened (discard goes back to it)
---@field was_modified boolean
---@field saved_maps table[]
---@field group integer

---@type revuey.EditFloat?
M.current = nil

---Question with choices (a hook so tests can answer it): returns 1 save, 2 discard, else cancel.
function M.ask(msg)
  return vim.fn.confirm(msg, '&Save\n&Discard\n&Cancel', 1, 'Question')
end

-- window options the float sets (reset to the global values before it closes)
local WIN_OPTS = {
  foldmethod = 'manual',
  foldenable = true,
  foldlevel = 0,
  foldcolumn = '0',
  number = true,
  relativenumber = false,
  cursorline = true,
  signcolumn = 'auto',
  wrap = false,
  winfixbuf = false,
}

local MAPS = {
  { 'n', 'q', 'close' },
  { 'n', '<Esc>', 'close' },
  { 'n', '<C-s>', 'save' },
  { 'i', '<C-s>', 'save' },
}

local function valid(st)
  return st and api.nvim_win_is_valid(st.win) and api.nvim_buf_is_valid(st.buf)
end

---Undo the float's own changes (not edits the buffer already had when it opened).
local function discard(st)
  api.nvim_buf_call(st.buf, function()
    pcall(vim.cmd, 'silent undo ' .. st.seq)
    if not st.was_modified and vim.bo[st.buf].modified then
      pcall(vim.cmd, 'silent edit!')
    end
  end)
end

---Write the buffer (as `:w` would). Returns false when the write failed.
local function write(st)
  local ok, err = pcall(api.nvim_buf_call, st.buf, function()
    vim.cmd('write')
  end)
  if not ok then
    vim.notify('revuey: ' .. tostring(err):gsub('^Vim:', ''), vim.log.levels.ERROR)
  end
  return ok and not vim.bo[st.buf].modified
end

---Restore what the float changed: its window options and folds (so the next window showing the
---buffer doesn't inherit them), the shadowed buffer mappings, its autocmds.
local function teardown(st)
  if st.torn then
    return
  end
  st.torn = true
  if api.nvim_win_is_valid(st.win) then
    api.nvim_win_call(st.win, function()
      pcall(vim.cmd, 'normal! zE')
      for name in pairs(WIN_OPTS) do
        pcall(api.nvim_set_option_value, name, api.nvim_get_option_value(name, { scope = 'global' }), { scope = 'local', win = st.win })
      end
    end)
  end
  if api.nvim_buf_is_valid(st.buf) then
    for _, m in ipairs(MAPS) do
      pcall(vim.keymap.del, m[1], m[2], { buffer = st.buf })
    end
    for _, saved in ipairs(st.saved_maps) do
      api.nvim_buf_call(st.buf, function()
        pcall(vim.fn.mapset, saved)
      end)
    end
  end
  pcall(api.nvim_del_augroup_by_id, st.group)
  if M.current == st then
    M.current = nil
  end
end

---Close the float. With unsaved changes, asks first: save, discard or cancel (`force` skips the
---question and keeps the changes in the buffer, as `:q` would with 'hidden').
---@return boolean closed
function M.close(o)
  o = o or {}
  local st = M.current
  if not valid(st) then
    if st then
      teardown(st)
    end
    return true
  end
  if not o.force and vim.bo[st.buf].modified then
    local choice = M.ask(('Save changes to %s?'):format(st.path))
    if choice == 1 then
      if not write(st) then
        return false
      end
    elseif choice == 2 then
      discard(st)
    else
      return false
    end
  end
  local s = st.session
  teardown(st)
  pcall(api.nvim_win_close, st.win, true)
  if s and s.diff_win and api.nvim_win_is_valid(s.diff_win) then
    api.nvim_set_current_win(s.diff_win)
  end
  return true
end

---The review `s` is going away: close its float without asking (unsaved changes stay in the
---buffer, as with `:q` and 'hidden').
function M.detach(s)
  local st = M.current
  if st and st.session == s then
    teardown(st)
    pcall(api.nvim_win_close, st.win, true)
  end
end

local function remember_maps(buf)
  local saved = {}
  for _, m in ipairs(MAPS) do
    for _, km in ipairs(api.nvim_buf_get_keymap(buf, m[1])) do
      if km.lhs == vim.keycode(m[2]) or km.lhs == m[2] then
        local d = api.nvim_buf_call(buf, function()
          return vim.fn.maparg(m[2], m[1], false, true)
        end)
        if d and d.buffer == 1 then
          saved[#saved + 1] = d
        end
      end
    end
  end
  return saved
end

local function set_maps(st)
  for _, m in ipairs(MAPS) do
    local mode, lhs, what = m[1], m[2], m[3]
    vim.keymap.set(mode, lhs, function()
      if not (M.current == st and api.nvim_get_current_win() == st.win) then
        return vim.keycode(lhs) -- another window showing this buffer: the key as usual
      end
      vim.schedule(function()
        if what == 'close' then
          M.close()
        elseif valid(st) then
          write(st)
        end
      end)
      return mode == 'i' and '' or '<Ignore>'
    end, { buffer = st.buf, expr = true, nowait = true, silent = true, desc = 'revuey: edit float ' .. what })
  end
end

---Size and place the float near the diff window's cursor: below it when there is room, else
---above it.
local function geometry(s, wanted)
  local win = s.diff_win
  local wh, ww = api.nvim_win_get_height(win), api.nvim_win_get_width(win)
  local width = math.max(20, math.min(ww - 2, 120))
  local crow = api.nvim_win_call(win, function()
    return vim.fn.winline()
  end)
  -- room for the text (the border takes two rows) below and above the cursor line
  local below, above = wh - crow - 2, crow - 3
  local height = math.max(3, math.min(wanted, math.floor(wh * 0.6)))
  local row
  if height <= below then
    row = crow -- the line below the cursor
  elseif height <= above then
    row = crow - height - 3
  elseif below >= above and below >= 3 then
    row, height = crow, below
  elseif above >= 3 then
    row, height = 0, above
  else
    row = 0 -- a tiny window: cover the cursor line
  end
  return { relative = 'win', win = win, row = row, col = 0, width = width, height = height }
end

---Open the float on `opts.abs` at the snapshot line `opts.lnum`, folded to the snapshot hunk
---range `opts.lo`..`opts.hi` (all mapped through edits made since the review was loaded).
---@param s table review session
---@param opts {abs:string, path:string, snapshot?:string, lnum:integer, lo:integer, hi:integer, col?:integer, note?:string}
---@return integer? win
function M.open(s, opts)
  if M.current and not M.close() then
    return nil
  end
  if not vim.uv.fs_stat(opts.abs) then
    vim.notify('revuey: not in the working tree: ' .. opts.path, vim.log.levels.WARN)
    return nil
  end
  -- the file's one buffer: an open one (any window, any name resolving to it), else revuey's
  -- hidden LSP buffer, else a new one; never a second buffer for the same file
  local buf = vim.fn.bufnr(opts.abs)
  if buf == -1 then
    buf = lsp.file_buffer(opts.abs)
  end
  if not buf or buf == -1 then
    vim.notify('revuey: cannot open ' .. opts.path, vim.log.levels.WARN)
    return nil
  end
  if not api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  lsp.adopt(buf)
  local current = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  local count = api.nvim_buf_line_count(buf)
  local lnum = edit.map_line(opts.snapshot, current, opts.lnum)
  local lo = edit.map_line(opts.snapshot, current, opts.lo)
  local hi = math.max(lo, edit.map_line(opts.snapshot, current, opts.hi))
  local top, bottom = edit.view_range(lo, hi, count)
  local folds = (top > 1 and 1 or 0) + (bottom < count and 1 or 0)
  local cfg = geometry(s, bottom - top + 1 + folds)
  cfg.border = 'rounded'
  cfg.title = { { (' %s:%d-%d '):format(opts.path, lo, hi), 'FloatTitle' } }
  cfg.title_pos = 'left'
  cfg.footer = { { ' :w save · q close ', 'FloatFooter' } }
  cfg.footer_pos = 'right'
  local st = {
    buf = buf,
    path = opts.path,
    session = s,
    was_modified = vim.bo[buf].modified,
    seq = api.nvim_buf_call(buf, function()
      return vim.fn.changenr()
    end),
    saved_maps = remember_maps(buf),
    lo = lo,
    hi = hi,
  }
  st.win = api.nvim_open_win(buf, true, cfg)
  M.current = st
  for name, value in pairs(WIN_OPTS) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = st.win })
  end
  api.nvim_win_call(st.win, function()
    vim.cmd('normal! zE')
    if bottom < count then
      vim.cmd(('%d,%dfold'):format(bottom + 1, count))
    end
    if top > 1 then
      vim.cmd(('1,%dfold'):format(top - 1))
    end
    api.nvim_win_set_cursor(st.win, { lnum, opts.col or 0 })
    vim.fn.winrestview({ topline = top > 1 and top - 1 or 1 })
  end)
  set_maps(st)
  st.group = api.nvim_create_augroup('revuey_edit_float_' .. st.win, { clear = true })
  -- `:q`, `<C-w>c` and friends: tidy up as the window goes (it is still valid here)
  api.nvim_create_autocmd('WinClosed', {
    group = st.group,
    pattern = tostring(st.win),
    callback = function()
      teardown(st)
    end,
  })
  -- after a save, the review refresh puts its cursor on the hunk being edited
  api.nvim_create_autocmd('BufWritePost', {
    group = st.group,
    buffer = buf,
    callback = function()
      if valid(st) then
        s.edit_focus = { path = opts.path, lnum = api.nvim_win_get_cursor(st.win)[1] }
      end
    end,
  })
  if opts.note then
    vim.notify(opts.note, vim.log.levels.INFO)
  end
  return st.win
end

return M
