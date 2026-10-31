-- The stack tree in a review (stack_tree_view.lua, with forge_view, view and panel): a real
-- clone of a branching stack (tests/helpers.lua tree_repo) with the fake `gh` answering the tree
-- and `git fetch` reaching a local bare "GitHub" (tests/bin/fake-ssh). The tree comes with the PR
-- lookup in batched rounds; the stack is the default route; the panel marks other paths and
-- branches to fetch; the tree view moves, lights the path up, shows closed PRs, selects a path
-- and cancels; full scope and ]s/[s follow the chosen path; the fetch key; git detection when
-- GitHub fails.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('tree-state')
local log_file = h.tmpdir('tree-log') .. '/revuey.log'
local function setup(extra)
  require('revuey').setup(vim.tbl_deep_extend('force', {
    state_dir = state_dir, lsp_warmup = false, log_file = log_file, panel_width = 30,
    forge = { threads = { enabled = false }, check = false, description = { enabled = false } },
  }, extra or {}))
end
setup()
local view = require('revuey.view')
local tv = require('revuey.stack_tree_view')
local api = vim.api

-- Error-level messages nobody expected fail the test they happen in: shown or captured
-- (h.capture_notify passes them to h.on_error), whether from revuey or an error in a task.
local errors = {}
h.on_error = function(msg)
  errors[#errors + 1] = msg
end
do
  local real = vim.notify
  vim.notify = function(msg, level, ...)
    if level and level >= vim.log.levels.ERROR then
      errors[#errors + 1] = msg
    end
    return real(msg, level, ...)
  end
end
---h.test, failing on error notifications unless `allow(msg)` accepts each one.
local function test(name, fn, allow)
  h.test(name, function()
    errors = {}
    fn()
    vim.wait(100, function()
      return false
    end)
    local bad = vim.tbl_filter(function(m)
      return not (allow and allow(m))
    end, errors)
    h.eq({}, bad, 'unexpected error notifications')
  end)
end

local function names(s)
  return vim.tbl_map(function(l)
    return l.name
  end, s.review.stack and s.review.stack.layers or {})
end

---Open a review of a fresh tree_repo and wait for the tree and the stack built from it.
local function open(name, scenario, o)
  o = o or {}
  local r = h.tree_repo(name)
  if o.prepare then
    o.prepare(r) -- the clone or the PRs changed before the review opens
  end
  local calls = h.tmpdir(name .. '-gh') .. '/calls.ndjson'
  h.use_fake_gh(calls, r.prs, scenario, o.threads)
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = o.tree_scenario
  local ssh_log = h.tmpdir(name .. '-ssh') .. '/ssh.log'
  h.use_fake_ssh(r.bare, ssh_log)
  local s = h.open_review({ cwd = r.dir, base = '' })
  if o.until_ then
    h.ok(vim.wait(15000, function()
      return o.until_(s)
    end, 10), 'the review did not get there')
    return s, r, calls, ssh_log
  end
  h.ok(vim.wait(15000, function()
    local gt = s.gh_tree
    return (not tv.enabled() or (gt and gt.fetched and not gt.running and (gt.reason or (gt.tree and not gt.loading))))
      and s.forge and not s.forge.busy and not s.refreshing
  end, 20), 'the tree did not load')
  vim.wait(200, function()
    return false
  end)
  h.ok(vim.wait(5000, function()
    return not s.refreshing and not (s.forge and s.forge.busy)
  end, 20))
  return s, r, calls, ssh_log
end

local function tree_calls(calls)
  local out = {}
  for _, c in ipairs(h.read_calls(calls)) do
    local q = c.argv[5] or ''
    if q:find('fragment tnode', 1, true) then
      out[#out + 1] = q
    end
  end
  return out
end

local function wait_idle(s)
  return vim.wait(10000, function()
    return not s.refreshing and not s.pending and not (s.forge and s.forge.busy)
      and not (s.gh_tree and (s.gh_tree.fetching or s.gh_tree.running))
  end, 20)
end

test('open: the tree comes with the PR lookup, in batched rounds; the stack is the default route', function()
  local s, _, calls = open('tree-open')
  local all = h.read_calls(calls)
  local first = all[1].argv[5]
  h.ok(first:find('l1:', 1, true) and first:find('sd1:', 1, true), 'the first round rides on the PR lookup')
  local tq = tree_calls(calls)
  -- 1 shared + children of the chain (11, 12), then 13, then 15 (routes), then the closed 16
  -- and 14, then 17; plus the lookup of the new layers' PRs once the stack changed
  h.eq(6, #tq)
  for i = 2, #tq do
    h.ok(not tq[i]:find('fragment pr on', 1, true), 'tree rounds of their own')
    h.ok(not tq[i]:find('sd1:', 1, true), 'the chain came in the first call')
  end
  h.eq(#tq + 1, #all, 'one more PR lookup for the layers the tree added')
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq('github', s.review.stack.kind)
  h.eq({ kind = 'layer', index = 2 }, s.scope, 'HEAD\'s layer')
  local l = s.review.stack.layers
  h.eq({ 11, 12, 13 }, { l[1].pr, l[2].pr, l[3].pr })
  h.eq(true, l[2].is_head)
  h.eq('behind', l[3].fetch)
  h.eq(true, l[1].remote)
  local kinds = vim.tbl_map(function(n)
    return n.kind
  end, s.review.stack.notes)
  h.ok(vim.tbl_contains(kinds, 'not_fetched'), 'PR #15 is not in the clone')
  view.close()
end)

test('panel: other paths (⑂), branches to fetch (⇣), the hints under a layer, the help line', function()
  local s = open('tree-panel')
  local lines = api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local virt = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(s.panel_buf, -1, 0, -1, { details = true })) do
    if m[4].virt_text then
      local t = {}
      for _, v in ipairs(m[4].virt_text) do
        t[#t + 1] = v[1]
      end
      virt[m[2] + 1] = table.concat(t)
    end
  end
  local row = {}
  for r, i in pairs(s.panel_layers) do
    if i ~= 'full' then
      row[({ 'stack/a', 'stack/b', 'stack/c' })[i]] = r
    end
  end
  h.ok(virt[row['stack/a']]:find('^⑂2 ro #11'), virt[row['stack/a']])
  h.ok(virt[row['stack/b']]:find('^⑂2 #12'), virt[row['stack/b']])
  h.ok(virt[row['stack/c']]:find('^⇣ ro #13'), virt[row['stack/c']])
  h.ok(vim.tbl_contains(lines, ' gb stack tree  gF fetch'), 'help line')
  h.ok(vim.iter(lines):any(function(x)
    return x:find('⚠ PR #15 not fetched:', 1, true) ~= nil
  end), table.concat(lines, '\n'))
  local function hints_at(r)
    api.nvim_set_current_win(s.panel_win)
    api.nvim_win_set_cursor(s.panel_win, { r, 0 })
    require('revuey.panel').update_hint(s)
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(s.panel_buf, -1, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        out[#out + 1] = vim.trim(vl[1][1])
      end
    end
    return out
  end
  h.eq({ 'gS creates local branch stack/a', 'gb tree: 2 closed PRs here' }, hints_at(row['stack/a']))
  h.eq({ 'gb tree: 2 other paths here' }, hints_at(row['stack/b']))
  h.eq({ 'gS creates local branch stack/c', 'gF fetch: origin is behind GitHub' }, hints_at(row['stack/c']))
  view.close()
end)

---The tree view's PR rows (number -> row) and the PR under the cursor.
local function tree_rows(s)
  local v = s.gh_tree.view
  local rows = {}
  for r, n in pairs(v.row_pr) do
    rows[n] = r
  end
  return rows, v
end

---The PRs whose glyph is lit (the path under consideration), sorted; and per graph line the
---lit characters (`hl` marks them `^`).
local function lit(s)
  local v = s.gh_tree.view
  local nodes, marks = {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(v.buf, -1, 0, -1, { details = true })) do
    if m[4].hl_group == 'RevueyTreePath' then
      local row = m[2] + 1
      local inf = v.info[row]
      if inf and inf.glyph == m[3] and inf.node then
        nodes[#nodes + 1] = inf.node
      end
      marks[row] = marks[row] or {}
      marks[row][#marks[row] + 1] = { m[3], m[4].end_col }
    end
  end
  table.sort(nodes)
  return nodes, marks
end

---Graph line `row` with its lit characters shown as `^`, the rest as `.` (graph part only).
local function lit_line(s, row)
  local v = s.gh_tree.view
  local _, marks = lit(s)
  local line = api.nvim_buf_get_lines(v.buf, row - 1, row, false)[1]
  local g = line:match('^([│├─╯●○ ]*)')
  local out = {}
  local i = 0
  for ch in g:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local on = false
    for _, r in ipairs(marks[row] or {}) do
      on = on or (i >= r[1] and i < r[2])
    end
    out[#out + 1] = ch == ' ' and ' ' or (on and '^' or '.')
    i = i + #ch
  end
  return (table.concat(out):gsub('%s+$', ''))
end

local function footer(s)
  local v = s.gh_tree.view
  -- the clone's facts (fetch marks: `⇣` on PRs not here) come a moment after the view opens
  vim.wait(5000, function()
    return v.facts ~= nil
  end, 10)
  require('revuey.stack_tree_view').render_footer(s)
  return api.nvim_buf_get_lines(v.fbuf, 0, -1, false)
end

local function at(s)
  return require('revuey.stack_tree_view').cursor_pr(s)
end

test('tree view: the graph, j/k/h/l, the path lit whole, the footer, closed shown and hidden, q cancels', function()
  local s = open('tree-view')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  local v = s.gh_tree.view
  h.ok(v and api.nvim_win_is_valid(v.win), 'the tree view opened')
  h.eq(v.win, api.nvim_get_current_win())
  h.eq('win', api.nvim_win_get_config(v.win).relative, 'a float over the diff window')
  local lines = api.nvim_buf_get_lines(v.buf, 0, -1, false)
  h.eq(' Stack tree · 9 PRs on main', lines[1])
  local graph = {}
  for i = 2, #lines do
    graph[#graph + 1] = (lines[i]:match('^([│├─╯●○ ]*#?%d*)') or ''):gsub('%s+$', '')
  end
  h.eq({ '● #15', '● #13', '│ ○ #19', '├─╯', '● #12', '● #11', '●' }, graph)
  h.ok(lines[#lines]:find('● main', 1, true))
  h.eq(' path: main › #11 › #12 › #13 › #15⇣', footer(s)[1])
  -- the keys, in as many words as the window has room for (a narrow one here)
  h.eq(' j k h l move  <CR> review  C closed  gF fetch  q', footer(s)[2])
  local rows = tree_rows(s)
  h.eq({ rows[12], v.info[rows[12]].glyph }, api.nvim_win_get_cursor(v.win), 'on #12\'s glyph (the viewed layer\'s PR)')
  h.eq({ 11, 12, 13, 15 }, (lit(s)))
  h.eq('^ .', lit_line(s, rows[19]), 'the line beside #19 is #12 → #13, on the path; #19 is not')
  -- l: across to the sibling branch at the fork, the path through it lit, lines included
  api.nvim_feedkeys('l', 'x', false)
  h.eq(19, at(s))
  h.eq({ 11, 12, 19 }, (lit(s)))
  h.eq('. ^', lit_line(s, rows[19]))
  h.eq('^^^', lit_line(s, rows[19] + 1), 'the join into #12')
  h.eq(' path: main › #11 › #12 › #19⇣', footer(s)[1])
  -- h: back across
  api.nvim_feedkeys('h', 'x', false)
  h.eq(13, at(s))
  h.eq({ 11, 12, 13, 15 }, (lit(s)))
  h.eq('^ .', lit_line(s, rows[19]))
  h.eq('^..', lit_line(s, rows[19] + 1), '`├` carries #13\'s line too')
  -- k up, j down the branch to the trunk end
  api.nvim_feedkeys('k', 'x', false)
  h.eq(15, at(s))
  h.eq({ rows[15], v.info[rows[15]].glyph }, api.nvim_win_get_cursor(v.win))
  api.nvim_feedkeys('k', 'x', false)
  h.eq(15, at(s), 'the top: stays')
  api.nvim_feedkeys('jjj', 'x', false)
  h.eq(11, at(s))
  h.eq(' path: main › #11 › #12 › #13 › #15⇣', footer(s)[1], 'the default route on from #11')
  api.nvim_feedkeys('j', 'x', false)
  h.eq(11, at(s), 'the trunk is not a PR')
  api.nvim_feedkeys('kk', 'x', false)
  h.eq(13, at(s))
  -- closed PRs: shown, then hidden again; the cursor stays on its PR
  api.nvim_feedkeys('C', 'x', false)
  rows = tree_rows(s)
  h.ok(rows[10] and rows[14] and rows[16] and rows[17], 'closed PRs shown')
  h.eq(13, at(s))
  h.ok(footer(s)[2]:find('C closed', 1, true))
  api.nvim_feedkeys('C', 'x', false)
  rows = tree_rows(s)
  h.eq(nil, rows[16])
  -- q: closed, nothing changed
  local stack = s.review.stack
  api.nvim_feedkeys('q', 'x', false)
  h.eq(nil, s.gh_tree.view)
  h.ok(not api.nvim_win_is_valid(v.win))
  h.ok(not api.nvim_win_is_valid(v.fwin), 'the footer too')
  h.eq(s.diff_win, api.nvim_get_current_win())
  wait_idle(s)
  h.eq(stack, s.review.stack, 'the stack is unchanged')
  -- <Esc> closes too
  api.nvim_feedkeys('gb', 'x', false)
  h.ok(s.gh_tree.view ~= nil)
  api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  h.eq(nil, s.gh_tree.view)
  view.close()
end)

test('a long, nested tree: every PR reachable with j/k/h/l, the view scrolls, the footer shortens', function()
  local s = open('tree-long', nil, { prepare = h.tree_extend })
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  api.nvim_feedkeys('C', 'x', false)
  local v = s.gh_tree.view
  h.eq(12, at(s))
  -- down the long path to its bottom: the cursor stays in view
  api.nvim_feedkeys('30j', 'x', false)
  h.eq(100, at(s))
  local row = api.nvim_win_get_cursor(v.win)[1]
  api.nvim_win_call(v.win, function()
    h.ok(row >= vim.fn.line('w0') and row <= vim.fn.line('w$'), 'visible')
  end)
  h.ok(footer(s)[1]:find('^ path: main › #100⇣ › … %d+ more … › '), footer(s)[1])
  -- every PR from #100 by the keys
  local seen, queue = { [100] = true }, { 100 }
  local tree_mod = require('revuey.stack_tree')
  while #queue > 0 do
    local n = table.remove(queue)
    for _, k in ipairs({ 'h', 'j', 'k', 'l' }) do
      local m = tree_mod.nav(s.gh_tree.tree, v.rows, n, k)
      if not seen[m] then
        seen[m] = true
        queue[#queue + 1] = m
      end
    end
  end
  for n in pairs(v.row_pr) do
    h.ok(seen[v.row_pr[n]], '#' .. v.row_pr[n])
  end
  -- and by keys pressed: up to #13, across into the closed chain, up it, across into the fork
  api.nvim_feedkeys('40k', 'x', false)
  h.eq(15, at(s))
  api.nvim_feedkeys('jl', 'x', false)
  h.eq(120, at(s), 'from #13 into its own side branch, the closed chain')
  api.nvim_feedkeys('k', 'x', false)
  h.eq(121, at(s), 'up the chain')
  api.nvim_feedkeys('l', 'x', false)
  h.eq(130, at(s), 'the fork off #121')
  h.ok(footer(s)[1]:find('^ path: main › #100⇣ › … %d+ more … › .*#130⇣$'), footer(s)[1])
  api.nvim_feedkeys('h', 'x', false)
  h.eq(121, at(s), 'back across: the nearest PR')
  api.nvim_feedkeys('j', 'x', false)
  h.eq(120, at(s), 'and down the chain')
  api.nvim_feedkeys('q', 'x', false)
  view.close()
end)

test('the lit path through a later side branch is lit all the way to its fork', function()
  local s = open('tree-lit-joined')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  api.nvim_feedkeys('C', 'x', false)
  api.nvim_feedkeys('kl', 'x', false)
  h.eq(19, at(s))
  local rows = tree_rows(s)
  h.eq('. ^', lit_line(s, rows[19]))
  h.eq('^^^', lit_line(s, rows[19] + 1))
  h.eq('^ .', lit_line(s, rows[14]), 'beside #14 the line still carries #19 down to #12')
  h.eq('^..', lit_line(s, rows[14] + 1))
  api.nvim_feedkeys('q', 'x', false)
  view.close()
end)

test('the footer follows the window: hidden when too short, back when it grows', function()
  local s = open('tree-footer-resize')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  local v = s.gh_tree.view
  local function shown()
    return not api.nvim_win_get_config(v.fwin).hide
  end
  local function wait_resized()
    -- WinResized comes with a screen redraw, which a headless Neovim without a UI never does
    api.nvim_exec_autocmds('WinResized', { modeline = false })
    vim.wait(300, function()
      return false
    end)
  end
  h.ok(shown())
  local full = api.nvim_win_get_height(s.diff_win)
  local fpos = api.nvim_win_get_position(v.fwin)[1]
  -- a short diff window: a split above it takes the room
  api.nvim_set_current_win(s.diff_win)
  vim.cmd('aboveleft ' .. (full - 3) .. 'split')
  local other = api.nvim_get_current_win()
  api.nvim_set_current_win(v.win)
  wait_resized()
  h.ok(api.nvim_win_get_height(s.diff_win) < 6, 'short now')
  h.eq(false, shown(), 'no room: hidden, not left over the other window')
  api.nvim_win_close(other, true)
  if s.gh_tree.view then
    api.nvim_set_current_win(v.win)
  end
  wait_resized()
  h.ok(s.gh_tree.view, 'still open')
  h.ok(shown(), 'room again: shown')
  h.eq(fpos, api.nvim_win_get_position(v.fwin)[1], 'at the bottom again')
  api.nvim_feedkeys('q', 'x', false)
  view.close()
end)

test('h/l then <CR>: the other branch at a fork is reviewed', function()
  local s = open('tree-swap')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  api.nvim_feedkeys('C', 'x', false)
  h.eq(12, at(s))
  api.nvim_feedkeys('l', 'x', false)
  h.eq(14, at(s), '#12\'s own side branch nearest to it')
  h.eq(' path: main › #11 › #12 › #14', footer(s)[1])
  api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  h.ok(wait_idle(s))
  h.eq(14, s.gh_tree.sel)
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/x' }, names(s))
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  -- the reviewed path is column 0 now, the other branch moved right
  api.nvim_feedkeys('gb', 'x', false)
  local v = s.gh_tree.view
  local lines = api.nvim_buf_get_lines(v.buf, 0, -1, false)
  h.ok(vim.iter(lines):any(function(l)
    return l:find('^● #14') ~= nil
  end), table.concat(lines, '\n'))
  h.ok(vim.iter(lines):any(function(l)
    return l:find('^│ ○ #15') ~= nil or l:find('^│ ○ #13') ~= nil
  end), table.concat(lines, '\n'))
  api.nvim_feedkeys('q', 'x', false)
  view.close()
end)

test('<CR>: the stack becomes the chosen path, viewing its PR; full scope and ]s/[s follow it', function()
  local s = open('tree-select')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  api.nvim_feedkeys('C', 'x', false)
  local rows, v = tree_rows(s)
  api.nvim_win_set_cursor(v.win, { rows[16], 0 })
  api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  h.eq(nil, s.gh_tree.view, 'the view closes')
  h.ok(wait_idle(s))
  h.eq(16, s.gh_tree.sel)
  -- #16 is closed: its own path (nothing open above it)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope, 'viewing #16')
  h.ok(vim.tbl_contains(vim.tbl_map(function(n)
    return n.kind
  end, s.review.stack.notes), 'head_off_path'), 'stack/b (checked out) is not on this path')
  h.eq('origin/stack/old1', s.review.branch)
  h.eq({ 'src/legacy.ts' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  -- [s / ]s and the full scope along the chosen path
  api.nvim_feedkeys('[s', 'x', false)
  h.ok(wait_idle(s))
  h.eq({ kind = 'layer', index = 1 }, s.scope)
  h.eq('origin/stack/a', s.review.branch)
  api.nvim_feedkeys(']s', 'x', false)
  h.ok(wait_idle(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  api.nvim_feedkeys('gs', 'x', false)
  h.ok(wait_idle(s))
  h.eq('full', s.scope.kind)
  h.eq({ 'src/legacy.ts', 'src/price.ts' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  -- choosing HEAD's PR again: the default route
  api.nvim_feedkeys('gb', 'x', false)
  rows, v = tree_rows(s)
  api.nvim_win_set_cursor(v.win, { rows[13], 0 })
  api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  -- a refresh (git) keeps the chosen path
  local msgs, restore = h.capture_notify()
  s.gh_tree.sel = 16
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  restore()
  h.eq('revuey: layer origin/stack/c is no longer in the stack; showing origin/stack/old1', msgs[1] and msgs[1].msg)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  view.close()
end)

test('R: the tree is fetched again (and only then); the chosen path stays', function()
  local s, _, calls = open('tree-refetch')
  local before = #tree_calls(calls)
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq(before, #tree_calls(calls), 'a refresh never refetches')
  s.gh_tree.sel = 16
  local _, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(vim.wait(15000, function()
    return #tree_calls(calls) >= 2 * before - 1 and not s.gh_tree.loading and not s.forge.busy and not s.refreshing
  end, 20))
  h.ok(wait_idle(s))
  restore()
  h.eq(16, s.gh_tree.sel)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  view.close()
end)

test('the fetch key: git fetch of the stack\'s branches from the PRs\' remote, then the marks go', function()
  local s, r, calls, ssh_log = open('tree-fetch')
  local n_gh = #h.read_calls(calls)
  local msgs, restore = h.capture_notify()
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gF', 'x', false)
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.fetching and #names(s) == 4
  end, 20), 'fetched')
  h.ok(wait_idle(s))
  restore()
  -- no tree call, nothing but the PR lookup of the layer that appeared (stack/d): GitHub is only read
  h.eq(0, #vim.tbl_filter(function(c)
    local q = c.argv[5] or ''
    return not (q:match('^query=query {') and q:find('l1:', 1, true) and not q:find('sd1:', 1, true))
  end, vim.list_slice(h.read_calls(calls), n_gh + 1)))
  h.ok(vim.fn.readfile(ssh_log)[1]:find('git%-upload%-pack'), 'git fetch went through the fake ssh')
  h.eq(r.oid.c2, vim.trim(h.git(r.dir, 'rev-parse', 'origin/stack/c')))
  h.eq(r.oid.d, vim.trim(h.git(r.dir, 'rev-parse', 'origin/stack/d')))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'origin/stack/d' }, names(s))
  for _, l in ipairs(s.review.stack.layers) do
    h.eq(nil, l.fetch, l.name)
  end
  h.eq({}, vim.tbl_filter(function(n)
    return n.kind == 'not_fetched'
  end, s.review.stack.notes))
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg == 'revuey: fetched #13 #15 from origin'
  end), vim.inspect(msgs))
  -- again: nothing to fetch
  msgs, restore = h.capture_notify()
  require('revuey.stack_tree_view').fetch(s)
  h.ok(vim.wait(5000, function()
    return #msgs > 0
  end, 20))
  restore()
  h.eq('revuey: nothing to fetch: the stack is up to date with GitHub', msgs[1].msg)
  -- a fork's PR: chosen, it is missing; the fetch key in the tree fetches refs/pull/19/head
  -- (commits only, no ref) and it becomes a read-only layer that gS refuses
  msgs, restore = h.capture_notify()
  tv.select(s, 19)
  h.ok(wait_idle(s))
  h.ok(vim.wait(2000, function()
    return vim.iter(msgs):any(function(m)
      return m.msg:find('PR #19 is not in this clone yet; gF fetches it', 1, true) ~= nil
    end)
  end, 20), vim.inspect(msgs))
  h.eq({ 'origin/stack/a', 'stack/b' }, names(s))
  api.nvim_feedkeys('gb', 'x', false)
  local rows, v = tree_rows(s)
  api.nvim_win_set_cursor(v.win, { rows[19], 0 })
  api.nvim_feedkeys('gF', 'x', false)
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.fetching and #names(s) == 3
  end, 20), 'fork fetched')
  h.ok(wait_idle(s))
  restore()
  h.eq({ 'origin/stack/a', 'stack/b', 'bob:fix-d' }, names(s))
  local f = s.review.stack.layers[3]
  h.eq({ true, true, r.oid.fork }, { f.fork_pr, f.remote, f.tip })
  h.eq('', h.git(r.dir, 'for-each-ref', 'refs/pull', 'refs/remotes/origin/pr'), 'no ref written for it')
  msgs, restore = h.capture_notify()
  view.switch_layer(3)
  restore()
  h.ok(msgs[1].msg:find('comes from a fork; check it out with `gh pr checkout 19`', 1, true), msgs[1].msg)
  if s.gh_tree.view then
    tv.close_view(s)
  end
  view.close()
end)

test('GitHub fails: git detection stays, the tree key says why', function()
  local s = open('tree-fail', 'fail')
  h.eq(nil, s.gh_tree.tree)
  h.eq(nil, s.review.stack, 'a lone local branch: the plain review, as without GitHub')
  local msgs, restore = h.capture_notify()
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  restore()
  h.eq('revuey: no stack tree from GitHub: the GitHub lookup failed (see revuey.log) (the stack comes from git)', msgs[1].msg)
  -- quiet in the panel, like the PR lookup it shared its call with (decision 13)
  h.eq(false, vim.iter(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)):any(function(x)
    return x:find('stack tree', 1, true) ~= nil
  end))
  h.eq(nil, s.gh_tree.view)
  view.close()
end)

test('later tree rounds fail: the chain read so far is the stack, the failure is logged', function()
  local s = open('tree-fail-later', nil, { tree_scenario = 'fail' })
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = nil
  h.ok(s.gh_tree.tree ~= nil)
  h.eq({ 'origin/stack/a', 'stack/b' }, names(s))
  h.ok(s.gh_tree.tree.cut ~= nil)
  local text = table.concat(vim.fn.readfile(log_file), '\n')
  h.ok(text:find('stack tree: ', 1, true), 'logged')
  h.ok(vim.iter(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)):any(function(x)
    return x:find('stack tree incomplete: R', 1, true) ~= nil
  end), 'the panel says so')
  view.close()
end)

test('stack.github = false: no tree query, git detection only', function()
  setup({ stack = { github = false } })
  local s, _, calls = open('tree-off')
  h.eq(0, #tree_calls(calls))
  h.eq(nil, s.review.stack)
  local msgs, restore = h.capture_notify()
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  restore()
  h.ok(msgs[1].msg:find('the stack tree is off', 1, true), msgs[1].msg)
  view.close()
  setup()
end)

local function files(s)
  return vim.tbl_map(function(f)
    return f.path
  end, s.review.files or {})
end

local function note_kinds(s)
  return vim.tbl_map(function(n)
    return n.kind
  end, (s.review.stack and s.review.stack.notes) or s.review.notes or {})
end

local function fetch_and_wait(s, nums)
  local msgs, restore = h.capture_notify()
  tv.fetch(s, nums)
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.fetching
  end, 20), 'fetched')
  h.ok(wait_idle(s))
  restore()
  return msgs
end

test('a closed PR of a moved branch: its own commit, never the local branch of the newer PR; its own PR in the forge', function()
  local s, r = open('tree-moved-local', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/c', 'origin/stack/c') -- a local copy of #13's branch
    end,
  })
  tv.select(s, 10)
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a' }, names(s), '#10\'s commit is not here: left out, not shown from stack/c')
  fetch_and_wait(s)
  h.eq({ 'origin/stack/a', 'origin/stack/c' }, names(s))
  local l = s.review.stack.layers[2]
  h.eq({ r.oid.c_old, 10, true }, { l.tip, l.pr, l.unfetched })
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.eq({ 'src/coupon.ts' }, files(s), 'only #10\'s change')
  h.ok(vim.wait(10000, function()
    return not s.forge.busy and require('revuey.forge_view').pr(s, 'origin/stack/c') ~= nil
  end, 20))
  local fv = require('revuey.forge_view')
  h.eq(10, fv.pr(s, 'origin/stack/c').number, 'the layer\'s PR is #10, not the branch\'s open #13')
  h.eq({ 10 }, vim.tbl_map(function(p)
    return p.number
  end, (fv.scope_prs(s, true))), 'the change check asks #10')
  h.eq({}, require('revuey.forge_post_view').scope_targets(s), 'nothing to post to (#10 is closed), never #13')
  view.close()
end)

test('a local branch behind its open PR (not checked out): the layer is the PR\'s, with a note', function()
  local s, r = open('tree-local-behind', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/a', 'main')
    end,
  })
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  local l = s.review.stack.layers[1]
  h.eq({ r.oid.a, 'other', 'local' }, { l.tip, l.local_differs, l.fetch })
  h.ok(vim.tbl_contains(note_kinds(s), 'local_differs'))
  view.set_scope({ kind = 'layer', index = 1 })
  h.ok(wait_idle(s))
  h.eq({ 'src/price.ts' }, files(s), '#11\'s change, not stack/b\'s')
  view.close()
end)

test('a fork\'s PR as a layer: threads, the description, posting and the change check are its own', function()
  setup({ forge = { threads = { enabled = true }, description = { enabled = true } } })
  local thread = {
    id = 'T19', isResolved = false, isOutdated = false, path = 'src/fix.ts', line = 1, startLine = vim.NIL,
    originalLine = 1, originalStartLine = vim.NIL, diffSide = 'RIGHT', startDiffSide = vim.NIL, subjectType = 'LINE',
    resolvedBy = vim.NIL,
    comments = { { id = 'C19', databaseId = 19, url = 'https://github.com/acme/shop/pull/19#c', body = 'Round down?',
      createdAt = '2026-01-04T00:00:00Z', lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = '', author = { login = 'carol' },
      replyTo = vim.NIL } },
  }
  local s, _, calls = open('tree-fork-forge', nil, {
    threads = { ['acme/shop#19'] = { thread } },
    prepare = function(r)
      r.prs['acme/shop:fix-d'][1].body = 'Rounding fix from a fork.'
    end,
  })
  tv.select(s, 19)
  h.ok(wait_idle(s))
  fetch_and_wait(s, { 19 })
  h.eq('bob:fix-d', s.review.stack.layers[s.scope.index].name)
  local fv = require('revuey.forge_view')
  h.ok(vim.wait(10000, function()
    return not s.forge.busy and fv.pr(s, 'bob:fix-d') ~= nil and #fv.thread_items(s) > 0
  end, 20), 'the fork PR\'s lookup and threads')
  h.eq(19, fv.pr(s, 'bob:fix-d').number)
  h.eq({ 19 }, vim.tbl_map(function(p)
    return p.number
  end, (fv.scope_prs(s))))
  h.eq(19, require('revuey.forge_post_view').scope_targets(s)[1].pr.number, 'a post goes to #19')
  h.eq('Rounding fix from a fork.', fv.descriptions(s)[1] and fv.descriptions(s)[1].md)
  h.ok(vim.iter(h.read_calls(calls)):any(function(c)
    return (c.argv[5] or ''):find('pullRequest(number: 19)', 1, true) ~= nil and c.argv[5]:find('reviewThreads', 1, true) ~= nil
  end), 'threads asked for #19')
  local n = #h.read_calls(calls)
  fv.check(s)
  h.ok(vim.wait(10000, function()
    return #h.read_calls(calls) > n and not s.forge.checking
  end, 20))
  local q = h.read_calls(calls)[n + 1].argv[5]
  h.ok(q:find('fragment check', 1, true) and q:find('pullRequest(number: 19)', 1, true), 'the change check asks #19')
  view.close()
  setup()
end)

test('HEAD on an unrelated branch: its own (first) fetch, git meanwhile; back again without a fetch', function()
  local s, r, calls = open('tree-head-moves')
  local before = #tree_calls(calls)
  h.git(r.dir, 'checkout', '-q', '-b', 'unrelated', 'main')
  h.write(r.dir, 'other.txt', 'x\n')
  h.git(r.dir, 'add', '-A')
  h.git(r.dir, 'commit', '-q', '-m', 'other')
  local _, restore = h.capture_notify()
  view.refresh({ force = true })
  h.ok(vim.wait(10000, function()
    return s.gh_tree.reason ~= nil and wait_idle(s)
  end, 20))
  restore()
  h.eq(nil, s.review.stack, 'git detection: a lone branch')
  h.eq({ 'other.txt' }, files(s))
  h.eq('no pull request for unrelated', s.gh_tree.reason)
  h.eq(before + 1, #tree_calls(calls), 'one first fetch for the new branch')
  h.ok(tree_calls(calls)[before + 1]:find('headRefName: "unrelated"', 1, true))
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s), 'its tree again')
  h.eq(before + 1, #tree_calls(calls), 'kept from before: no fetch')
  view.close()
end)

test('HEAD on a branch of the tree (gS to a layer): the path stays, @ follows HEAD', function()
  local s, r = open('tree-head-layer')
  h.eq(12, s.gh_tree.head_pr)
  h.git(r.dir, 'checkout', '-q', '--track', 'origin/stack/a')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq(true, s.review.stack.layers[1].is_head)
  h.eq(false, s.review.stack.layers[2].is_head)
  h.eq(11, s.gh_tree.head_pr)
  h.eq({ kind = 'layer', index = 2 }, s.scope, 'the view stays on the layer it showed')
  view.close()
end)

---gS on layer `index` (view.switch_layer), waiting until HEAD is `branch` and the review is idle.
local function switch_to(s, index, branch)
  local done
  local msgs, restore = h.capture_notify()
  view.switch_layer(index, { on_done = function(ok, msg)
    done = { ok = ok, msg = msg }
  end })
  h.ok(vim.wait(15000, function()
    return done ~= nil
  end, 10), 'switch did not finish')
  h.ok(done.ok, done.msg)
  h.ok(vim.wait(15000, function()
    local l = s.review.stack and s.review.stack.layers[s.review.stack.head_index or 0]
    return wait_idle(s) and require('revuey.git').current_branch(s.review.root) == branch and l and l.name == branch
  end, 20), 'HEAD layer did not become ' .. branch)
  h.ok(wait_idle(s))
  restore()
  return msgs
end

---The viewed layer's name (▶) and HEAD's (@), from the panel.
local function marks(s)
  local text = table.concat(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  return { (text:match('▶[@ ] (%S+)')), (text:match('[▶ ]@ (%S+)')) }
end

test('gS in a GitHub stack views the switched layer: the top, the bottom, the middle (the tree kept)', function()
  local s, r, calls = open('tree-switch-follows')
  local n = #tree_calls(calls)
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  switch_to(s, 3, 'stack/c')
  h.eq({ 'origin/stack/a', 'stack/b', 'stack/c' }, names(s))
  h.eq(3, s.scope.index, 'the switched layer, not the old one')
  h.eq({ 'stack/c', 'stack/c' }, marks(s))
  switch_to(s, 1, 'stack/a')
  h.eq(1, s.scope.index, 'the bottom, not the route\'s start')
  h.eq({ 'stack/a', 'stack/a' }, marks(s))
  view.set_scope({ kind = 'layer', index = 3 })
  h.ok(wait_idle(s))
  switch_to(s, 2, 'stack/b')
  h.eq(2, s.scope.index, 'the middle, not the top')
  h.eq({ 'stack/b', 'stack/b' }, marks(s))
  h.eq(n, #tree_calls(calls), 'the tree is kept: HEAD stayed on its branches')
  -- the guide view (no guide yet) follows too: its scope is the switched layer
  view.set_view('guide')
  h.ok(wait_idle(s))
  switch_to(s, 3, 'stack/c')
  h.eq(3, s.scope.index)
  h.eq('guide', s.view_mode)
  h.ok(view.guide_winbar(s, s.diff_win):find('layer stack/c', 1, true), view.guide_winbar(s, s.diff_win))
  view.set_view('diff')
  h.ok(wait_idle(s))
  switch_to(s, 2, 'stack/b')
  -- a chosen path: gS views the switched layer, not the chosen PR's
  tv.select(s, 13)
  h.ok(wait_idle(s))
  h.eq(3, s.scope.index)
  switch_to(s, 1, 'stack/a')
  h.eq(1, s.scope.index, 'the switched layer, not the chosen PR\'s')
  h.eq(13, s.gh_tree.sel, 'the path stays chosen')
  h.eq({ 'stack/a', 'stack/a' }, marks(s))
  -- ]s with switch_on_navigate: the view and HEAD move together
  require('revuey.config').options.stack.switch_on_navigate = true
  local ok, err = pcall(function()
    api.nvim_set_current_win(s.diff_win)
    local _, restore = h.capture_notify()
    api.nvim_feedkeys(vim.keycode(']s'), 'mtx', false)
    h.ok(vim.wait(15000, function()
      return require('revuey.git').current_branch(r.dir) == 'stack/b' and wait_idle(s)
        and s.review.stack.layers[s.review.stack.head_index].name == 'stack/b'
    end, 20), ']s switched')
    restore()
    h.eq(2, s.scope.index)
    h.eq({ 'stack/b', 'stack/b' }, marks(s))
  end)
  require('revuey.config').options.stack.switch_on_navigate = false
  assert(ok, err)
  view.close()
end)

test('HEAD on the top PR\'s branch, gS to the middle: the middle is viewed, not the top', function()
  local s = open('tree-switch-from-top', nil, {
    prepare = function(r)
      h.git(r.dir, 'checkout', '-q', '--track', 'origin/stack/c')
    end,
  })
  h.eq({ 'origin/stack/a', 'stack/b', 'stack/c' }, names(s))
  h.eq(3, s.scope.index)
  view.set_scope({ kind = 'layer', index = 1 })
  h.ok(wait_idle(s))
  switch_to(s, 2, 'stack/b')
  h.eq(2, s.scope.index, 'the middle layer, not the top')
  h.eq({ 'stack/b', 'stack/b' }, marks(s))
  view.close()
end)

test('gS to a local layer above the top PR (a first fetch for its branch): that layer is viewed', function()
  local s, r = open('tree-switch-local-above')
  fetch_and_wait(s)
  h.git(r.dir, 'branch', 'stack/d', 'origin/stack/d')
  h.git(r.dir, 'branch', 'stack/e', 'stack/d')
  h.git(r.dir, 'checkout', '-q', 'stack/e')
  h.write(r.dir, 'src/e.ts', 'export const e = 1\n')
  h.git(r.dir, 'add', '-A')
  h.git(r.dir, 'commit', '-q', '-m', 'e')
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'stack/d', 'stack/e' }, names(s))
  h.eq(2, s.scope.index)
  local done
  view.switch_layer(5, { on_done = function(ok)
    done = ok
  end })
  h.ok(vim.wait(15000, function()
    return done ~= nil
  end, 10))
  h.eq(true, done)
  h.ok(vim.wait(15000, function()
    return s.gh_tree.fetched and not s.gh_tree.running and not s.gh_tree.loading and wait_idle(s)
      and s.review.stack and s.review.stack.layers[s.scope.index]
  end, 20))
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  local stack = s.review.stack
  h.eq('stack/e', stack.layers[s.scope.index].name, vim.inspect(names(s)))
  h.eq('stack/e', marks(s)[1])
  h.eq('stack/e', marks(s)[2])
  view.close()
end)

test('only R refetches the tree: not the refetch after a post', function()
  local s, _, calls = open('tree-post-refetch')
  local n = #tree_calls(calls)
  local all = #h.read_calls(calls)
  require('revuey.forge_view').update(s, true)
  h.ok(vim.wait(10000, function()
    return #h.read_calls(calls) > all and wait_idle(s)
  end, 20))
  h.eq(n, #tree_calls(calls), 'the PRs, not the tree')
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  h.ok(#tree_calls(calls) > n, 'R')
  view.close()
end)

test('R keeps a chosen PR under a closed one, and the stack object when nothing changed', function()
  local s = open('tree-r-closed')
  tv.select(s, 16)
  h.ok(wait_idle(s))
  local stack = s.review.stack
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  local msgs, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  restore()
  h.eq(16, s.gh_tree.sel)
  h.eq(stack, s.review.stack, 'the same stack: nothing reloaded by the phases')
  h.eq({}, vim.tbl_filter(function(m)
    return m.msg:find('no longer in the stack', 1, true) ~= nil
  end, msgs))
  -- #17 (under closed #16, its commit not here)
  tv.select(s, 17)
  h.ok(wait_idle(s))
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  h.eq(17, s.gh_tree.sel)
  view.close()
end)

test('the tree\'s rounds run outside the PR lookup, and stop when the review closes', function()
  local s, _, calls = open('tree-slow', 'slow')
  vim.env.REVUEY_FAKE_GH_DELAY = '0.5'
  view.refresh({ force = true, forge = true })
  h.ok(vim.wait(10000, function()
    return s.gh_tree.running ~= nil and not s.forge.busy
  end, 10), 'the lookup is done while the tree\'s rounds run')
  local version, n = s.gh_tree.version, #h.read_calls(calls)
  view.close()
  vim.wait(2500, function()
    return false
  end)
  h.eq(version, s.gh_tree.version, 'nothing taken after close')
  h.ok(#h.read_calls(calls) <= n + 1, 'no round after close')
  vim.env.REVUEY_FAKE_GH_DELAY = nil
end)

test('gF: a branch gone on GitHub comes by its pull ref, the rest is fetched; no prompts', function()
  local s, r, _, ssh_log = open('tree-fetch-partial')
  h.git(r.bare, 'update-ref', '-d', 'refs/heads/stack/d')
  local msgs = fetch_and_wait(s)
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg == 'revuey: fetched #13; #15 only by their pull refs (branch gone on GitHub) from origin'
  end), vim.inspect(msgs))
  h.eq(r.oid.c2, vim.trim(h.git(r.dir, 'rev-parse', 'origin/stack/c')))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'origin/stack/d' }, names(s), '#15 from its commit')
  for _, line in ipairs(vim.fn.readfile(ssh_log)) do
    h.ok(line:find('prompt=0', 1, true), line)
  end
  view.close()
end)

test('git detection finds another stack: the tree overrides it, says where a parent setting disagrees', function()
  local git_stack
  local s, r = open('tree-over-git', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/a', 'origin/stack/a')
      h.git(r.dir, 'branch', 'stack/old1', 'origin/stack/old1')
      h.git(r.dir, 'config', 'branch.stack/b.revueyParent', 'stack/old1')
      git_stack = require('revuey.stack').detect(r.dir, 'origin/main')
    end,
  })
  h.eq({ 'stack/a', 'stack/old1', 'stack/b' }, vim.tbl_map(function(l)
    return l.name
  end, git_stack.layers), 'git\'s own stack, from the parent setting')
  h.eq({ 'stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.ok(vim.tbl_contains(note_kinds(s), 'github_parent'), vim.inspect(note_kinds(s)))
  -- a commit on stack/b: origin/stack/c is not based on it any more
  h.write(r.dir, 'src/tax.ts', 'export const tax = 0.25\n')
  h.git(r.dir, 'commit', '-q', '-am', 'tax')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq(true, s.review.stack.layers[3].diverged)
  h.ok(vim.tbl_contains(note_kinds(s), 'pr_not_restacked'), vim.inspect(note_kinds(s)))
  view.close()
end)

test('local branches above the top PR (no PR yet) stay on top', function()
  local s, r = open('tree-local-above')
  fetch_and_wait(s)
  h.git(r.dir, 'branch', 'stack/d', 'origin/stack/d')
  h.git(r.dir, 'branch', 'stack/e', 'stack/d')
  h.git(r.dir, 'checkout', '-q', 'stack/e')
  h.write(r.dir, 'src/e.ts', 'export const e = 1\n')
  h.git(r.dir, 'add', '-A')
  h.git(r.dir, 'commit', '-q', '-m', 'e')
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'stack/d', 'stack/e' }, names(s))
  h.eq(nil, s.review.stack.layers[5].pr)
  view.close()
end)

test('a lone PR stays a plain review until a path is chosen', function()
  local s = open('tree-lone', nil, {
    prepare = function(r)
      local a = r.prs['acme/shop:stack/a'][1]
      r.prs._tree['acme/shop'] = { a }
      h.git(r.dir, 'checkout', '-q', '--track', 'origin/stack/a')
      h.git(r.dir, 'branch', '-q', '-D', 'stack/b') -- else git finds a stack of its own
    end,
  })
  h.ok(s.gh_tree.tree ~= nil)
  h.eq(nil, s.review.stack)
  tv.select(s, 11)
  h.ok(wait_idle(s))
  h.eq({ 'stack/a' }, names(s))
  view.close()
end)

test('GitHub rejects the lookup with the tree in it: the PRs are looked up alone', function()
  local s = open('tree-reject', nil, { tree_scenario = 'reject' })
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = nil
  h.eq(nil, s.gh_tree.tree)
  h.eq(12, require('revuey.forge_view').pr(s, '') and require('revuey.forge_view').pr(s, '').number)
  h.ok(table.concat(vim.fn.readfile(log_file), '\n'):find('retrying without it', 1, true))
  view.close()
end)

test('a PR chosen while closed PRs still load: the stack is rebuilt when they arrive', function()
  vim.env.REVUEY_FAKE_GH_DELAY = '0.4'
  local s = open('tree-phase-two', 'slow', {
    until_ = function(s)
      return s.gh_tree and s.gh_tree.loading == true and s.review.stack ~= nil and not s.refreshing
    end,
  })
  tv.select(s, 16) -- #16's children (closed #17) are not read yet
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.loading and not s.gh_tree.running and wait_idle(s)
  end, 20))
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  h.eq(1, s.review.stack.layers[2].others, '⑂1: #17, read in phase two')
  view.close()
end)

test('R: a chosen PR GitHub no longer has is dropped, back to the default route', function()
  local s, r, calls = open('tree-sel-gone')
  tv.select(s, 16)
  h.ok(wait_idle(s))
  local prs = vim.deepcopy(r.prs)
  prs._tree['acme/shop'] = vim.tbl_filter(function(n)
    return n.number ~= 16 and n.number ~= 17
  end, prs._tree['acme/shop'])
  vim.fn.writefile({ vim.json.encode(prs) }, calls .. '.prs.json')
  local _, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  restore()
  h.eq(nil, s.gh_tree.sel)
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  view.close()
end)

test('the tree\'s own rounds fail with the chain unknown below HEAD\'s PR: git detection, and a note that R retries', function()
  local s = open('tree-fail-rounds', nil, {
    tree_scenario = 'fail',
    prepare = function(r)
      -- the chain below stack/b needs a round of its own: a flat lookup of stack/a answers
      -- stack/a's PRs nested, so cut it there by giving stack/a more PRs than a nested level lists
      for i = 1, 3 do
        table.insert(r.prs._tree['acme/shop'], {
          number = 30 + i, title = 'old ' .. i, url = 'https://github.com/acme/shop/pull/' .. (30 + i), state = 'CLOSED',
          isDraft = false, updatedAt = '2026-01-06T0' .. i .. ':00:00Z', headRefName = 'stack/a', baseRefName = 'main',
          headRefOid = r.oid.main, isCrossRepository = false, headRepositoryOwner = { login = 'acme' }, reviewDecision = vim.NIL,
        })
      end
    end,
  })
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = nil
  h.eq({ 12 }, s.gh_tree.tree.chain, 'only HEAD\'s PR was read')
  h.eq(nil, s.review.stack, 'a lone PR: the plain review')
  h.ok(vim.wait(3000, function()
    return vim.iter(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)):any(function(x)
      return x:find('stack tree incomplete: R', 1, true) ~= nil
    end)
  end, 20), table.concat(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n'))
  view.close()
end)

local function pause(ms)
  vim.wait(ms, function()
    return false
  end)
end

local function set_pr(r, num, fields)
  for k, list in pairs(r.prs) do
    if type(list) == 'table' and k ~= '_default_branch' then
      for _, n in ipairs(list['acme/shop'] or list) do
        if type(n) == 'table' and n.number == num then
          for f, v in pairs(fields) do
            n[f] = v
          end
        end
      end
    end
  end
end

test('HEAD\'s branch with a closed PR and work on top: still the HEAD layer, viewed', function()
  local s = open('tree-head-closed', nil, {
    prepare = function(r)
      set_pr(r, 12, { state = 'CLOSED', reviewDecision = vim.NIL })
      h.write(r.dir, 'src/new.ts', 'export const n = 1\n')
      h.git(r.dir, 'add', '-A')
      h.git(r.dir, 'commit', '-q', '-m', 'more work')
      h.write(r.dir, 'src/new.ts', 'export const n = 2\n') -- uncommitted too
    end,
  })
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq(true, s.review.stack.layers[2].is_head)
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.ok(vim.tbl_contains(files(s), 'src/new.ts'), vim.inspect(files(s)))
  h.eq(12, s.gh_tree.head_pr)
  view.close()
end)

test('a chosen PR not in the tree after R (moved under another closed PR): default route, then its path', function()
  vim.env.REVUEY_FAKE_GH_DELAY = '0.3'
  local s, r, calls = open('tree-sel-moved', 'slow')
  tv.select(s, 17)
  h.ok(wait_idle(s))
  local prs = vim.deepcopy(r.prs)
  for _, n in ipairs(prs._tree['acme/shop']) do
    if n.number == 17 then
      n.baseRefName = 'stack/x' -- now on closed #14's branch
    end
  end
  vim.fn.writefile({ vim.json.encode(prs) }, calls .. '.prs.json')
  local _, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  pause(300)
  h.ok(vim.wait(20000, function()
    return not s.gh_tree.loading and not s.gh_tree.running and wait_idle(s)
  end, 20))
  restore()
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.eq(17, s.gh_tree.sel, 'kept through phase one')
  h.eq({ 11, 12, 14, 17 }, (tv.path(s)))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/x' }, names(s))
  view.close()
end)

test('the chosen PR missing from the tree: the default route, no error', function()
  local s = open('tree-sel-missing')
  s.gh_tree.sel = 17
  local t = vim.deepcopy(s.gh_tree.tree)
  t.nodes[17], t.parent[17], t.kids[16] = nil, nil, {}
  s.gh_tree.tree = t
  s.gh_tree.version = s.gh_tree.version + 1
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  view.close()
end)

test('a fetch landing while the stack is built: one tree throughout', function()
  local s = open('tree-race')
  local orig = tv.facts
  tv.facts = function(...)
    local f = orig(...)
    -- take() lands here: a tree without #13 and #15
    local t2 = vim.deepcopy(s.gh_tree.tree)
    t2.nodes[13], t2.nodes[15], t2.kids[12], t2.kids[13] = nil, nil, { 14, 19 }, nil
    t2.parent[13], t2.parent[15] = nil, nil
    s.gh_tree.tree = t2
    tv.facts = orig
    return f
  end
  s.gh_tree.version = s.gh_tree.version + 1
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  tv.facts = orig
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s), 'the tree it started with')
  s.gh_tree.version = s.gh_tree.version + 1
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b' }, names(s), 'then the new one')
  view.close()
end)

test('HEAD leaves before its tree arrived: coming back fetches it', function()
  vim.env.REVUEY_FAKE_GH_DELAY = '0.6'
  local s, r = open('tree-leave-early', 'slow', {
    until_ = function(s)
      return s.gh_tree and s.gh_tree.fetched and s.gh_tree.tree == nil and s.forge and s.forge.busy
    end,
  })
  h.git(r.dir, 'checkout', '-q', '-b', 'unrelated', 'main')
  local _, restore = h.capture_notify()
  view.refresh({ force = true })
  h.ok(vim.wait(20000, function()
    return s.gh_tree.for_branch == 'unrelated' and s.gh_tree.reason ~= nil and wait_idle(s)
  end, 20))
  h.eq(nil, s.gh_tree.saved['stack/b'], 'nothing saved for a tree still loading')
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(vim.wait(20000, function()
    return s.gh_tree.tree ~= nil and not s.gh_tree.loading and not s.gh_tree.running and wait_idle(s)
  end, 20))
  restore()
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  view.close()
end)

test('HEAD leaves while closed PRs load: coming back reads them', function()
  vim.env.REVUEY_FAKE_GH_DELAY = '0.6'
  local s, r = open('tree-leave-phase2', 'slow', {
    until_ = function(s)
      return s.gh_tree and s.gh_tree.loading == true and s.review.stack ~= nil and not s.refreshing
    end,
  })
  h.git(r.dir, 'checkout', '-q', '-b', 'unrelated', 'main')
  local _, restore = h.capture_notify()
  view.refresh({ force = true })
  h.ok(vim.wait(20000, function()
    return s.gh_tree.for_branch == 'unrelated' and s.gh_tree.reason ~= nil and wait_idle(s)
  end, 20))
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(vim.wait(20000, function()
    return s.gh_tree.tree ~= nil and not s.gh_tree.loading and not s.gh_tree.running and wait_idle(s)
  end, 20))
  restore()
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.ok(s.gh_tree.tree.nodes[17], 'the closed subtree is there')
  view.close()
end)

test('R refetches the other branches\' trees too, when HEAD goes back', function()
  local s, r, calls = open('tree-r-saved')
  h.git(r.dir, 'checkout', '-q', '-b', 'unrelated', 'main')
  local _, restore = h.capture_notify()
  view.refresh({ force = true })
  h.ok(vim.wait(10000, function()
    return s.gh_tree.reason ~= nil and wait_idle(s)
  end, 20))
  h.ok(s.gh_tree.saved['stack/b'] ~= nil)
  view.refresh({ force = true, forge = true })
  pause(300)
  h.ok(wait_idle(s))
  local n = #tree_calls(calls)
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  pause(300)
  h.ok(vim.wait(10000, function()
    return s.gh_tree.tree ~= nil and wait_idle(s)
  end, 20))
  restore()
  h.ok(#tree_calls(calls) > n, 'fetched again')
  view.close()
end)

test('a saved tree is found by any branch in it', function()
  local s, r, calls = open('tree-saved-contains')
  h.git(r.dir, 'checkout', '-q', '-b', 'unrelated', 'main')
  local _, restore = h.capture_notify()
  view.refresh({ force = true })
  h.ok(vim.wait(10000, function()
    return s.gh_tree.reason ~= nil and wait_idle(s)
  end, 20))
  local n = #tree_calls(calls)
  h.git(r.dir, 'checkout', '-q', '--track', 'origin/stack/a')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  restore()
  h.eq(n, #tree_calls(calls), 'stack/b\'s tree has stack/a: no fetch')
  h.eq({ 'stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq(true, s.review.stack.layers[1].is_head)
  view.close()
end)

test('a lower branch restacked locally: your copy, the layer above not marked', function()
  local s = open('tree-local-restack', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/a', 'origin/stack/a')
      h.git(r.dir, 'checkout', '-q', 'stack/a')
      h.write(r.dir, 'src/price.ts', 'export const price = 2\n')
      h.git(r.dir, 'commit', '-q', '--amend', '-am', 'a2')
      h.git(r.dir, 'checkout', '-q', 'stack/b')
      h.git(r.dir, 'rebase', '-q', '--onto', 'stack/a', 'origin/stack/a', 'stack/b')
    end,
  })
  h.eq({ 'stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq('restacked', s.review.stack.layers[1].local_differs)
  h.eq(nil, s.review.stack.layers[2].diverged)
  h.eq({ 'src/tax.ts' }, files(s), '#12\'s change only')
  for _, n in ipairs(s.review.stack.notes) do
    h.ok(not (n.kind == 'pr_not_restacked' and n.branch == 'stack/b'), n.text)
  end
  view.close()
end)

test('the bottom base: GitHub\'s copy, not a stale local branch', function()
  local s = open('tree-base-stale', nil, {
    prepare = function(r)
      set_pr(r, 11, { baseRefName = 'release' })
      h.git(r.author, 'push', '-q', 'origin', 'main:release')
      h.git(r.dir, 'fetch', '-q', r.bare, 'main:refs/remotes/origin/release')
      h.git(r.dir, 'branch', 'release', 'main')
      h.git(r.dir, 'checkout', '-q', 'release')
      h.write(r.dir, 'src/stale.ts', 'x\n')
      h.git(r.dir, 'add', '-A')
      h.git(r.dir, 'commit', '-q', '-m', 'stale')
      h.git(r.dir, 'checkout', '-q', 'stack/b')
    end,
  })
  h.eq('origin/release', s.review.stack.layers[1].parent)
  view.close()
end)

test('a local branch above the top with a PR based elsewhere: not stacked, noted', function()
  local s = open('tree-local-above-pr', nil, {
    prepare = function(r)
      h.git(r.dir, 'fetch', '-q', r.bare, '+refs/heads/stack/c:refs/remotes/origin/stack/c')
      h.git(r.dir, 'checkout', '-q', '-b', 'stack/e', 'origin/stack/c')
      h.write(r.dir, 'src/e.ts', 'export const e = 1\n')
      h.git(r.dir, 'add', '-A')
      h.git(r.dir, 'commit', '-q', '-m', 'e')
      h.git(r.dir, 'branch', 'stack/c', 'origin/stack/c')
      h.git(r.dir, 'checkout', '-q', 'stack/c')
      local e = vim.trim(h.git(r.dir, 'rev-parse', 'stack/e'))
      local node = {
        number = 20, title = 'E', url = 'https://github.com/acme/shop/pull/20', state = 'OPEN', isDraft = false,
        updatedAt = '2026-01-06T00:00:00Z', headRefName = 'stack/e', baseRefName = 'stack/a', headRefOid = e,
        isCrossRepository = false, headRepositoryOwner = { login = 'acme' }, reviewDecision = 'REVIEW_REQUIRED',
      }
      table.insert(r.prs._tree['acme/shop'], node)
      r.prs['acme/shop:stack/e'] = { node }
    end,
  })
  h.ok(not vim.tbl_contains(names(s), 'stack/e'), vim.inspect(names(s)))
  h.ok(vim.tbl_contains(note_kinds(s), 'local_above'), vim.inspect(note_kinds(s)))
  view.close()
end)

test('R with a chosen PR under a closed one: its path already after phase one', function()
  local s = open('tree-pins', nil)
  tv.select(s, 17) -- under closed #16, whose children phase one reads only for a pin
  h.ok(wait_idle(s))
  vim.env.REVUEY_FAKE_GH, vim.env.REVUEY_FAKE_GH_DELAY = 'slow', '0.5'
  view.refresh({ force = true, forge = true })
  h.ok(vim.wait(20000, function()
    return s.gh_tree.loading == true and s.gh_tree.running ~= nil and not s.refreshing and not s.pending
  end, 10), 'phase one taken')
  pause(200)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s), 'not the default route meanwhile')
  h.eq({ 11, 16, 17 }, (tv.path(s)))
  h.ok(wait_idle(s))
  vim.env.REVUEY_FAKE_GH, vim.env.REVUEY_FAKE_GH_DELAY = nil, nil
  view.close()
end)

test('R twice: the first fetch\'s rounds stop, and nothing of it is taken', function()
  local s, _, calls = open('tree-gen')
  local full = #tree_calls(calls)
  local function taken()
    local n = 0
    for _, l in ipairs(vim.fn.filereadable(log_file) == 1 and vim.fn.readfile(log_file) or {}) do
      if l:find('stack tree: ', 1, true) then
        n = n + 1
      end
    end
    return n
  end
  local logged = taken()
  vim.env.REVUEY_FAKE_GH, vim.env.REVUEY_FAKE_GH_DELAY = 'slow', '0.4'
  view.refresh({ force = true, forge = true })
  h.ok(vim.wait(20000, function()
    return s.gh_tree.running ~= nil and not s.forge.busy
  end, 10))
  view.refresh({ force = true, forge = true })
  pause(300)
  h.ok(vim.wait(30000, function()
    return not s.gh_tree.running and not s.gh_tree.loading and wait_idle(s)
  end, 20))
  pause(1500)
  vim.env.REVUEY_FAKE_GH, vim.env.REVUEY_FAKE_GH_DELAY = nil, nil
  local extra = #tree_calls(calls) - full
  h.ok(extra < 2 * full, ('%d tree calls for two R, a full fetch is %d'):format(extra, full))
  -- the first fetch's round stopped mid-call fails; its tree must not be taken (logged by take)
  h.eq(logged, taken(), 'the stopped fetch took nothing')
  view.close()
end)

test('gF on a remote that does not answer: one attempt, no retries', function()
  local s, _, _, ssh_log = open('tree-fetch-hang')
  vim.env.REVUEY_FAKE_SSH_HANG = '1'
  local msgs = fetch_and_wait(s)
  vim.env.REVUEY_FAKE_SSH_HANG = nil
  local starts = vim.tbl_filter(function(l)
    return l:find('^start') ~= nil
  end, vim.fn.readfile(ssh_log))
  h.eq(1, #starts, 'a connection failure is not retried per ref')
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg:find('could not fetch #13 #15', 1, true) ~= nil
  end), vim.inspect(msgs))
  view.close()
end, function(m)
  return m:find('could not fetch', 1, true) ~= nil
end)

test('gF then closing the review: the fetch stops, nothing starts after', function()
  local s, _, _, ssh_log = open('tree-fetch-close')
  vim.env.REVUEY_FAKE_SSH_HANG = '8' -- longer than the wait below: only a kill ends it in time
  local _, restore = h.capture_notify()
  tv.fetch(s)
  h.ok(vim.wait(5000, function()
    return vim.fn.filereadable(ssh_log) == 1 and #vim.tbl_filter(function(l)
      return l:find('^start') ~= nil
    end, vim.fn.readfile(ssh_log)) > 0
  end, 20), 'ssh started')
  view.close()
  pause(3000)
  restore()
  vim.env.REVUEY_FAKE_SSH_HANG = nil
  local lines = vim.fn.readfile(ssh_log)
  local starts, pids = 0, {}
  for _, l in ipairs(lines) do
    local pid = l:match('^start pid=(%d+)')
    if pid then
      starts = starts + 1
      pids[#pids + 1] = tonumber(pid)
    end
  end
  h.eq(1, starts, 'no fetch after the close')
  local alive = vim.tbl_filter(function(pid)
    return vim.uv.kill(pid, 0) == 0
  end, pids)
  if #alive > 0 then
    pause(6000) -- not stopped: let it end on its own before failing (no process outlives a spec)
  end
  h.eq({}, alive, 'ssh stopped with the review')
  h.eq(false, s.gh_tree.fetching)
end)

h.run()
