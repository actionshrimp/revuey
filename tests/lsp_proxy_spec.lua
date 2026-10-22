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

-- A typical user LspAttach handler: buffer-local keymaps plus inlay hints, for every client.
local attached = {}
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    local ok, err = pcall(function()
      local o = { buffer = ev.buf }
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

h.test('a deleted line gives a clear message, not a hang', function()
  open(repo)
  put_cursor('src/use.ts', 'Math.hypot', 'del')
  local msgs, restore = h.capture_notify()
  vim.lsp.buf.definition()
  local m = wait_msg(msgs, 'deleted line')
  restore()
  h.eq(vim.log.levels.WARN, m.level)
  h.eq(s.diff_buf, vim.api.nvim_get_current_buf())
end)

h.test('no LSP for a filetype is a clear error; other files in the same buffer still route', function()
  open(repo)
  put_cursor('tools/tool.lua', 'answer', 'add')
  local msgs, restore = h.capture_notify()
  vim.lsp.buf.definition()
  wait_msg(msgs, 'no LSP attached for filetype "lua"')
  restore()
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
