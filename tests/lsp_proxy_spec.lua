-- Integration: the in-process proxy LSP client ("revuey") attached to review buffers, so the
-- user's own vim.lsp.buf.* mappings (and pickers built on LSP requests) work in the diff and the
-- guide. Lifecycle, capabilities, routing errors and LspAttach handlers are tested without any
-- language server; navigation runs against typescript-language-server (skipped when missing).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')

local have_ts = vim.fn.executable('typescript-language-server') == 1
if have_ts then
  vim.lsp.config('ts_ls', {
    cmd = { 'typescript-language-server', '--stdio' },
    filetypes = { 'typescript', 'typescriptreact' },
    root_markers = { 'tsconfig.json' },
  })
  vim.lsp.enable('ts_ls')
end
local function need_ts()
  if not have_ts then
    h.skip('typescript-language-server not on PATH')
  end
end

-- (no headless grid resize here: with ts_ls warm-up and a reopened review, Neovim 0.12.4
-- headless has been seen to segfault after `vim.o.lines = 50`, independent of the proxy)

-- A typical user LspAttach handler: buffer-local keymaps (including LazyVim/kickstart-style
-- `gd`, `K` and `]]`, which collide with revuey's) plus inlay hints, for every client.
local attached = {}
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    local ok, err = pcall(function()
      local o = { buffer = ev.buf }
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = ev.buf, desc = 'user gd' })
      vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = ev.buf, desc = 'user K' })
      vim.keymap.set('n', ']]', '<Nop>', { buffer = ev.buf, desc = 'user ]]' })
      vim.keymap.set('n', 'mgg', function()
        vim.lsp.buf.definition()
      end, o)
      vim.keymap.set('n', 'mgt', function()
        vim.lsp.buf.type_definition()
      end, o)
      vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
    end)
    attached[#attached + 1] = { name = client.name, buf = ev.buf, ok = ok, err = err }
  end,
})

local state_dir = h.tmpdir('proxy-state')
require('revuey').setup({ state_dir = state_dir })
local view = require('revuey.view')

local repo = h.repo('proxy-repo', {
  ['tsconfig.json'] = '{ "compilerOptions": { "strict": true, "noEmit": true }, "include": ["src"] }\n',
  ['src/types.ts'] = '/** A point in 2D. */\nexport interface Point {\n  x: number;\n  y: number;\n}\n',
  ['src/use.ts'] = table.concat({
    'import { Point } from "./types";',
    '',
    'export const origin: Point = { x: 0, y: 0 };',
    '',
    'export function norm(p: Point): number {',
    '  return Math.hypot(p.x, p.y);',
    '}',
    '',
  }, '\n'),
  ['tools/tool.lua'] = 'local M = {}\nreturn M\n',
}, {
  ['src/use.ts'] = table.concat({
    'import { Point } from "./types";',
    '',
    'export const origin: Point = { x: 0, y: 0 };',
    '',
    'export function norm(p: Point): number {',
    '  return Math.sqrt(p.x * p.x + p.y * p.y);',
    '}',
    '',
    'export const unit: Point = { x: 1, y: 0 };',
    'export const len = norm(unit);',
    '',
  }, '\n'),
  ['tools/tool.lua'] = 'local M = {}\nM.answer = 42\nreturn M\n',
})

local s

local function proxies()
  return vim.lsp.get_clients({ name = 'revuey' })
end

local function open(dir, opts)
  if view.session then
    view.close()
  end
  s = h.open_review(vim.tbl_extend('force', { cwd = dir, base = 'main' }, opts or {}))
  assert(vim.wait(5000, function()
    local c = vim.lsp.get_clients({ name = 'revuey', bufnr = s.diff_buf })[1]
    return c and c.initialized
  end, 10), 'proxy client did not attach')
  return s
end

local function row_of(path, needle, kind)
  for row, e in ipairs(s.layout.map) do
    local f = s.review.files[e.file_idx or 0]
    if f and f.path == path and (not kind or e.kind == kind) then
      local col = s.layout.lines[row]:find(needle, 1, true)
      if col then
        return row, col - 1
      end
    end
  end
  error('not found: ' .. needle)
end

local function put_cursor(path, needle, kind)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of(path, needle, kind) })
end

---Wait until the current window shows `suffix` and return its buffer line.
local function wait_jump(suffix)
  local ok = vim.wait(25000, function()
    return vim.api.nvim_buf_get_name(0):sub(-#suffix) == suffix
  end, 20)
  h.ok(ok, 'did not jump to ' .. suffix .. ' (at ' .. vim.api.nvim_buf_get_name(0) .. ')')
  return vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[1]
end

---The review is intact after a jump: the diff buffer is still in the diff window and the jump
---target opened in the code window below it.
local function review_intact()
  h.eq(s, view.session)
  h.eq(s.diff_buf, vim.api.nvim_win_get_buf(s.diff_win))
  h.eq(s.code_win, vim.api.nvim_get_current_win())
end

local function wait_msg(msgs, needle)
  vim.wait(10000, function()
    for _, m in ipairs(msgs) do
      if m.msg:find(needle, 1, true) then
        return true
      end
    end
  end, 20)
  for _, m in ipairs(msgs) do
    if m.msg:find(needle, 1, true) then
      return m
    end
  end
  error('no message containing "' .. needle .. '": ' .. vim.inspect(msgs))
end

h.test('a "revuey" client with navigation-only capabilities is attached to the review buffer', function()
  open(repo)
  local c = proxies()[1]
  h.eq(1, #proxies())
  h.eq({ s.diff_buf }, vim.tbl_keys(c.attached_buffers))
  local caps = c.server_capabilities
  for _, k in ipairs({ 'definitionProvider', 'typeDefinitionProvider', 'declarationProvider', 'implementationProvider',
    'referencesProvider', 'hoverProvider' }) do
    h.eq(true, caps[k], k)
  end
  for _, k in ipairs({ 'completionProvider', 'semanticTokensProvider', 'inlayHintProvider', 'documentFormattingProvider',
    'codeActionProvider', 'diagnosticProvider', 'renameProvider', 'documentHighlightProvider', 'signatureHelpProvider' }) do
    h.eq(nil, caps[k], k)
  end
  h.eq(0, #vim.lsp.get_clients({ bufnr = s.panel_buf }), 'the file panel gets no client')
  -- the user's LspAttach handler ran for the proxy without errors and its keymaps are there
  local mine = vim.tbl_filter(function(a)
    return a.name == 'revuey'
  end, attached)
  h.eq(1, #mine)
  h.eq(true, mine[1].ok, tostring(mine[1].err))
  h.eq(s.diff_buf, mine[1].buf)
  h.ok(vim.fn.maparg('mgg', 'n', false, true).buffer == 1, 'buffer-local mgg mapped')
  h.ok(vim.lsp.inlay_hint.is_enabled({ bufnr = s.diff_buf }))
  h.eq('', vim.v.errmsg)
end)

h.test("revuey's own keys win over keys a user LspAttach handler maps on the proxy", function()
  open(repo)
  vim.api.nvim_set_current_win(s.diff_win)
  h.ok(vim.wait(1000, function()
    return (vim.fn.maparg('gd', 'n', false, true).desc or ''):find('^revuey') ~= nil
  end, 10), 'gd: ' .. tostring(vim.fn.maparg('gd', 'n', false, true).desc))
  h.ok((vim.fn.maparg('K', 'n', false, true).desc or ''):find('^revuey'), vim.fn.maparg('K', 'n', false, true).desc)
  h.ok((vim.fn.maparg(']]', 'n', false, true).desc or ''):find('^revuey'), vim.fn.maparg(']]', 'n', false, true).desc)
  -- the user's other mappings stay
  h.eq(1, vim.fn.maparg('mgg', 'n', false, true).buffer)
end)

h.test('picker targets: snacks picks the diff window (then redirected), never the file panel', function()
  open(repo)
  -- snacks.picker's main-window finder skips non-file buffers unless flagged
  h.eq(true, vim.b[s.diff_buf].snacks_main)
  -- any picker that would open a file in the panel window gets an error instead of wiping it
  h.eq(true, vim.wo[s.panel_win].winfixbuf)
end)

h.test('buffers with bufhidden=wipe/delete/unload survive the redirect', function()
  open(repo)
  for _, bh in ipairs({ 'wipe', 'delete', 'unload' }) do
    vim.v.errmsg = ''
    vim.api.nvim_set_current_win(s.diff_win)
    -- like fugitive object buffers or a dashboard opened in the current window
    vim.cmd('enew')
    local nb = vim.api.nvim_get_current_buf()
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = bh
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'scratch ' .. bh })
    h.ok(vim.wait(2000, function()
      return vim.api.nvim_win_get_buf(s.diff_win) == s.diff_buf
    end, 10), 'review put back (' .. bh .. ')')
    h.ok(vim.api.nvim_buf_is_valid(nb), bh .. ': buffer still exists')
    h.eq(nb, vim.api.nvim_win_get_buf(s.code_win), bh .. ': shown in the code window')
    h.eq({ 'scratch ' .. bh }, vim.api.nvim_buf_get_lines(nb, 0, -1, false))
    review_intact()
    h.eq('', vim.v.errmsg, bh)
  end
end)

h.test('redirect target: a winfixbuf code window, or no room for a split', function()
  open(repo)
  local proxy = require('revuey.lsp_proxy')
  vim.api.nvim_set_current_win(s.diff_win)
  vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/src/types.ts'))
  assert(vim.wait(2000, function()
    return vim.api.nvim_win_get_buf(s.diff_win) == s.diff_buf
  end, 10))
  local first = s.code_win
  vim.wo[first].winfixbuf = true
  vim.api.nvim_set_current_win(s.diff_win)
  vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/src/use.ts'))
  h.ok(vim.wait(2000, function()
    return vim.api.nvim_win_get_buf(s.diff_win) == s.diff_buf
  end, 10), 'review put back')
  h.ok(s.code_win ~= first, 'a new code window, since the old one is winfixbuf')
  h.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(s.code_win)):match('src/use%.ts$'))
  h.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first)):match('src/types%.ts$'), 'fixed window untouched')
  review_intact()
  -- E36: no room for a split -> the buffer opens in a new tab and the review stays
  vim.api.nvim_win_close(first, true)
  vim.api.nvim_win_close(s.code_win, true)
  local orig = proxy.split_below
  proxy.split_below = function()
    error('Vim:E36: Not enough room')
  end
  local tabs = #vim.api.nvim_list_tabpages()
  vim.api.nvim_set_current_win(s.diff_win)
  vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/src/types.ts'))
  local ok = vim.wait(2000, function()
    return vim.api.nvim_win_get_buf(s.diff_win) == s.diff_buf
  end, 10)
  proxy.split_below = orig
  h.ok(ok, 'review put back without a split')
  h.eq(tabs + 1, #vim.api.nvim_list_tabpages())
  h.ok(vim.api.nvim_buf_get_name(0):match('src/types%.ts$'), 'the buffer is in the new tab')
  h.eq(s, view.session)
  vim.cmd('tabclose')
end)

h.test('jumplist and tagstack of the code window never lead back to the review', function()
  open(repo)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(s.diff_win, { 3, 0 })
  vim.cmd("normal! m'")
  vim.fn.settagstack(s.diff_win, { items = { { tagname = 'x', from = { s.diff_buf, 2, 1, 0 } } } }, 't')
  vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/src/types.ts'))
  assert(vim.wait(2000, function()
    return vim.api.nvim_win_get_buf(s.diff_win) == s.diff_buf
  end, 10))
  h.eq(s.code_win, vim.api.nvim_get_current_win())
  -- a code window made by the redirect starts with no history
  for _, j in ipairs(vim.fn.getjumplist(s.code_win)[1]) do
    h.ok(j.bufnr ~= s.diff_buf, 'jumplist entry for the review buffer')
  end
  h.eq(0, #vim.fn.gettagstack(s.code_win).items)
  -- a code window opened by revuey itself (go) records the review in its jumplist; <C-o> there
  -- goes back to the review window instead of showing the review a second time
  view.close()
  open(repo)
  local row = row_of('src/use.ts', 'unit: Point', 'add')
  put_cursor('src/use.ts', 'unit: Point', 'add')
  view.open_file()
  local code = s.code_win
  h.eq(code, vim.api.nvim_get_current_win())
  local file = vim.api.nvim_get_current_buf()
  vim.cmd('normal! \15') -- <C-o>
  h.ok(vim.wait(1000, function()
    return vim.api.nvim_get_current_win() == s.diff_win
  end, 10), 'back in the diff window')
  h.eq(file, vim.api.nvim_win_get_buf(code), 'the code window keeps its file')
  h.eq(s.diff_buf, vim.api.nvim_win_get_buf(s.diff_win))
  h.eq(1, #vim.fn.win_findbuf(s.diff_buf), 'the review is shown once')
  h.eq(row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  h.eq(s, view.session)
end)

h.test('a cancelled request never calls back and cancels the forwarded request', function()
  open(repo)
  local proxy = vim.lsp.get_clients({ name = 'revuey', bufnr = s.diff_buf })[1]
  -- no LSP for lua: the readiness wait (1.5s) is still running when we cancel
  put_cursor('tools/tool.lua', 'answer', 'add')
  local params = vim.lsp.util.make_position_params(s.diff_win, proxy.offset_encoding)
  local msgs, restore = h.capture_notify()
  local fired = false
  local _, id = proxy:request('textDocument/definition', params, function()
    fired = true
  end, s.diff_buf)
  proxy:cancel_request(id)
  vim.wait(2500)
  restore()
  h.eq(false, fired, 'handler called after cancel')
  h.eq({}, msgs, 'no message for a cancelled request')
  h.ok(vim.wait(1000, function()
    return next(proxy.requests) == nil
  end, 10), 'request still pending: ' .. vim.inspect(proxy.requests))
  need_ts()
  -- a request already sent to ts_ls is cancelled there too
  put_cursor('src/use.ts', 'norm(unit', 'add')
  vim.lsp.buf.hover() -- warm up: wait until ts_ls answers once
  assert(vim.wait(25000, function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        vim.api.nvim_win_close(w, true)
        return true
      end
    end
  end, 20), 'hover')
  local ts = vim.lsp.get_clients({ name = 'ts_ls' })[1]
  local sent, cancelled = {}, {}
  local orig_request, orig_cancel = ts.request, ts.cancel_request
  ts.request = function(self, method, ...)
    local ok, rid = orig_request(self, method, ...)
    if method == 'textDocument/hover' then
      sent[#sent + 1] = rid
    end
    return ok, rid
  end
  ts.cancel_request = function(self, rid)
    cancelled[#cancelled + 1] = rid
    return orig_cancel(self, rid)
  end
  vim.api.nvim_set_current_win(s.diff_win)
  params = vim.lsp.util.make_position_params(s.diff_win, proxy.offset_encoding)
  fired = false
  _, id = proxy:request('textDocument/hover', params, function()
    fired = true
  end, s.diff_buf)
  assert(vim.wait(5000, function()
    return #sent > 0
  end, 1), 'forwarded')
  proxy:cancel_request(id)
  vim.wait(1000)
  ts.request, ts.cancel_request = orig_request, orig_cancel
  h.eq(false, fired)
  h.eq(sent, cancelled)
end)

h.test(':lsp restart of the proxy does not leak a client', function()
  open(repo)
  local old = proxies()[1].id
  vim.cmd('lsp restart revuey')
  h.ok(vim.wait(3000, function()
    local c = vim.lsp.get_clients({ name = 'revuey', bufnr = s.diff_buf })[1]
    return c and c.id ~= old and c.initialized and #proxies() == 1
  end, 10), 'restarted')
  view.close()
  h.ok(vim.wait(3000, function()
    return #proxies() == 0
  end, 10), 'leaked after restart + close')
  -- restart and close at once: the new client starts for a buffer that is already gone
  open(repo)
  vim.cmd('lsp restart revuey')
  view.close()
  h.ok(vim.wait(4000, function()
    return #proxies() == 0
  end, 10), 'leaked after restart racing close')
end)

h.test('a buffer opened in the diff window (any jump) moves to the code window; the review stays', function()
  open(repo)
  vim.api.nvim_set_current_win(s.diff_win)
  local tool_row = row_of('tools/tool.lua', 'tool.lua', nil)
  vim.cmd(tool_row .. 'foldclose')
  h.eq(tool_row, vim.fn.foldclosed(tool_row))
  local row = row_of('src/use.ts', 'unit: Point', 'add')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/src/types.ts')) -- what a jump handler does
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  h.ok(vim.wait(2000, function()
    return vim.api.nvim_win_get_buf(s.diff_win) == s.diff_buf
  end, 10), 'review put back')
  h.ok(vim.api.nvim_buf_get_name(0):match('src/types%.ts$'), vim.api.nvim_buf_get_name(0))
  h.eq({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
  review_intact()
  h.eq(row, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'diff cursor kept')
  vim.api.nvim_win_call(s.diff_win, function()
    h.eq(tool_row, vim.fn.foldclosed(tool_row), 'closed fold kept')
  end)
  h.eq(1, #vim.lsp.get_clients({ name = 'revuey', bufnr = s.diff_buf }), 'still attached')
end)

h.test('results from a server with another position encoding are converted', function()
  local proxy = require('revuey.lsp_proxy')
  local d = h.tmpdir('enc')
  h.write(d, 'f.ts', 'const é = "ü"; x\n')
  local uri = vim.uri_from_fname(d .. '/f.ts')
  -- `x` is at byte 17, UTF-16 index 15 (é and ü are two bytes, one UTF-16 unit each)
  local loc = { uri = uri, range = { start = { line = 0, character = 17 }, ['end'] = { line = 0, character = 18 } } }
  local link = { targetUri = uri, originSelectionRange = loc.range, targetRange = vim.deepcopy(loc.range),
    targetSelectionRange = vim.deepcopy(loc.range) }
  proxy.convert_locations({ loc, link }, 'utf-8')
  h.eq({ 15, 16 }, { loc.range.start.character, loc.range['end'].character })
  h.eq(15, link.targetSelectionRange.start.character)
  h.eq(nil, link.originSelectionRange, 'origin range (hidden buffer) dropped')
  -- same encoding: untouched
  local same = { uri = uri, range = { start = { line = 0, character = 16 }, ['end'] = { line = 0, character = 17 } } }
  proxy.convert_locations(same, 'utf-16')
  h.eq(16, same.range.start.character)
end)

h.test('a deleted line gives one clear message, not a hang or an error', function()
  open(repo)
  put_cursor('src/use.ts', 'Math.hypot', 'del')
  for _, fn in ipairs({ vim.lsp.buf.definition, vim.lsp.buf.references, vim.lsp.buf.hover }) do
    local msgs, restore = h.capture_notify()
    fn()
    local m = wait_msg(msgs, 'deleted line')
    vim.wait(300)
    restore()
    h.eq(vim.log.levels.WARN, m.level)
    h.eq(1, #msgs, vim.inspect(msgs)) -- no "No locations found" / "No information available"
    h.eq(s.diff_buf, vim.api.nvim_get_current_buf())
  end
  -- the reply is an empty result, not an error (hover would log it)
  local proxy = vim.lsp.get_clients({ name = 'revuey', bufnr = s.diff_buf })[1]
  local _, restore = h.capture_notify()
  local got
  proxy:request('textDocument/hover', vim.lsp.util.make_position_params(s.diff_win, proxy.offset_encoding), function(err, res)
    got = { err = err, res = res }
  end, s.diff_buf)
  vim.wait(1000, function()
    return got ~= nil
  end, 10)
  restore()
  h.eq({ err = nil, res = nil }, got)
end)

h.test('no LSP for a filetype is a clear error; other files in the same buffer still route', function()
  open(repo)
  put_cursor('tools/tool.lua', 'answer', 'add')
  local msgs, restore = h.capture_notify()
  vim.lsp.buf.definition()
  wait_msg(msgs, 'no LSP attached for filetype "lua"')
  vim.wait(300)
  restore()
  h.eq(1, #msgs, vim.inspect(msgs))
  h.eq(s.diff_buf, vim.api.nvim_get_current_buf())
  need_ts()
  -- a TypeScript row of the same composed buffer goes to ts_ls
  put_cursor('src/use.ts', 'norm(unit', 'add')
  vim.lsp.buf.definition()
  local line, lnum = wait_jump('src/use.ts')
  h.ok(line:find('export function norm', 1, true), line)
  h.eq(5, lnum)
  review_intact()
end)

h.test('definition and type definition from a context line (user mappings mgg / mgt)', function()
  need_ts()
  open(repo)
  put_cursor('src/use.ts', 'Point = { x: 0', 'ctx')
  vim.cmd('normal mgg')
  local line, lnum = wait_jump('src/types.ts')
  h.ok(line:find('export interface Point', 1, true), line)
  h.eq(2, lnum)
  review_intact()
  put_cursor('src/use.ts', 'origin', 'ctx')
  vim.cmd('normal mgt')
  vim.wait(200)
  line, lnum = wait_jump('src/types.ts')
  h.eq(2, lnum)
  h.ok(line:find('export interface Point', 1, true), line)
  review_intact()
end)

h.test('definition and type definition from an added line', function()
  need_ts()
  open(repo)
  put_cursor('src/use.ts', 'unit: Point', 'add')
  vim.lsp.buf.type_definition()
  local line, lnum = wait_jump('src/types.ts')
  h.eq(2, lnum)
  h.ok(line:find('export interface Point', 1, true), line)
  review_intact()
  put_cursor('src/use.ts', 'Point = { x: 1', 'add')
  vim.lsp.buf.definition()
  vim.wait(200)
  line, lnum = wait_jump('src/types.ts')
  h.eq(2, lnum)
  review_intact()
end)

h.test('references return real locations', function()
  need_ts()
  open(repo)
  vim.fn.setqflist({}, 'r', { title = 'none', items = {} })
  put_cursor('src/use.ts', 'norm(p', 'ctx')
  vim.lsp.buf.references({ includeDeclaration = true })
  h.ok(vim.wait(25000, function()
    return #vim.fn.getqflist() > 0
  end, 20), 'references found')
  local got = {}
  for _, it in ipairs(vim.fn.getqflist()) do
    got[#got + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(it.bufnr), ':t') .. ':' .. it.lnum
  end
  table.sort(got)
  h.eq({ 'use.ts:10', 'use.ts:5' }, got)
  vim.cmd('cclose')
end)

h.test('hover through the proxy', function()
  need_ts()
  open(repo)
  put_cursor('src/use.ts', 'norm(unit', 'add')
  vim.lsp.buf.hover()
  local float
  vim.wait(25000, function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        float = w
        return true
      end
    end
  end, 20)
  h.ok(float, 'hover float opened')
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), '\n')
  h.ok(text:find('function norm', 1, true), text)
  vim.api.nvim_win_close(float, true)
end)

h.test('the guide view works through the proxy too', function()
  need_ts()
  local d = h.tmpdir('proxy-guide-fixture')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', d }):wait().code == 0)
  open(d)
  h.use_fake_claude(h.tmpdir('proxy-fake-claude') .. '/calls.ndjson')
  local _, restore = h.capture_notify()
  view.guide_command(true)
  assert(vim.wait(20000, function()
    return next(require('revuey.guide_view').jobs) == nil and s.guide.resolved ~= nil
  end, 20), 'guide generated')
  restore()
  h.eq('guide', s.layout.kind)
  put_cursor('src/cart.ts', 'sum(this')
  vim.lsp.buf.definition()
  local line = wait_jump('src/math.ts')
  h.ok(line:find('export function sum', 1, true), line)
  review_intact()
  h.eq('guide', s.view_mode)
end)

h.test('closing the review stops the proxy; reopening starts exactly one', function()
  open(repo)
  h.eq(1, #proxies())
  view.close()
  h.ok(vim.wait(5000, function()
    return #proxies() == 0
  end, 10), 'proxy stopped after close')
  open(repo)
  h.eq(1, #proxies())
  open(repo) -- opening over an open review replaces it
  h.ok(vim.wait(5000, function()
    return #proxies() == 1
  end, 10), 'one proxy after reopen')
  vim.cmd('tabclose') -- closing the tab without :RevueyClose also cleans up
  h.ok(vim.wait(5000, function()
    return #proxies() == 0 and view.session == nil
  end, 10), 'proxy stopped after :tabclose')
  h.eq('', vim.v.errmsg)
  -- the user's LspAttach handler never failed, for the proxy or the real servers
  h.ok(#attached > 0)
  for _, a in ipairs(attached) do
    h.eq(true, a.ok, a.name .. ': ' .. tostring(a.err))
  end
end)

h.run()
