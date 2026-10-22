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

---Answer one request on a review buffer. `reply(err, result)` is always called exactly once.
function M.handle(method, params, reply)
  local function fail(msg)
    vim.notify(msg, vim.log.levels.WARN)
    reply({ code = REQUEST_FAILED, message = msg })
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
  lsp.request(target, method, function(err, result, client, _, lnum)
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
local function new_server(dispatchers)
  local closing = false
  local next_id = 0
  local function exit()
    if not closing then
      closing = true
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
    local function reply(err, result)
      vim.schedule(function()
        if notify_reply_callback then
          notify_reply_callback(id)
        end
        callback(err, result, id)
      end)
    end
    if method == 'initialize' then
      reply(nil, { capabilities = M.capabilities, serverInfo = { name = M.NAME } })
    elseif method == 'shutdown' then
      reply(nil, nil)
    elseif METHODS[method] then
      local ok, e = pcall(M.handle, method, params, reply)
      if not ok then
        reply({ code = REQUEST_FAILED, message = 'revuey: ' .. tostring(e) })
      end
    else
      reply({ code = METHOD_NOT_FOUND, message = 'revuey: unsupported method ' .. method })
    end
    return true, id
  end
  function srv.notify(method)
    if method == 'exit' then
      exit()
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

---Another buffer replaced the review in the diff window (a jump from vim.lsp.buf.definition, a
---picker or the quickfix list): put the review back and show that buffer in the code window.
local function put_back(s, buf, saved)
  local win = s.diff_win
  local other = api.nvim_win_get_buf(win)
  local cursor = api.nvim_win_get_cursor(win)
  local focus = api.nvim_get_current_win() == win
  api.nvim_win_set_buf(win, buf)
  if saved then
    api.nvim_win_call(win, function()
      vim.cmd('silent! %foldopen!')
      for _, row in ipairs(saved.folds) do
        vim.cmd('silent! ' .. row .. 'foldclose')
      end
      vim.fn.winrestview(saved.view)
    end)
  end
  local code = require('revuey.view').code_window(s)
  api.nvim_win_set_buf(code, other)
  pcall(api.nvim_win_set_cursor, code, cursor)
  if focus then
    api.nvim_set_current_win(code)
  end
  api.nvim_win_call(code, function()
    vim.cmd('normal! zvzz')
  end)
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
          put_back(s, buf, saved)
        else
          -- the review window is gone: what bufhidden=wipe did before (cleans up the session)
          pcall(api.nvim_buf_delete, buf, { force = true })
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
  local c = id and vim.lsp.get_client_by_id(id)
  if c then
    c:stop(true)
  end
end

---Client id attached to a review buffer (tests, health).
function M.client_id(buf)
  return clients[buf]
end

return M
