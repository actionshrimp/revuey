-- Proxy LSP client for review buffers (ARCHITECTURE decision 3, "projected LSP").
--
-- A review buffer is a scratch buffer, so no language server attaches to it and the user's own
-- vim.lsp.buf.* mappings (and pickers built on LSP requests) fail with "not supported by any
-- server". This module attaches an in-process client named "revuey" (vim.lsp.start with a Lua
-- `cmd`) that advertises only navigation capabilities. Each request is mapped from the composed
-- row to the real file through the side table, sent to the real server via the hidden buffer
-- (lsp.request, with its readiness wait), and the result is returned with locations in the real
-- files, as any server would return them.
--
-- Jumps replace the buffer of the current window, which here is the review's diff window. The
-- diff buffer is therefore kept when hidden (bufhidden=hide), and a buffer that lands in the diff
-- window is moved to the code window below it, with the review put back.
local api = vim.api
local lsp = require('revuey.lsp')

local M = {}

M.NAME = 'revuey'
-- Positions in requests and replies of the proxy client. Results from a server with another
-- encoding are converted.
M.ENCODING = 'utf-16'

local METHODS = {
  ['textDocument/definition'] = 'definitionProvider',
  ['textDocument/typeDefinition'] = 'typeDefinitionProvider',
  ['textDocument/declaration'] = 'declarationProvider',
  ['textDocument/implementation'] = 'implementationProvider',
  ['textDocument/references'] = 'referencesProvider',
  ['textDocument/hover'] = 'hoverProvider',
}

-- Only navigation: no diagnostics, semantic tokens, inlay hints, formatting, completion or code
-- actions, so the user's LspAttach handlers enable nothing that would misbehave on a diff. No
-- document sync either: the composed buffer's text means nothing to a server.
M.capabilities = { positionEncoding = M.ENCODING, textDocumentSync = { openClose = false, change = 0 } }
for _, cap in pairs(METHODS) do
  M.capabilities[cap] = true
end

local REQUEST_FAILED = -32803
local METHOD_NOT_FOUND = -32601

local clients = {} ---@type table<integer, integer> review buffer -> proxy client id

local function session_for(buf)
  local view = package.loaded['revuey.view']
  local s = view and view.session
  if s and s.diff_buf == buf and not s.cleaned then
    return s
  end
end

---Map a position in a review buffer to a target in the real file.
---@return table? target {abs, lnum, col, text, head} for lsp.request
---@return integer|string row, or the reason there is no target
function M.target(s, line0, character)
  local row = line0 + 1
  local e = s.layout.map[row]
  local text = s.layout.lines[row]
  local f = e and e.file_idx and s.review.files[e.file_idx]
  if e and e.kind == 'del' then
    return nil, 'revuey: no LSP on a deleted line (it is not in the new version of the file)'
  end
  if not f or not text or (e.kind ~= 'add' and e.kind ~= 'ctx') then
    return nil, 'revuey: LSP is available on added and context lines only'
  end
  return {
    abs = vim.fs.joinpath(s.review.root, f.path),
    lnum = e.new_lnum,
    col = vim.str_byteindex(text, M.ENCODING, character, false),
    text = text,
    head = require('revuey.view').head_text(s, f),
  }, row
end

-- ---------------------------------------------------------------------------
-- Result conversion
-- ---------------------------------------------------------------------------

---Text of line `line0` (0-based) of the file at `uri`, from its buffer when loaded.
local function line_text(uri, line0)
  local ok, fname = pcall(vim.uri_to_fname, uri)
  if not ok then
    return nil
  end
  local b = vim.fn.bufnr(fname)
  if b > 0 and api.nvim_buf_is_loaded(b) then
    return api.nvim_buf_get_lines(b, line0, line0 + 1, false)[1]
  end
  local fd = io.open(fname, 'r')
  if not fd then
    return nil
  end
  local i, found = 0, nil
  for l in fd:lines() do
    if i == line0 then
      found = l
      break
    end
    i = i + 1
  end
  fd:close()
  return found
end

local function convert_pos(text, pos, from, to)
  if not text then
    return
  end
  local ok, byte = pcall(vim.str_byteindex, text, from, pos.character, false)
  if ok then
    local ok2, char = pcall(vim.str_utfindex, text, to, byte, false)
    if ok2 then
      pos.character = char
    end
  end
end

local function convert_range(uri, range, from, to)
  if range then
    convert_pos(line_text(uri, range.start.line), range.start, from, to)
    convert_pos(line_text(uri, range['end'].line), range['end'], from, to)
  end
end

---Locations stay in the real files; only their encoding changes. originSelectionRange refers to
---the hidden buffer, not the review buffer, so it is dropped.
function M.convert_locations(result, from)
  if type(result) ~= 'table' then
    return result
  end
  local list = (result.uri or result.targetUri) and { result } or result
  for _, loc in ipairs(list) do
    loc.originSelectionRange = nil
    if from ~= M.ENCODING then
      local uri = loc.uri or loc.targetUri
      convert_range(uri, loc.range, from, M.ENCODING)
      convert_range(uri, loc.targetRange, from, M.ENCODING)
      convert_range(uri, loc.targetSelectionRange, from, M.ENCODING)
    end
  end
  return result
end

---A hover range on the requested line moves to the review row (same text); others are dropped.
local function convert_hover(result, from, lnum, row, text)
  local r = type(result) == 'table' and result.range
  if r then
    if r.start.line == lnum - 1 and r['end'].line == lnum - 1 then
      r.start.line, r['end'].line = row - 1, row - 1
      if from ~= M.ENCODING then
        convert_pos(text, r.start, from, M.ENCODING)
        convert_pos(text, r['end'], from, M.ENCODING)
      end
    else
      result.range = nil
    end
  end
  return result
end

local function hover_empty(r)
  if type(r) ~= 'table' or r.contents == nil then
    return true
  end
  local c = r.contents
  return c == '' or (type(c) == 'table' and (c.value == '' or (c.value == nil and vim.tbl_isempty(c))))
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

---Answer one request on a review buffer. `reply(err, result, quiet)` is called exactly once,
---unless the returned handle is cancelled first. Where there is no LSP (deleted or meta rows, no
---server for the filetype) revuey shows its one message and replies with an empty result,
---`quiet` so the caller's own "No locations found" is not shown as well.
---@return {cancel: fun()}?
function M.handle(method, params, reply)
  local function fail(msg)
    vim.notify(msg, vim.log.levels.WARN)
    reply(nil, nil, true)
  end
  local uri = params and params.textDocument and params.textDocument.uri
  local view = package.loaded['revuey.view']
  local s = view and view.session
  if not (s and not s.cleaned and api.nvim_buf_is_valid(s.diff_buf) and vim.uri_from_bufnr(s.diff_buf) == uri) then
    return fail('revuey: this buffer is not part of the open review')
  end
  local target, row = M.target(s, params.position.line, params.position.character)
  if not target then
    return fail(row --[[@as string]])
  end
  local extra = {}
  for k, v in pairs(params) do
    if k ~= 'textDocument' and k ~= 'position' then
      extra[k] = v
    end
  end
  local hover = method == 'textDocument/hover'
  return lsp.request(target, method, function(err, result, client, _, lnum)
    if err then
      return reply(err)
    end
    local enc = client and client.offset_encoding or M.ENCODING
    if hover then
      result = convert_hover(result, enc, lnum, row, target.text)
    else
      result = M.convert_locations(result, enc)
    end
    reply(nil, result)
  end, hover and hover_empty or nil, { on_fail = fail, params = extra })
end

---The in-process "server": an RPC client object as vim.lsp.start expects from a function `cmd`
---(vim.lsp.rpc.PublicClient). Replies are always asynchronous, like a real server's.
-- Core's own messages for an empty result. When revuey has already said why there is no result,
-- these are suppressed while the reply's handler runs (it runs synchronously from the callback).
local EMPTY_MESSAGES = {
  ['No locations found'] = true,
  ['No references found'] = true,
  ['No information available'] = true,
  ['Empty hover response'] = true,
}

local function quietly(fn)
  local orig = vim.notify
  vim.notify = function(msg, ...)
    if EMPTY_MESSAGES[msg] then
      return
    end
    return orig(msg, ...)
  end
  local ok, e = pcall(fn)
  vim.notify = orig
  if not ok then
    error(e, 0)
  end
end

local function new_server(dispatchers)
  local closing = false
  local next_id = 0
  local pending = {} ---@type table<integer, {handle?: {cancel: fun()}, ack?: fun(id: integer)}>
  local function exit()
    if not closing then
      closing = true
      for _, p in pairs(pending) do
        if p.handle then
          p.handle.cancel()
        end
      end
      pending = {}
      vim.schedule(function()
        dispatchers.on_exit(0, 0)
      end)
    end
  end
  local srv = {}
  function srv.request(method, params, callback, notify_reply_callback)
    if closing then
      return false
    end
    next_id = next_id + 1
    local id = next_id
    local entry = { ack = notify_reply_callback }
    pending[id] = entry
    local function reply(err, result, quiet)
      vim.schedule(function()
        if pending[id] ~= entry then
          return -- cancelled: acknowledged already, the callback must not run
        end
        pending[id] = nil
        if notify_reply_callback then
          notify_reply_callback(id)
        end
        if quiet then
          quietly(function()
            callback(err, result, id)
          end)
        else
          callback(err, result, id)
        end
      end)
    end
    if method == 'initialize' then
      reply(nil, { capabilities = M.capabilities, serverInfo = { name = M.NAME } })
      vim.defer_fn(M.sweep, 1000)
    elseif method == 'shutdown' then
      reply(nil, nil)
    elseif METHODS[method] then
      local ok, e = pcall(M.handle, method, params, reply)
      if not ok then
        reply({ code = REQUEST_FAILED, message = 'revuey: ' .. tostring(e) })
      elseif pending[id] == entry then
        entry.handle = e
      end
    else
      reply({ code = METHOD_NOT_FOUND, message = 'revuey: unsupported method ' .. method })
    end
    return true, id
  end
  function srv.notify(method, params)
    if method == 'exit' then
      exit()
    elseif method == '$/cancelRequest' then
      -- like a real server: stop the work (and the request forwarded to the real server), then
      -- acknowledge; the client drops the callback of a cancelled request
      local id = params and params.id
      local entry = id and pending[id]
      if entry then
        pending[id] = nil
        if entry.handle then
          entry.handle.cancel()
        end
        if entry.ack then
          vim.schedule(function()
            entry.ack(id)
          end)
        end
      end
    end
    return not closing
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    exit()
  end
  return srv
end

-- ---------------------------------------------------------------------------
-- Keeping the review in its window
-- ---------------------------------------------------------------------------

local function closed_folds(win)
  return api.nvim_win_call(win, function()
    local out, row, last = {}, 1, api.nvim_buf_line_count(0)
    while row <= last do
      local c = vim.fn.foldclosed(row)
      if c ~= -1 then
        out[#out + 1] = c
        row = vim.fn.foldclosedend(row) + 1
      else
        row = row + 1
      end
    end
    return out
  end)
end

---No history inherited from the diff window: <C-o>/<C-t> there must not bring the review back.
local function fresh_history(win)
  pcall(api.nvim_win_call, win, function()
    vim.cmd('clearjumps')
  end)
  pcall(vim.fn.settagstack, win, { items = {} }, 'r')
end

---Split the diff window (it shows the other buffer at this point, never the review). A test
---seam: replaced to simulate E36 (no room).
function M.split_below(s)
  return api.nvim_win_call(s.diff_win, function()
    vim.cmd('belowright split')
    return api.nvim_get_current_win()
  end)
end

---The code window below the review, created if needed. nil when there is no room for a split.
local function code_target(s)
  local cw = s.code_win
  if cw and api.nvim_win_is_valid(cw) and api.nvim_win_get_tabpage(cw) == s.tab and not vim.wo[cw].winfixbuf then
    return cw
  end
  local ok, w = pcall(M.split_below, s)
  if not ok or type(w) ~= 'number' or not api.nvim_win_is_valid(w) then
    return nil
  end
  pcall(api.nvim_win_set_height, w, math.floor(vim.o.lines * 0.45))
  vim.wo[w].winfixbuf = false
  fresh_history(w)
  s.code_win = w
  return w
end

---Another buffer replaced the review in the diff window (a jump from vim.lsp.buf.definition, a
---picker or the quickfix list): show that buffer in the code window (or, with no room for one,
---a new tab) *first*, so a bufhidden=wipe/delete/unload buffer is never hidden, then put the
---review back.
local function put_back(s, buf, saved)
  local win = s.diff_win
  if not (api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf)) then
    return
  end
  local other = api.nvim_win_get_buf(win)
  if other == buf then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  local focus = api.nvim_get_current_win() == win
  local target = code_target(s)
  if target and api.nvim_win_get_buf(target) ~= other and not pcall(api.nvim_win_set_buf, target, other) then
    target = nil
  end
  if not target then
    if not pcall(vim.cmd, 'tab sbuffer ' .. other) then
      return vim.notify('revuey: no room to show the buffer outside the review', vim.log.levels.WARN)
    end
    target = api.nvim_get_current_win()
    fresh_history(target)
    focus = true
  end
  if not (api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf)) then
    return
  end
  api.nvim_win_set_buf(win, buf)
  if saved then
    pcall(api.nvim_win_call, win, function()
      vim.cmd('silent! %foldopen!')
      for _, row in ipairs(saved.folds) do
        vim.cmd('silent! ' .. row .. 'foldclose')
      end
      vim.fn.winrestview(saved.view)
    end)
  end
  if api.nvim_win_is_valid(target) then
    pcall(api.nvim_win_set_cursor, target, cursor)
    if focus then
      api.nvim_set_current_win(target)
    end
    pcall(api.nvim_win_call, target, function()
      vim.cmd('normal! zvzz')
    end)
  end
end

local function keep_in_window(buf, group)
  vim.bo[buf].bufhidden = 'hide'
  local saved
  api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = buf,
    callback = function()
      local s = session_for(buf)
      local win = api.nvim_get_current_win()
      saved = nil
      if s and win == s.diff_win and api.nvim_win_get_buf(win) == buf then
        saved = { view = vim.fn.winsaveview(), folds = closed_folds(win) }
      end
      vim.schedule(function()
        if not api.nvim_buf_is_valid(buf) or #vim.fn.win_findbuf(buf) > 0 then
          return
        end
        s = session_for(buf)
        if s and api.nvim_win_is_valid(s.diff_win) and api.nvim_win_get_tabpage(s.diff_win) == s.tab then
          local ok, e = pcall(put_back, s, buf, saved)
          if not ok then
            vim.notify('revuey: could not restore the review window: ' .. tostring(e), vim.log.levels.WARN)
          end
        else
          -- the review window is gone: what bufhidden=wipe did before (cleans up the session)
          pcall(api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
  -- <C-o>/<C-t> in the code window can lead back to the review (its jumplist and tagstack start
  -- as copies of the diff window's, and jumps from there record the review). Treat that as "back
  -- to the review": the code window keeps its file and the diff window gets the position.
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function()
      local s = session_for(buf)
      local win = api.nvim_get_current_win()
      if not (s and win == s.code_win and win ~= s.diff_win) then
        return
      end
      vim.schedule(function()
        if not (api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf) then
          return
        end
        local cursor = api.nvim_win_get_cursor(win) -- the jump's position, set after BufWinEnter
        local alt = api.nvim_win_call(win, function()
          return vim.fn.bufnr('#')
        end)
        if alt > 0 and alt ~= buf and api.nvim_buf_is_valid(alt) and pcall(api.nvim_win_set_buf, win, alt) then
          -- the file stays as it was in the code window
        elseif #api.nvim_tabpage_list_wins(s.tab) > 2 then
          pcall(api.nvim_win_close, win, false)
        end
        if api.nvim_win_is_valid(s.diff_win) and api.nvim_win_get_buf(s.diff_win) == buf then
          pcall(api.nvim_win_set_cursor, s.diff_win, cursor)
          api.nvim_set_current_win(s.diff_win)
          pcall(api.nvim_win_call, s.diff_win, function()
            vim.cmd('normal! zv')
          end)
        end
      end)
    end,
  })
  -- :tabclose on the review: wipe at once, as bufhidden=wipe would have (nested, so the
  -- BufWipeout handlers that clean up the session and stop the client run)
  api.nvim_create_autocmd('TabClosed', {
    group = group,
    nested = true,
    callback = function()
      if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

---Attach the proxy client to a review buffer (called on FileType revuey; deferred so the
---session exists). Stopped when the buffer is wiped, which closing the review does.
function M.attach(buf)
  vim.schedule(function()
    if clients[buf] or not api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'revuey' then
      return
    end
    local s = session_for(buf)
    local id = vim.lsp.start({
      name = M.NAME,
      cmd = new_server,
      root_dir = s and s.review.root or nil,
    }, {
      bufnr = buf,
      reuse_client = function()
        return false
      end,
    })
    if not id then
      return
    end
    clients[buf] = id
    local group = api.nvim_create_augroup('revuey_lsp_proxy_' .. buf, { clear = true })
    keep_in_window(buf, group)
    -- Pickers: snacks.picker opens selections in a "main" window and skips non-file buffers, so
    -- it fell back to the file panel. Flag the review buffer as its target (the redirect moves
    -- the selection to the code window), and pin the panel window to its buffer.
    vim.b[buf].snacks_main = true
    if s and api.nvim_win_is_valid(s.panel_win) then
      vim.wo[s.panel_win].winfixbuf = true
    end
    -- A user's LspAttach handler (LazyVim, kickstart) maps `gd`, `K`, `]]`... buffer-locally on
    -- every client, overriding revuey's keys on this buffer. Put revuey's back afterwards.
    api.nvim_create_autocmd('LspAttach', {
      group = group,
      buffer = buf,
      callback = function(ev)
        local c = vim.lsp.get_client_by_id(ev.data.client_id)
        if not (c and c.name == M.NAME) then
          return
        end
        vim.schedule(function()
          vim.schedule(function() -- after handlers that schedule their own mappings too
            local ss = session_for(buf)
            if ss then
              require('revuey.view').diff_keymaps(ss)
            end
          end)
        end)
      end,
    })
    api.nvim_create_autocmd('BufWipeout', {
      group = group,
      buffer = buf,
      once = true,
      callback = function()
        M.detach(buf)
      end,
    })
  end)
end

function M.detach(buf)
  pcall(api.nvim_del_augroup_by_name, 'revuey_lsp_proxy_' .. buf)
  local id = clients[buf]
  clients[buf] = nil
  -- the tracked client, plus any started for this buffer since (`:lsp restart revuey`)
  for _, c in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    if c.id == id or c.attached_buffers[buf] or vim.tbl_isempty(c.attached_buffers) then
      c:stop(true)
    end
  end
end

---Stop proxy clients attached to no buffer, e.g. one that `:lsp restart revuey` started for a
---review closed in the meantime.
function M.sweep()
  for _, c in ipairs(vim.lsp.get_clients({ name = M.NAME })) do
    if vim.tbl_isempty(c.attached_buffers) then
      c:stop(true)
    end
  end
end

---Client id attached to a review buffer (tests, health).
function M.client_id(buf)
  return clients[buf]
end

return M
