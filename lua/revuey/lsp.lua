-- Projected LSP (ARCHITECTURE decision 3): requests are sent through a hidden buffer holding the real
-- working-tree file, so the user's own LSP configuration attaches as usual.
local config = require('revuey.config')
local linemap = require('revuey.linemap')

local M = {}

local first_seen = {} ---@type table<integer, integer> client id -> ms timestamp
local created = {} ---@type table<integer, true> hidden buffers loaded by revuey

local function mtime(buf)
  local st = vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf))
  return st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size) or nil
end

---Silently reload revuey's hidden buffers whose files changed on disk. Never uses :checktime
---(with 'noautoread' that raises the blocking W11 prompt for a buffer the user never opened),
---and never touches buffers the user has opened (listed), modified or is showing in a window.
function M.checktime()
  for buf, loaded_mtime in pairs(created) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and not vim.bo[buf].buflisted
      and not vim.bo[buf].modified
      and #vim.fn.win_findbuf(buf) == 0
    then
      local now = mtime(buf)
      if now and now ~= loaded_mtime then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd('silent! keepalt keepjumps edit')
        end)
        created[buf] = mtime(buf)
      end
    end
  end
end

---Wipe hidden buffers revuey loaded, unless the user has since opened, listed or modified them.
function M.cleanup()
  for buf in pairs(created) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and not vim.bo[buf].buflisted
      and not vim.bo[buf].modified
      and #vim.fn.win_findbuf(buf) == 0
    then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  created = {}
end

local function now()
  return vim.uv.now()
end

---Load the working-tree file into a (hidden) buffer and make sure filetype detection ran.
---@return integer? buf
function M.file_buffer(abs)
  if not vim.uv.fs_stat(abs) then
    return nil
  end
  local buf = vim.fn.bufadd(abs)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
    created[buf] = mtime(buf) or true
  end
  if vim.bo[buf].filetype == '' then
    local ft = vim.filetype.match({ buf = buf, filename = abs })
    if ft then
      vim.bo[buf].filetype = ft -- fires FileType, which is what vim.lsp.enable() hooks
    end
  end
  return buf
end

---Start LSP for a file without showing it (warm-up so the project is loaded before `gd`).
function M.warmup(abs)
  pcall(M.file_buffer, abs)
end

---Map a HEAD line (as shown in the diff) to the corresponding line of the working-tree buffer.
---With `head_text`, lines are mapped through a diff of HEAD vs the buffer, so duplicated text
---elsewhere can never be picked; the mapped line must also still have the same text.
---Without it, only an exact match at `lnum` is accepted. Returns nil when there is no
---counterpart (the line was edited or removed in the working tree).
---@return integer? lnum
function M.match_line(buf, lnum, text, head_text)
  local wl = lnum
  if head_text then
    local buf_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
    wl = linemap.new(head_text, buf_text)(lnum)
  end
  if not wl then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(buf, wl - 1, wl, false)[1]
  return line == text and wl or nil
end

---Wait (asynchronously) until the buffer has initialized clients supporting `method` that have
---been alive for `lsp_settle_ms`, then call `cb(clients)`.
local function with_clients(buf, method, cb, on_fail)
  local start = now()
  local deadline = start + 15000
  local notified = false
  local function fail(msg)
    if notified then
      vim.api.nvim_echo({ { '' } }, false, {})
    end
    on_fail('revuey: ' .. msg)
  end
  local function try()
    local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
    local any = vim.lsp.get_clients({ bufnr = buf })
    -- Fail fast: nothing attached shortly after loading means no LSP is configured for this
    -- filetype; attached-and-initialized clients that lack the method will never gain it.
    if #any == 0 and now() - start > 1500 then
      return fail('no LSP attached for filetype "' .. vim.bo[buf].filetype .. '"')
    end
    if #clients == 0 and #any > 0 then
      local all_init = true
      for _, c in ipairs(any) do
        all_init = all_init and c.initialized
      end
      if all_init and now() - start > 1500 then
        return fail('no attached LSP supports ' .. method)
      end
    end
    local ready = #clients > 0
    for _, c in ipairs(clients) do
      first_seen[c.id] = first_seen[c.id] or now()
      if not c.initialized or now() - first_seen[c.id] < config.options.lsp_settle_ms then
        ready = false
      end
    end
    if ready then
      if notified then
        vim.api.nvim_echo({ { '' } }, false, {})
      end
      return cb(clients)
    end
    if now() > deadline then
      if #clients > 0 then
        return cb(clients)
      end
      return fail('no LSP client supporting ' .. method .. ' attached for this file')
    end
    if not notified then
      notified = true
      vim.api.nvim_echo({ { 'revuey: waiting for LSP…', 'Comment' } }, false, {})
    end
    vim.defer_fn(try, 150)
  end
  try()
end

---Note the time clients first attach to warmed-up buffers.
vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('revuey_lsp', { clear = true }),
  callback = function(ev)
    local id = ev.data and ev.data.client_id
    if id then
      first_seen[id] = first_seen[id] or now()
    end
  end,
})

local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

---Send `method` at the target position to every client on the file's buffer that supports it.
---`cb` receives the first non-empty result (clients tried in id order), or nil.
---Failures before anything is sent (file missing, line not mapped, no client) go to
---`opts.on_fail(msg)` (default: a warning) and `cb` is not called.
---@param target {abs:string, lnum:integer, col:integer, text:string, head?:string}
---@param method string
---@param cb fun(err:any, result:any, client:vim.lsp.Client?, buf:integer, lnum:integer)
---@param is_empty? fun(result:any):boolean
---@param opts? {on_fail?: fun(msg: string), params?: table} params: extra request params (`context`)
function M.request(target, method, cb, is_empty, opts)
  opts = opts or {}
  local on_fail = opts.on_fail or warn
  is_empty = is_empty or function(r)
    return r == nil or (type(r) == 'table' and vim.tbl_isempty(r))
  end
  local buf = M.file_buffer(target.abs)
  if not buf then
    return on_fail('revuey: file not in working tree: ' .. target.abs)
  end
  local lnum = M.match_line(buf, target.lnum, target.text, target.head)
  if not lnum then
    return on_fail('revuey: line differs in the working tree (uncommitted edits?); LSP unavailable here')
  end
  with_clients(buf, method, function(clients)
    table.sort(clients, function(a, b)
      return a.id < b.id
    end)
    local pending = #clients
    local results = {}
    for i, client in ipairs(clients) do
      local character = vim.lsp.util.character_offset(buf, lnum - 1, target.col, client.offset_encoding)
      local params = vim.tbl_extend('force', opts.params or {}, {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = lnum - 1, character = character },
      })
      local ok = client:request(method, params, function(err, result)
        results[i] = { err = err, result = result, client = client }
        pending = pending - 1
        if pending == 0 then
          local first_err
          for j = 1, #clients do
            local r = results[j]
            if r and not r.err and not is_empty(r.result) then
              return cb(nil, r.result, r.client, buf, lnum)
            end
            first_err = first_err or (r and r.err)
          end
          cb(first_err, nil, nil, buf, lnum)
        end
      end, buf)
      if not ok then
        pending = pending - 1
        results[i] = { err = { message = 'request failed' }, client = client }
      end
    end
    if pending == 0 then
      cb({ message = 'no client accepted the request' }, nil, nil, buf, lnum)
    end
  end, on_fail)
end

---Normalise a definition result into a list of {uri, range}.
function M.locations(result)
  if not result then
    return {}
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  local out = {}
  for _, loc in ipairs(result) do
    out[#out + 1] = {
      uri = loc.uri or loc.targetUri,
      range = loc.range or loc.targetSelectionRange or loc.targetRange,
    }
  end
  return out
end

-- Review buffers (filetype "revuey") get the proxy client, so the user's own vim.lsp.buf.*
-- mappings work in them (see lsp_proxy.lua).
vim.api.nvim_create_autocmd('FileType', {
  group = 'revuey_lsp',
  pattern = 'revuey',
  callback = function(ev)
    if config.options.lsp_proxy ~= false then
      require('revuey.lsp_proxy').attach(ev.buf)
    end
  end,
})

return M
