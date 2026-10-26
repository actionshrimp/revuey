-- Integration: the real-thread corpus (tests/data/forge_threads/) end to end. A repository is
-- built from it (main: a README; the PR branch adds every excerpt, so every commented line is
-- in the diff), the fake `gh` serves the PR (its headRefOid is the branch's commit) and the 37
-- threads, and a review is opened the normal way. Each thread must be drawn on the row the
-- corpus expects, or in its file's "GitHub threads on lines not shown here" group: first with
-- the threads numbered against the branch's commit (head trust on), then after a refetch that
-- reports another head commit (trust off).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
require('revuey').setup({ state_dir = h.tmpdir('fce-state'), lsp_warmup = false, log_file = h.tmpdir('fce-log') .. '/revuey.log' })
local view = require('revuey.view')
local cv = require('revuey.comments_view')

local DIR = h.root .. '/tests/data/forge_threads'

local function read(path)
  local fd = assert(io.open(path, 'rb'))
  local s = fd:read('*a')
  fd:close()
  return s
end

local function nz(v)
  return v ~= vim.NIL and v or nil
end

local cases = vim.json.decode(read(DIR .. '/cases.json'))

---The fixture path of case i: each excerpt in its own directory (several cases share a path).
local function fpath(i, c)
  return ('c%02d/%s'):format(i, c.source.path)
end

local changes = {}
for i, c in ipairs(cases) do
  changes[fpath(i, c)] = read(DIR .. '/' .. c.slice)
end
local repo = h.repo('fce', { ['README.md'] = 'corpus\n' }, changes)
h.git(repo, 'remote', 'add', 'origin', 'git@github.com:acme/corpus.git')
local HEAD = vim.trim(h.git(repo, 'rev-parse', 'HEAD'))

local function threads(head)
  local list = {}
  for i, c in ipairs(cases) do
    local th = c.thread
    list[i] = {
      id = ('T%02d'):format(i), isResolved = false, isOutdated = false, path = fpath(i, c),
      line = th.line, startLine = th.start_line, originalLine = th.original_line,
      originalStartLine = th.original_start_line, diffSide = th.side, startDiffSide = th.start_side,
      subjectType = 'LINE', resolvedBy = vim.NIL,
      comments = { {
        id = ('C%02d'):format(i), databaseId = i, url = 'https://github.com/acme/corpus/pull/1#discussion_r' .. i,
        body = ('Corpus thread %02d'):format(i), createdAt = '2026-01-01T00:00:00Z', lastEditedAt = vim.NIL,
        state = 'SUBMITTED', diffHunk = th.diff_hunk, author = { login = 'reviewer' }, replyTo = vim.NIL,
      } },
    }
  end
  return { ['acme/corpus#1'] = list, _heads = { ['acme/corpus#1'] = head } }
end

local PRS = {
  ['acme/corpus:feat'] = { {
    number = 1, title = 'Corpus', url = 'https://github.com/acme/corpus/pull/1', state = 'OPEN', isDraft = false,
    author = { login = 'author' }, latestReviews = { nodes = {} }, reviewRequests = { nodes = {} },
    mergeable = 'MERGEABLE', baseRefName = 'main', headRefName = 'feat', headRepositoryOwner = { login = 'acme' },
    headRefOid = HEAD, updatedAt = '2026-01-01T00:00:00Z', commits = { nodes = {} },
  } },
}

local function settled(s, head)
  return vim.wait(20000, function()
    return not s.refreshing and s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled
      and s.cm and s.cm.forge_items and vim.tbl_count(s.cm.forge_items) == #cases
      and require('revuey.forge').threads_head(require('revuey.forge_view').scope_prs(s)[1]) == head
  end, 20)
end

---Virtual-line text attached to buffer row `row`.
local function vlines(s, row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      out[#out + 1] = table.concat(vim.tbl_map(function(ch)
        return ch[1]
      end, l))
    end
  end
  return table.concat(out, '\n')
end

---Where every thread is drawn, against the corpus' expectation for `mode`.
local function check(s, mode)
  local wrong = {}
  for i, c in ipairs(cases) do
    local id = ('gh:T%02d'):format(i)
    local want = c.expected[mode]
    local p, rows = s.cm.forge_place[id], s.cm.forge_rows[id]
    local what = ('%02d %s#%d %s'):format(i, c.source.repo, c.source.pr, c.source.path)
    local ok, why = true, nil
    if not p or not rows then
      ok, why = false, 'not drawn'
    elseif p.how ~= want.how then
      ok, why = false, ('placed %s, expected %s'):format(p.how, want.how)
    elseif want.how == 'outside' then
      local e = s.layout.map[rows.last]
      ok = rows.group == 'gh_outside' and e.path == fpath(i, c)
      why = 'not in its file\'s "not shown here" group'
    else
      local first, last = s.layout.map[rows.first], s.layout.map[rows.last]
      ok = rows.group == nil and first.path == fpath(i, c) and last.path == fpath(i, c)
        and first.kind == 'add' and first.new_lnum == want.start_line and last.new_lnum == want.end_line
      why = ('rows show lines %s-%s, expected %d-%d'):format(tostring(first.new_lnum), tostring(last.new_lnum),
        want.start_line, want.end_line)
    end
    if ok and not vlines(s, rows.last):find(('Corpus thread %02d'):format(i), 1, true) then
      ok, why = false, 'its thread box is not on that row'
    end
    if not ok then
      wrong[#wrong + 1] = what .. ': ' .. why
    end
  end
  h.eq({}, wrong, mode)
end

local s
h.test('every corpus thread drawn where expected at the PR head (head trust on)', function()
  h.use_fake_gh(h.tmpdir('fce-gh') .. '/calls.ndjson', PRS, nil, threads(HEAD))
  s = h.open_review({ cwd = repo, base = 'main' })
  h.ok(settled(s, HEAD), 'threads did not load')
  check(s, 'at_head')
end)

h.test('after a refetch numbered against another head commit (head trust off)', function()
  h.use_fake_gh(h.tmpdir('fce-gh') .. '/calls.ndjson', PRS, nil, threads(string.rep('f', 40)))
  local _, restore = h.capture_notify()
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys('R', 'mtx', false)
  h.ok(settled(s, string.rep('f', 40)), 'threads did not reload')
  restore()
  check(s, 'no_head')
  view.close()
end)

h.teardown(function()
  if view.session then
    view.close()
  end
end)

h.run()
