-- The comment editor: a small floating markdown buffer anchored under the commented line, with
-- the anchor in its title. <C-s> or :w saves; q or <Esc><Esc> cancels (asking first when text
-- would be lost); closing it any other way (:q, <C-w>c, another window) keeps the text as a
-- draft through `on_draft`. The send key (<C-a>) hands the text to `on_send`, the hook for the
-- later "send to an AI / agent session" action.
local api = vim.api

local M = {}

---Ask before discarding; tests replace this.
---@return boolean
function M.confirm(msg)
  return vim.fn.confirm(msg, '&Discard\n&Keep editing', 2) == 1
end

---@type {buf:integer, win:integer, opts:table, done:boolean, original:string}?
M.current = nil

local seq = 0

local function text_of(buf)
  if not api.nvim_buf_is_valid(buf) then
    return ''
  end
  return vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
end

local function keys()
  local k = require('revuey.config').options.keymaps
  return k.comment_send
end

---Close the editor window (without saving) and wipe its buffer.
local function close(st)
  st.done = true
  if M.current == st then
    M.current = nil
  end
  if api.nvim_win_is_valid(st.win) then
    pcall(api.nvim_win_close, st.win, true)
  end
  if api.nvim_buf_is_valid(st.buf) then
    pcall(api.nvim_buf_delete, st.buf, { force = true })
  end
  if st.opts.return_win and api.nvim_win_is_valid(st.opts.return_win) then
    pcall(api.nvim_set_current_win, st.opts.return_win)
  end
end

---Save the text (empty text is not saved).
function M.save(st)
  st = st or M.current
  if not st or st.done then
    return false
  end
  local t = text_of(st.buf)
  if t == '' then
    vim.notify('revuey: empty comment not saved (q cancels)', vim.log.levels.WARN)
    return false
  end
  vim.cmd('stopinsert')
  close(st)
  st.opts.on_save(t)
  return true
end

---Cancel: discard the text, asking first when there is unsaved text.
function M.cancel(st)
  st = st or M.current
  if not st or st.done then
    return false
  end
  local t = text_of(st.buf)
  if t ~= '' and t ~= st.original and not M.confirm('revuey: discard this comment?') then
    return false
  end
  vim.cmd('stopinsert')
  close(st)
  if st.opts.on_cancel then
    st.opts.on_cancel()
  end
  return true
end

---The send action (reserved for sending to an AI / agent session).
function M.send(st)
  st = st or M.current
  if not st or st.done or not st.opts.on_send then
    return false
  end
  local t = text_of(st.buf)
  if st.opts.on_send(t) then
    vim.cmd('stopinsert')
    close(st)
    return true
  end
  return false
end

---Open the editor.
---@param o {title:string, win:integer, row:integer, col?:integer, text?:string, footer?:string, startinsert?:boolean, return_win?:integer, on_save:fun(text:string), on_draft?:fun(text:string), on_cancel?:fun(), on_send?:fun(text:string):boolean}
---@return table state
function M.open(o)
  if M.current and not M.current.done then
    -- one editor at a time: the open one keeps its text as a draft
    local prev = M.current
    local t = text_of(prev.buf)
    close(prev)
    if t ~= '' and t ~= prev.original and prev.opts.on_draft then
      prev.opts.on_draft(t)
    end
  end
  seq = seq + 1
  local buf = api.nvim_create_buf(false, false)
  pcall(api.nvim_buf_set_name, buf, 'revuey://comment/' .. seq)
  vim.bo[buf].buftype = 'acwrite'
  -- hide, not wipe: `:q` on a buffer with typed text must close the window (the text becomes a
  -- draft), not fail with E37; the buffer is wiped when the window closes
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  local text = o.text or ''
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modified = false
  local host_w = api.nvim_win_get_width(o.win)
  local col = o.col or 0
  local width = math.max(30, math.min(80, host_w - col - 2))
  local height = math.max(4, math.min(12, #vim.split(text, '\n', { plain = true }) + 2))
  local send = keys()
  local footer = o.footer or (' <C-s> save  q cancel' .. (send and ('  ' .. send .. ' send') or '') .. ' ')
  local win = api.nvim_open_win(buf, true, {
    relative = 'win',
    win = o.win,
    bufpos = { math.max(o.row - 1, 0), 0 },
    row = 1,
    col = col,
    width = width,
    height = height,
    border = 'rounded',
    style = 'minimal',
    title = ' ' .. o.title .. ' ',
    title_pos = 'left',
    footer = footer,
    footer_pos = 'right',
    zindex = 60,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'FloatTitle:RevueyCommentTitle'
  local st = { buf = buf, win = win, opts = o, done = false, original = vim.trim(text) }
  M.current = st
  local function map(modes, lhs, fn, desc)
    if lhs then
      vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'revuey comment: ' .. desc })
    end
  end
  map({ 'n', 'i' }, '<C-s>', function()
    M.save(st)
  end, 'save')
  map('n', 'q', function()
    M.cancel(st)
  end, 'cancel')
  map('n', '<Esc><Esc>', function()
    M.cancel(st)
  end, 'cancel')
  map({ 'n', 'i' }, send, function()
    M.send(st)
  end, 'send to an AI / agent session')
  local group = api.nvim_create_augroup('revuey_comment_editor_' .. seq, { clear = true })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      vim.schedule(function()
        M.save(st)
      end)
    end,
  })
  -- never "modified": :q must not refuse, and a stray :qa must not prompt (the text is kept as a
  -- draft when the window closes)
  api.nvim_create_autocmd({ 'BufModifiedSet', 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.bo[buf].modified then
        vim.bo[buf].modified = false
      end
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, group)
      if st.done then
        return
      end
      local t = text_of(buf)
      st.done = true
      if M.current == st then
        M.current = nil
      end
      vim.schedule(function()
        if api.nvim_buf_is_valid(buf) then
          pcall(api.nvim_buf_delete, buf, { force = true })
        end
        if t ~= '' and t ~= st.original and o.on_draft then
          o.on_draft(t)
        end
      end)
    end,
  })
  if o.startinsert then
    vim.cmd('startinsert!')
  end
  return st
end

return M
