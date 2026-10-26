-- Posting reviews to GitHub (forge_post.lua, forge_post_view.lua, the forge.lua mutations and
-- the `ci` / `gP` keys): which comments can be added, where each one lands on GitHub (path, line,
-- startLine, side) and what is refused, routing in full-stack scope, the mutation texts; then
-- real git stacks with a fake `gh` that records every mutation: toggle, confirmation, the
-- pending-review flow (new or the user's own, bound to another commit), partial failures,
-- cancelling, a moved head, the posted state, the refetch, one submit at a time.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('fp-state')
local log_file = h.tmpdir('fp-log') .. '/revuey.log'
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, log_file = log_file })
local forge = require('revuey.forge')
local post = require('revuey.forge_post')
local fpv = require('revuey.forge_post_view')
local view = require('revuey.view')
local log = require('revuey.log')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')

-- ---------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------

local PATCH = table.concat({
  '@@ -1,4 +1,5 @@',
  ' import { multiply, sum } from "./math";',
  '+import { capitalize } from "./utils/strings";',
  ' ',
  ' export interface LineItem {',
  '   name: string;',
  '@@ -17,4 +18,8 @@ export class Cart {',
  '   total(): number {',
  '-    return 0;',
  '+    return sum(this.items);',
  '   }',
  '+',
  '+  names(): string {',
  '+    return "x";',
  '+  }',
  ' }',
  '\\ No newline at end of file',
}, '\n')

h.test('parse_patch: both sides per hunk, CRLF and "no newline" markers', function()
  local P = post.parse_patch(PATCH)
  h.eq(2, #P.hunks)
  h.eq({ 1, ' ', 'import { multiply, sum } from "./math";' }, { P.new[1].hunk, P.new[1].kind, P.new[1].text })
  h.eq({ 1, '+' }, { P.new[2].hunk, P.new[2].kind })
  h.eq(nil, P.new[6], 'between hunks')
  h.eq({ 2, '-', '    return 0;' }, { P.old[18].hunk, P.old[18].kind, P.old[18].text })
  h.eq({ 2, '+', '    return sum(this.items);' }, { P.new[19].hunk, P.new[19].kind, P.new[19].text })
  h.eq({ 2, ' ', '}' }, { P.new[25].hunk, P.new[25].kind, P.new[25].text })
  h.eq(nil, P.new[26], 'the marker is no line')
  h.eq({ [17] = '  total(): number {', [18] = '    return 0;', [19] = '  }', [20] = '}' }, P.hunks[2].old)
  local C = post.parse_patch('@@ -1 +1 @@\r\n-a\r\n+b\r\n')
  h.eq({ 'a', 'b' }, { C.old[1].text, C.new[1].text })
  h.eq({ new = {}, old = {}, hunks = {} }, post.parse_patch(nil))
end)

---A review file and its text for locate(): new side lines `new`, old side `old`, kinds per line.
local function want(o)
  return {
    path = o.path or 'src/cart.ts',
    side = o.side or 'new',
    first = o.first,
    last = o.last or o.first,
    full = o.full,
    file = { path = o.path or 'src/cart.ts', status = o.status or 'M', new_blob = o.blob or 'B1', uncommitted = o.uncommitted },
    line = function(side, l)
      return (side == 'new' and o.new or o.old or {})[l]
    end,
    kind = function(side, l)
      return (o.kinds or {})[side .. l]
    end,
  }
end

local NEW = {}
NEW[1], NEW[2], NEW[3], NEW[4], NEW[5] = 'import { multiply, sum } from "./math";', 'import { capitalize } from "./utils/strings";', '', 'export interface LineItem {', '  name: string;'
NEW[18], NEW[19], NEW[20], NEW[21], NEW[22], NEW[23], NEW[24], NEW[25] = '  total(): number {', '    return sum(this.items);', '  }', '', '  names(): string {', '    return "x";', '  }', '}'
local OLD = { [17] = '  total(): number {', [18] = '    return 0;', [19] = '  }', [20] = '}' }
local PF = { path = 'src/cart.ts', status = 'modified', sha = 'B1', patch = PATCH }

h.test('locate: RIGHT lines and ranges inside one hunk; LEFT lines; a file comment', function()
  h.eq({ kind = 'thread', path = 'src/cart.ts', line = 2, side = 'RIGHT' }, post.locate(want({ first = 2, new = NEW, kinds = { new2 = 'add' } }), PF, 12))
  h.eq({ kind = 'thread', path = 'src/cart.ts', line = 23, side = 'RIGHT', start_line = 21, start_side = 'RIGHT' },
    post.locate(want({ first = 21, last = 23, new = NEW }), PF, 12))
  -- a context line is in the diff too
  h.eq({ kind = 'thread', path = 'src/cart.ts', line = 18, side = 'RIGHT' }, post.locate(want({ first = 18, new = NEW, kinds = { new18 = 'ctx' } }), PF, 12))
  h.eq({ kind = 'thread', path = 'src/cart.ts', line = 18, side = 'LEFT' },
    post.locate(want({ side = 'old', first = 18, old = OLD, kinds = { old18 = 'del' } }), PF, 12))
  h.eq({ kind = 'thread', path = 'src/cart.ts', subject = 'FILE' }, post.locate(want({}), PF, 12))
end)

h.test('locate: refuses another file version, lines outside the diff, two hunks, other text, an earlier layer\'s lines', function()
  local function why(w, pf)
    local item, reason = post.locate(w, pf == nil and PF or pf, 12)
    h.eq(nil, item, vim.inspect(item))
    return reason
  end
  h.ok(why(want({ first = 2, new = NEW, blob = 'OTHER' })):find("src/cart.ts here is not the file at PR #12's head", 1, true))
  h.ok(why(want({ blob = 'OTHER' })):find('not the file at PR #12', 1, true), 'file comments too')
  h.ok(why(want({ first = 2 }), false):find('src/cart.ts is not changed in PR #12', 1, true))
  h.ok(why(want({ first = 10, new = NEW })):find("src/cart.ts:10 (new) is not in PR #12's diff", 1, true))
  h.ok(why(want({ first = 5, last = 18, new = NEW })):find("src/cart.ts:5-18 (new) is not in PR #12's diff", 1, true), 'a gap between hunks')
  -- two hunks that touch (no gap): GitHub still wants a range inside one
  local touching = '@@ -1,2 +1,2 @@\n a\n b\n@@ -3,2 +3,2 @@\n c\n d'
  h.ok(why(want({ first = 2, last = 3, new = { 'a', 'b', 'c', 'd' } }), { path = 'src/cart.ts', status = 'modified', sha = 'B1', patch = touching })
    :find('src/cart.ts:2-3 spans two hunks of PR #12\'s diff', 1, true))
  local new2 = vim.deepcopy(NEW)
  new2[19] = '    return sum(this.items)  ;'
  h.ok(why(want({ first = 19, new = new2 })):find('does not have the text', 1, true))
  -- shown as added in this (full-stack) review, but a context line of this PR: an earlier layer
  h.ok(why(want({ first = 18, new = NEW, kinds = { new18 = 'add' } })):find('was added by an earlier layer, not by PR #12', 1, true))
  h.ok(why(want({ full = true, first = 10, new = NEW, kinds = { new10 = 'add' } })):find('was added by an earlier layer, not by PR #12', 1, true))
  -- not in the PR's diff at all: uncommitted work in a layer scope, else GitHub's base differs
  h.ok(why(want({ side = 'old', first = 10, old = OLD, kinds = { old10 = 'del' }, uncommitted = true }))
    :find('src/cart.ts:10 was deleted by uncommitted work, which is not part of PR #12', 1, true))
  h.ok(why(want({ side = 'old', first = 10, old = OLD, kinds = { old10 = 'del' } }))
    :find("was deleted here but not in PR #12's diff (GitHub's base differs", 1, true))
  h.ok(why(want({ full = true, side = 'old', first = 10, old = OLD, kinds = { old10 = 'del' }, uncommitted = true }))
    :find('was deleted by an earlier layer or by uncommitted work, not by PR #12', 1, true))
  -- LEFT: the PR's base must read as the review's old side over the whole hunk
  local old2 = vim.deepcopy(OLD)
  old2[20] = '} // changed'
  h.ok(why(want({ side = 'old', first = 18, old = old2 })):find("PR #12's base is not the old side shown here", 1, true))
  -- no patch: binary or too large
  h.ok(why(want({ first = 2, new = NEW }), { path = 'src/cart.ts', status = 'modified', sha = 'B1' }):find('GitHub shows no diff', 1, true))
  -- deleted files: a file comment on a removed file
  h.eq({ kind = 'thread', path = 'old.ts', subject = 'FILE' }, post.locate(want({ path = 'old.ts', status = 'D' }), { path = 'old.ts', status = 'removed' }, 12))
end)

h.test('includable: your own saved comments; not AI findings, agents, drafts, resolved, threads, posted ones', function()
  local function c(o)
    return vim.tbl_extend('force', { author = { kind = 'user' }, status = 'saved', body = 'x' }, o)
  end
  h.eq(true, post.includable(c({})))
  h.eq(true, post.includable(c({ status = 'accepted', ai = { title = 't' } })), 'an accepted AI finding is yours')
  h.ok(select(2, post.includable(c({ author = { kind = 'ai', name = 'claude' } }))):find('accept it first', 1, true))
  h.ok(select(2, post.includable(c({ author = { kind = 'agent', name = 'claude' } }))):find('only your own comments', 1, true))
  h.ok(select(2, post.includable(c({ status = 'draft' }))):find('save the draft first', 1, true))
  h.ok(select(2, post.includable(c({ status = 'resolved' }))):find('reopen it first', 1, true))
  h.ok(select(2, post.includable(c({ forge = {} }))):find('GitHub thread already', 1, true))
  h.ok(select(2, post.includable(c({ forge_post = { state = 'posted', pr = 12 } }))):find('already posted to GitHub #12', 1, true))
  h.eq(true, post.includable(c({ forge_post = { state = 'pending', pr = 12 } })), 'pending: still part of the next submit')
  h.eq({ 'approve', 'request_changes', 'request_changes', 'comment', nil }, {
    post.norm_verdict('APPROVE'), post.norm_verdict('request-changes'), post.norm_verdict('changes'), post.norm_verdict('comment'), post.norm_verdict('lgtm') })
end)

---A plan input: comments on cart.ts lines, targets with files and preflight.
local function target(n, o)
  o = o or {}
  local pf
  if o.pf ~= false then
    pf = vim.tbl_extend('force', { id = 'PR_' .. n, state = 'OPEN', head_oid = o.head or o.tip or ('tip' .. n), author = 'alice' }, o.pf or {})
  end
  return {
    pr = { number = n, repo = 'github.com/acme/shop', url = 'https://github.com/acme/shop/pull/' .. n },
    key = o.key or ('layer' .. n),
    tip = o.tip or ('tip' .. n),
    files = o.files,
    pf = pf,
  }
end

local function cmt(id, first, last, o)
  o = o or {}
  return vim.tbl_extend('force', {
    id = id, body = 'body ' .. id, author = { kind = 'user' }, status = 'saved', in_review = true,
    anchor = { path = o.path or 'src/cart.ts', side = o.side or 'new', start_line = first, end_line = last or first },
    file_level = first == nil, thread = {},
  }, o.extra or {})
end

local function plan_input(cs, targets, o)
  o = o or {}
  local kinds = o.kinds or {}
  return {
    comments = cs,
    place = function(c)
      return (o.place or {})[c.id] or { start_line = c.anchor.start_line, end_line = c.anchor.end_line, outdated = false }
    end,
    review = {
      file = function(path)
        return (o.files or { ['src/cart.ts'] = { path = 'src/cart.ts', status = 'M', new_blob = 'B1' } })[path]
      end,
      line = function(_, side, l)
        return (side == 'new' and NEW or OLD)[l]
      end,
      kind = function(_, side, l)
        return kinds[side .. l]
      end,
    },
    targets = targets,
    full = o.full or false,
    verdict = o.verdict or 'comment',
    viewer = o.viewer or 'me',
  }
end

h.test('plan: a layer scope sends each comment to its PR or says why not', function()
  local t = target(12, { files = { PF } })
  local cs = {
    cmt('a', 2), cmt('b', 21, 23), cmt('c', 10), cmt('d', nil),
    cmt('e', 19, 19, { extra = { author = { kind = 'ai', name = 'claude' } } }),
    cmt('f', 2, 2, { extra = { body = '   ' } }),
    cmt('g', 2, 2, { extra = { forge_reply = { thread_id = 'T1', pr = 12, repo = 'github.com/acme/shop' } } }),
    cmt('h', 2, 2, { extra = { forge_reply = { thread_id = 'T9', pr = 99, repo = 'github.com/acme/shop' } } }),
    cmt('i', 19),
  }
  local p = post.plan(plan_input(cs, { t }, { place = { i = { outdated = true } } }))
  local got = {}
  for _, x in ipairs(p.items[t]) do
    got[x.c.id] = x.item
  end
  h.eq({ kind = 'thread', path = 'src/cart.ts', line = 2, side = 'RIGHT', body = 'body a' }, got.a)
  h.eq(21, got.b.start_line)
  h.eq('FILE', got.d.subject)
  h.eq({ kind = 'reply', thread_id = 'T1', body = 'body g' }, got.g)
  local why = {}
  for _, x in ipairs(p.refused) do
    why[x.c.id] = x.why
  end
  h.ok(why.c:find('not in PR #12', 1, true), why.c)
  h.ok(why.e:find('AI review finding', 1, true), why.e)
  h.ok(why.f:find('empty', 1, true), why.f)
  h.ok(why.h:find('PR #99, which is not an open PR of this scope', 1, true), why.h)
  h.ok(why.i:find('outdated', 1, true), why.i)
  h.eq(5, vim.tbl_count(why))
end)

h.test('plan: a whole PR refused (head moved, closed, not found, your own PR with approve)', function()
  local function refused(t, o)
    local p = post.plan(plan_input({ cmt('a', 2) }, { t }, o))
    h.eq(0, #p.items[t])
    return p.refused[1].why
  end
  h.ok(refused(target(12, { files = { PF }, tip = 'aaaaaaa1', head = 'bbbbbbb2' })):find("PR #12's head on GitHub is bbbbbbb, but this review shows aaaaaaa", 1, true))
  h.ok(refused(target(12, { files = { PF }, pf = { state = 'MERGED' } })):find('PR #12 is merged', 1, true))
  h.ok(refused(target(12, { files = { PF }, pf = false })):find('could not be read from GitHub', 1, true))
  h.ok(refused(target(12, { files = { PF }, pf = { author = 'Me' } }), { verdict = 'approve' }):find('PR #12 is yours', 1, true))
  -- a comment review of your own PR is fine
  local t = target(12, { files = { PF }, pf = { author = 'me' } })
  h.eq(1, #post.plan(plan_input({ cmt('a', 2) }, { t })).items[t])
  -- no files: the comment says so
  local t2 = target(12, { files = nil })
  t2.files_err = 'HTTP 500'
  h.ok(post.plan(plan_input({ cmt('a', 2) }, { t2 })).refused[1].why:find('HTTP 500', 1, true))
end)

h.test('plan: full stack routes each line to the PR whose diff adds it, never to a later one', function()
  -- #12 has cart.ts as the old version; #13 has the top's (B1)
  local pf12 = { path = 'src/cart.ts', status = 'added', sha = 'B0', patch = '@@ -0,0 +1,2 @@\n+import { multiply, sum } from "./math";\n+x' }
  local t12 = target(12, { files = { pf12 } })
  local t13 = target(13, { files = { PF } })
  local kinds = { new2 = 'add', new18 = 'add', new19 = 'add', new22 = 'add', new10 = 'add' }
  local p = post.plan(plan_input({ cmt('a', 2), cmt('b', 18), cmt('c', 22), cmt('d', 10) }, { t12, t13 }, { full = true, kinds = kinds }))
  h.eq({ 'a', 'c' }, vim.tbl_map(function(x)
    return x.c.id
  end, p.items[t13]))
  h.eq(0, #p.items[t12])
  local why = {}
  for _, x in ipairs(p.refused) do
    why[x.c.id] = x.why
  end
  h.ok(why.b:find('was added by an earlier layer, not by PR #13', 1, true), why.b)
  h.ok(why.d:find('was added by an earlier layer', 1, true), why.d)
  -- a file no open PR has in this version
  local p2 = post.plan(plan_input({ cmt('m', 1, 1, { path = 'src/math.ts' }) }, { t12, t13 }, {
    full = true, files = { ['src/math.ts'] = { path = 'src/math.ts', status = 'M', new_blob = 'M1' } } }))
  h.ok(p2.refused[1].why:find('no open PR of the stack has src/math.ts as shown here', 1, true), p2.refused[1].why)
  -- two PRs with the same file version and lines: refused as ambiguous
  local t14 = target(14, { files = { PF } })
  local p3 = post.plan(plan_input({ cmt('a', 2) }, { t13, t14 }, { full = true, kinds = kinds }))
  h.ok(p3.refused[1].why:find('fits several PRs of the stack (#13, #14)', 1, true), p3.refused[1].why)
end)

h.test('queries and mutations: preflight, pending review, threads, replies, submit; answers and alias errors', function()
  local q, aliases = forge.build_preflight_query({ { owner = 'acme', name = 'shop', number = 12 } }, { 'PRR_1' })
  h.ok(q:find('viewer { login }', 1, true), q)
  h.ok(q:find('r1: node(id: "PRR_1") { ... on PullRequestReview { ...review } }', 1, true), q)
  h.ok(q:find('p1: repository(owner: "acme", name: "shop") { pullRequest(number: 12) { id number url state isDraft headRefOid author { login } reviews(states: [PENDING], first: 5)', 1, true), q)
  h.ok(q:find('recent: reviews(last: 30) { totalCount nodes { ...review } }', 1, true), q)
  h.ok(q:find('fragment review on PullRequestReview', 1, true) and q:find('id state viewerDidAuthor createdAt body commit { oid }', 1, true), q)
  local viewer, pfs, reviews = forge.normalize_preflight({
    viewer = { login = 'me' },
    r1 = { id = 'PRR_1', state = 'COMMENTED', viewerDidAuthor = true, createdAt = '2026-02-01T00:00:00Z', body = 'B', commit = { oid = 'abc' }, comments = { totalCount = 0, nodes = {} } },
    p1 = { pullRequest = { id = 'PR_12', number = 12, url = 'u', state = 'OPEN', isDraft = false, headRefOid = 'abc', author = { login = 'alice' },
      reviews = { nodes = { { id = 'PRR_9', viewerDidAuthor = true, commit = { oid = 'old' }, comments = { totalCount = 3, nodes = {
        { id = 'C1', fullDatabaseId = '7', path = 'a.ts', line = 4, startLine = vim.NIL, body = 'hi', replyTo = vim.NIL, subjectType = 'LINE' },
      }, pageInfo = { hasNextPage = true, endCursor = 'K1' } } } } },
      recent = { totalCount = 2, nodes = {
        { id = 'PRR_x', state = 'APPROVED', viewerDidAuthor = false, createdAt = '2026-01-05T00:00:00Z', body = '', commit = { oid = 'abc' }, comments = { nodes = {} } },
        { id = 'PRR_y', state = 'COMMENTED', viewerDidAuthor = true, createdAt = '2026-01-06T00:00:00Z', body = 'ok', commit = { oid = 'abc' }, comments = { nodes = {} } },
      } } } },
  }, aliases)
  h.eq('me', viewer)
  h.eq({ 'PR_12', 'abc', 'alice', 'PRR_9', 'old', 3, 'C1', 4 }, { pfs.p1.id, pfs.p1.head_oid, pfs.p1.author, pfs.p1.pending.id, pfs.p1.pending.commit,
    pfs.p1.pending.total, pfs.p1.pending.comments[1].id, pfs.p1.pending.comments[1].line })
  h.eq({ 'COMMENTED', 'B', 'abc' }, { reviews.PRR_1.state, reviews.PRR_1.body, reviews.PRR_1.commit })
  h.eq({ 1, 'PRR_y', true, '2026-01-05T00:00:00Z' }, { #pfs.p1.recent, pfs.p1.recent[1].id, pfs.p1.recent_all, pfs.p1.recent_since })
  h.eq({ '7', 'K1' }, { pfs.p1.pending.comments[1].database_id, pfs.p1.pending.cursor })
  -- a review that is gone: only a NOT_FOUND error says so; any other null is unknown
  local _, gone, rv = forge.normalize_preflight({ viewer = { login = 'me' }, r1 = vim.NIL, p1 = { pullRequest = vim.NIL } }, aliases,
    { { type = 'NOT_FOUND', path = { 'r1' }, message = 'Could not resolve' } })
  h.eq({ {}, { PRR_1 = false } }, { gone, rv })
  local _, _, rv2 = forge.normalize_preflight({ viewer = { login = 'me' }, r1 = vim.NIL }, aliases, { { type = 'FORBIDDEN', path = { 'r1' } } })
  h.eq({}, rv2)
  h.ok(forge.build_pending_page_query('PRR_9', 'K1'):find('q: node(id: "PRR_9") { ... on PullRequestReview { comments(first: 100, after: "K1") {', 1, true))
  -- the pending review: no event, bound to a commit
  h.eq('mutation {\n  r: addPullRequestReview(input: {pullRequestId: "PR_12", commitOID: "abc"}) { pullRequestReview { id commit { oid } } }\n}',
    forge.build_pending_mutation('PR_12', 'abc'))
  local m, al = forge.build_add_mutation('PRR_1', {
    { kind = 'thread', path = 'src/a.ts', body = 'Say "hi"\nok', line = 9, side = 'RIGHT', start_line = 7, start_side = 'RIGHT' },
    { kind = 'thread', path = 'src/a.ts', body = 'one', line = 3, side = 'LEFT' },
    { kind = 'thread', path = 'src/b.ts', body = 'file', subject = 'FILE' },
    { kind = 'reply', thread_id = 'PRRT_5', body = 'reply' },
  })
  h.ok(m:find('m1: addPullRequestReviewThread(input: {pullRequestReviewId: "PRR_1", path: "src/a.ts", body: "Say \\"hi\\"\\nok", line: 9, side: RIGHT, startLine: 7, startSide: RIGHT})', 1, true), m)
  h.ok(m:find('m2: addPullRequestReviewThread(input: {pullRequestReviewId: "PRR_1", path: "src/a.ts", body: "one", line: 3, side: LEFT})', 1, true), m)
  h.ok(m:find('m3: addPullRequestReviewThread(input: {pullRequestReviewId: "PRR_1", path: "src/b.ts", body: "file", subjectType: FILE})', 1, true), m)
  h.ok(m:find('m4: addPullRequestReviewThreadReply(input: {pullRequestReviewId: "PRR_1", pullRequestReviewThreadId: "PRRT_5", body: "reply"}) { comment { id fullDatabaseId url } }', 1, true), m)
  h.eq('PRRT_5', al.m4.thread_id)
  h.eq({ thread_id = 'T', comment_id = 'C', database_id = '3', url = 'u' }, forge.added({ thread = { id = 'T', comments = { nodes = { { id = 'C', fullDatabaseId = '3', url = 'u' } } } } }))
  h.eq({ comment_id = 'C', database_id = '4', url = nil }, forge.added({ comment = { id = 'C', fullDatabaseId = '4' } }))
  h.eq(nil, forge.added(vim.NIL))
  h.eq('bad line; again', forge.alias_error({ { path = { 'm2' }, message = 'bad line' }, { path = { 'm1' }, message = 'x' }, { path = { 'm2', 'thread' }, message = 'again' } }, 'm2'))
  h.eq(nil, forge.alias_error({ { message = 'no path' } }, 'm1'))
  h.eq('mutation {\n  s: submitPullRequestReview(input: {pullRequestReviewId: "PRR_1", event: APPROVE, body: "LGTM"}) { pullRequestReview { id state url } }\n}',
    forge.build_submit_mutation({ review_id = 'PRR_1', event = 'APPROVE', body = 'LGTM' }))
  h.eq('mutation {\n  s: addPullRequestReview(input: {pullRequestId: "PR_12", commitOID: "abc", event: COMMENT}) { pullRequestReview { id state url } }\n}',
    forge.build_submit_mutation({ pr_id = 'PR_12', commit = 'abc', event = 'COMMENT' }))
end)

-- ---------------------------------------------------------------------------
-- Integration: a stack with PRs, a fake gh that records mutations
-- ---------------------------------------------------------------------------

local GH_URL = 'git@github.com:acme/shop.git'

local function stack_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  h.git(d, 'remote', 'add', 'origin', GH_URL)
  return d
end

local function rev(d, r)
  return vim.trim(h.git(d, 'rev-parse', r))
end

---GitHub's files of a PR from `base...head` (REST shape: filename, status, sha, patch).
local function pr_files(d, base, head)
  local out = {}
  local status = { A = 'added', D = 'removed', M = 'modified' }
  for line in h.git(d, 'diff', '--no-renames', '--name-status', base .. '...' .. head):gmatch('[^\n]+') do
    local st, path = line:match('^(%a)%s+(.+)$')
    local patch = h.git(d, 'diff', '-U3', '--no-renames', base .. '...' .. head, '--', path)
    patch = patch:match('\n(@@.*)$'):gsub('\n$', '')
    out[#out + 1] = { filename = path, status = status[st] or 'modified', sha = st ~= 'D' and rev(d, head .. ':' .. path) or nil, patch = patch }
  end
  return out
end

local function pr_node(o)
  return {
    number = o.number, title = 'PR ' .. o.number, url = 'https://github.com/acme/shop/pull/' .. o.number,
    state = 'OPEN', isDraft = false, author = { login = 'alice' }, latestReviews = { nodes = {} },
    reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE', baseRefName = o.base, headRefName = o.head,
    headRepositoryOwner = { login = 'acme' }, headRefOid = o.oid, updatedAt = '2026-01-01T00:00:00Z',
    commits = { nodes = {} },
  }
end

---The fake's GitHub for the stack fixture: #12 (stack/cart) and #13 (stack/ui), heads at the
---local tips. Returns prs, post, threads.
local function github(d, o)
  o = o or {}
  local cart, ui = rev(d, 'stack/cart'), rev(d, 'stack/ui')
  local prs = {
    ['acme/shop:stack/cart'] = { pr_node({ number = 12, head = 'stack/cart', base = 'stack/math', oid = cart }) },
    ['acme/shop:stack/ui'] = { pr_node({ number = 13, head = 'stack/ui', base = 'stack/cart', oid = ui }) },
  }
  local p = {
    viewer = 'me',
    prs = {
      ['acme/shop#12'] = { id = 'PR_12', headRefOid = o.head12 or cart, author = o.author or 'alice' },
      ['acme/shop#13'] = { id = 'PR_13', headRefOid = ui, author = 'alice' },
    },
    files = { ['acme/shop#12'] = pr_files(d, 'stack/math', 'stack/cart'), ['acme/shop#13'] = pr_files(d, 'stack/cart', 'stack/ui') },
    reviews = {},
    fail = o.fail,
  }
  return prs, p, o.threads or {}
end

local function open(dir, opts)
  if view.session then
    view.close()
  end
  local session
  require('revuey').open(vim.tbl_extend('force', { cwd = dir }, opts or {}, {
    on_ready = function(s)
      session = s
    end,
  }))
  assert(vim.wait(10000, function()
    return session ~= nil
  end, 10), 'review did not open')
  return session
end

local function idle(s)
  assert(vim.wait(15000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
      and s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled
  end, 10), 'refresh / PR lookup did not finish')
  vim.wait(50)
end

local function reset()
  forge.cache = {}
  forge.threads_cache = {}
  log.entries = {}
  fpv.job = nil
end

local function row_of(s, path, kind, lnum)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
  error(('no %s row %s:%d'):format(kind, path, lnum))
end

local function file_row(s, path)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.meta == 'file' then
      return row
    end
  end
end

---A saved comment on rows of the review (as `gc` on a selection makes it).
local function add_comment(s, path, kind, first, last, body, extra)
  local rows = {}
  if first == nil then
    local a = comments.file_anchor(path)
    local c = comments.new(a, body)
    for k, v in pairs(extra or {}) do
      c[k] = v
    end
    comments.put(s.cm.store, c)
    comments.save(s.cm.store)
    cv.refresh(s)
    return c
  end
  for l = first, last or first do
    rows[#rows + 1] = s.layout.map[row_of(s, path, kind, l)]
  end
  local a = comments.anchor_from_rows(s.review.files, require('revuey.review').units(s.review), rows, cv.context(s).get_line)
  local c = comments.new(a, body)
  for k, v in pairs(extra or {}) do
    c[k] = v
  end
  comments.put(s.cm.store, c)
  comments.save(s.cm.store)
  cv.refresh(s)
  return c
end

local function keys(s, k, row)
  vim.api.nvim_set_current_win(s.diff_win)
  if row then
    vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  end
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
end

local function vlines(s, row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      local x = {}
      for _, ch in ipairs(l) do
        x[#x + 1] = ch[1]
      end
      out[#out + 1] = table.concat(x)
    end
  end
  return table.concat(out, '\n')
end

local function all_vlines(s)
  local out = {}
  for row = 1, vim.api.nvim_buf_line_count(s.diff_buf) do
    local v = vlines(s, row)
    if v ~= '' then
      out[#out + 1] = row .. ': ' .. v
    end
  end
  return table.concat(out, '\n')
end

local function mutations(calls)
  return h.read_calls(calls .. '.mutations.ndjson')
end

local function ops(calls)
  return vim.tbl_map(function(m)
    return m.op
  end, mutations(calls))
end

local function fake_state(calls)
  return vim.json.decode(table.concat(vim.fn.readfile(calls .. '.post.json'), '\n'))
end

---Answer the confirmation with `answers` (1 submit, 2 body, 3 cancel; in order); records what
---was asked.
local function answer(answers)
  local asked = {}
  fpv.ask = function(msg, choices, default)
    asked[#asked + 1] = { msg = msg, choices = choices, default = default }
    return table.remove(answers, 1) or 0
  end
  return asked
end

local function wait_job()
  assert(vim.wait(20000, function()
    return fpv.job == nil
  end, 10), 'submit did not finish: ' .. vim.inspect(fpv.job and fpv.job.phase) .. vim.inspect(log.entries))
  vim.wait(50)
end

local function get(s, id)
  comments.reload(s.cm.store)
  return comments.get(s.cm.store, id)
end

local function write_state(calls, P)
  vim.fn.writefile({ vim.json.encode(P) }, calls .. '.post.json')
end

local function gh_thread(id, line, cs)
  return {
    id = id, isResolved = false, isOutdated = false, path = 'src/cart.ts', line = line, startLine = vim.NIL, originalLine = line,
    originalStartLine = vim.NIL, diffSide = 'RIGHT', startDiffSide = vim.NIL, subjectType = 'LINE', resolvedBy = vim.NIL,
    comments = cs,
  }
end

local function gh_comment(id, body, who)
  return { id = id, databaseId = 1, url = 'https://github.com/acme/shop/pull/12#discussion_r1', body = body,
    createdAt = '2026-01-01T00:00:00Z', lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = vim.NIL, author = { login = who or 'carol' }, replyTo = vim.NIL }
end

local function setup_review(name, o)
  reset()
  local calls = h.tmpdir('fp-gh-' .. name) .. '/calls.ndjson'
  local d = stack_fixture('fp-' .. name)
  local prs, p, threads = github(d, o)
  if o and o.edit then
    o.edit(p, d)
  end
  h.use_fake_gh(calls, prs, nil, threads, p)
  local s = open(d)
  idle(s)
  return s, calls, d
end

h.test('ci adds a comment to the review and takes it out; refuses AI findings, drafts and GitHub threads', function()
  local s = setup_review('toggle')
  local r19 = row_of(s, 'src/cart.ts', 'add', 18)
  local c = add_comment(s, 'src/cart.ts', 'add', 18, 18, 'Round the total?')
  local msgs, restore = h.capture_notify()
  keys(s, 'ci', r19)
  h.eq(true, get(s, c.id).in_review)
  h.ok(vlines(s, r19):find('· in review', 1, true), vlines(s, r19))
  local list = table.concat(vim.tbl_map(function(l)
    return l.text
  end, cv.list_lines(s)), '\n')
  h.ok(list:find('Round the total?  [in review]', 1, true), list)
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find('gP submit review (1 in review)', 1, true), panel)
  keys(s, 'ci', r19)
  h.eq(false, get(s, c.id).in_review)
  h.ok(not vlines(s, r19):find('in review', 1, true), vlines(s, r19))
  -- an AI finding that is not accepted, and a draft
  local ai = add_comment(s, 'src/cart.ts', 'add', 12, 12, '**Chain**', { author = { kind = 'ai', name = 'claude' }, ai = { title = 'Chain', severity = 'minor' } })
  keys(s, 'ci', row_of(s, 'src/cart.ts', 'add', 12))
  local draft = add_comment(s, 'src/cart.ts', 'add', 5, 5, 'wip', { status = 'draft' })
  keys(s, 'ci', row_of(s, 'src/cart.ts', 'add', 5))
  restore()
  h.eq(false, get(s, ai.id).in_review)
  h.eq(false, get(s, draft.id).in_review)
  h.ok(msgs[1].msg:find('added to the review (1 in review; gP submits)', 1, true), msgs[1].msg)
  h.ok(msgs[2].msg:find('taken out of the review (0 in review', 1, true), msgs[2].msg)
  h.ok(msgs[3].msg:find('AI review finding: accept it first', 1, true), msgs[3].msg)
  h.ok(msgs[4].msg:find('save the draft first', 1, true), msgs[4].msg)
  -- accepted, it is yours
  keys(s, 'ca', row_of(s, 'src/cart.ts', 'add', 12))
  keys(s, 'ci', row_of(s, 'src/cart.ts', 'add', 12))
  h.eq(true, get(s, ai.id).in_review)
  view.close()
end)

h.test('submit: comments, a range, a file comment and a thread reply go into a new pending review, then one submit', function()
  local threads = { ['acme/shop#12'] = { {
    id = 'T_round', isResolved = false, isOutdated = false, path = 'src/cart.ts', line = 18, startLine = vim.NIL, originalLine = 18,
    originalStartLine = vim.NIL, diffSide = 'RIGHT', startDiffSide = vim.NIL, subjectType = 'LINE', resolvedBy = vim.NIL,
    comments = { { id = 'PRRC_x', databaseId = 77, url = 'https://github.com/acme/shop/pull/12#discussion_r77', body = 'Rounded?',
      createdAt = '2026-01-01T00:00:00Z', lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = vim.NIL, author = { login = 'carol' }, replyTo = vim.NIL } },
  } } }
  local s, calls = setup_review('happy', { threads = threads })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local b = add_comment(s, 'src/cart.ts', 'add', 17, 19, 'Name this subtotal.', { in_review = true })
  local f = add_comment(s, 'src/index.ts', nil, nil, nil, 'Needs a test.', { in_review = true })
  local d = add_comment(s, 'src/index.ts', 'del', 8, 8, 'Why does this go?', { in_review = true })
  local r = add_comment(s, 'src/cart.ts', 'add', 18, 18, 'No, see formatCurrency.', {
    in_review = true, forge_reply = { thread_id = 'T_round', pr = 12, repo = 'github.com/acme/shop', comment_id = 'PRRC_x', database_id = 77 } })
  local skipped = add_comment(s, 'src/cart.ts', 'add', 3, 3, 'Not included.')
  local asked = answer({ 1 })
  local msgs, restore = h.capture_notify()
  view.submit('comment')
  wait_job()
  restore()
  -- the confirmation: verdict, the PR, counts and each comment
  h.eq(1, #asked)
  local text = asked[1].msg
  h.ok(text:find('Submit a "Comment" review to GitHub', 1, true), text)
  h.ok(text:find('PR #12 (acme/shop): 4 comments, 1 reply from revuey', 1, true), text)
  h.ok(text:find('+ src/cart.ts:17-19  Name this subtotal.', 1, true), text)
  h.ok(text:find('+ src/index.ts  Needs a test.', 1, true), text)
  h.ok(not text:find('Not included', 1, true) and not text:find('Not posted', 1, true), text)
  h.eq('&Submit\n&Write body\n&Cancel', asked[1].choices)
  -- what went to GitHub, in order
  local m = mutations(calls)
  -- (in the order of the comments list: by file, then line)
  h.eq({ 'addPullRequestReview', 'addPullRequestReviewThread', 'addPullRequestReviewThread', 'addPullRequestReviewThreadReply',
    'addPullRequestReviewThread', 'addPullRequestReviewThread', 'submitPullRequestReview' }, ops(calls))
  h.eq({ pullRequestId = 'PR_12', commitOID = rev(s.review.root, 'stack/cart') }, m[1].input)
  local by_body = {}
  for _, x in ipairs(m) do
    if x.input.body then
      by_body[x.input.body] = x.input
    end
  end
  h.eq({ path = 'src/cart.ts', line = 12, side = 'RIGHT', body = 'Return a copy?', pullRequestReviewId = 'PRR_1' }, by_body['Return a copy?'])
  h.eq({ path = 'src/cart.ts', line = 19, side = 'RIGHT', startLine = 17, startSide = 'RIGHT', body = 'Name this subtotal.', pullRequestReviewId = 'PRR_1' }, by_body['Name this subtotal.'])
  h.eq({ path = 'src/index.ts', subjectType = 'FILE', body = 'Needs a test.', pullRequestReviewId = 'PRR_1' }, by_body['Needs a test.'])
  h.eq({ path = 'src/index.ts', line = 8, side = 'LEFT', body = 'Why does this go?', pullRequestReviewId = 'PRR_1' }, by_body['Why does this go?'])
  h.eq({ pullRequestReviewThreadId = 'T_round', body = 'No, see formatCurrency.', pullRequestReviewId = 'PRR_1' }, by_body['No, see formatCurrency.'])
  h.eq({ pullRequestReviewId = 'PRR_1', event = 'COMMENT' }, m[#m].input)
  h.ok(msgs[#msgs].msg:find('Comment review submitted to #12', 1, true), vim.inspect(msgs))
  -- posted: kept with their GitHub ids, out of the review
  for _, c in ipairs({ a, b, f, d, r }) do
    local x = get(s, c.id)
    h.eq({ 'posted', 12, false }, { x.forge_post.state, x.forge_post.pr, x.in_review })
    h.ok(x.forge_post.comment_id and x.forge_post.review_id == 'PRR_1', vim.inspect(x.forge_post))
  end
  h.eq(nil, get(s, skipped.id).forge_post)
  -- the refetch drew them as GitHub threads; the local copies are not drawn twice
  idle(s)
  local all = all_vlines(s)
  local _, n = all:gsub('Return a copy%?', '')
  h.eq(1, n, all)
  h.ok(vlines(s, row_of(s, 'src/cart.ts', 'add', 12)):find('GitHub #12', 1, true), all)
  local _, nr = all:gsub('No, see formatCurrency', '')
  h.eq(1, nr, all)
  h.ok(not all:find('posted to GitHub', 1, true), 'shown as GitHub threads: ' .. all)
  local list = table.concat(vim.tbl_map(function(l)
    return l.text
  end, cv.list_lines(s)), '\n')
  local _, nl = list:gsub('Return a copy%?', '')
  h.eq(1, nl, list)
  -- with GitHub threads hidden, the posted comment is drawn locally, marked posted
  keys(s, 'gH')
  keys(s, 'gH')
  h.ok(vlines(s, row_of(s, 'src/cart.ts', 'add', 12)):find('posted to GitHub #12', 1, true), all_vlines(s))
  -- a posted comment cannot be added again
  msgs, restore = h.capture_notify()
  keys(s, 'ci', row_of(s, 'src/cart.ts', 'add', 12))
  restore()
  h.ok(msgs[1].msg:find('already posted to GitHub #12', 1, true), vim.inspect(msgs))
  view.close()
end)

h.test('an existing pending review (from another tool) is reused and listed; theirs are submitted too, never deleted', function()
  local s, calls = setup_review('pending', { edit = function(p, d)
    p.prs['acme/shop#12'].pending = { id = 'PRR_graphite', commit = rev(d, 'stack/cart'), comments = {
      { id = 'PRRC_g1', databaseId = 901, path = 'src/cart.ts', line = 3, body = 'From Graphite: rename LineItem?' },
      { id = 'PRRC_g2', databaseId = 902, path = 'src/index.ts', line = 9, startLine = 8, body = 'From Graphite: inline this.' },
    } }
    p.reviews.PRR_graphite = 'PENDING'
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  local text = asked[1].msg
  h.ok(text:find('Submit a "Approve" review', 1, true), text)
  h.ok(text:find('PR #12 (acme/shop): 1 comment from revuey', 1, true), text)
  h.ok(text:find('Your pending review on GitHub already has 2 comments from elsewhere; they are submitted too:', 1, true), text)
  h.ok(text:find('    src/cart.ts:3', 1, true) and text:find('    src/index.ts:8-9', 1, true), text)
  h.ok(not text:find('bound to commit', 1, true), text)
  -- no second pending review; the thread went into theirs; submitted with the verdict
  h.eq({ 'addPullRequestReviewThread', 'submitPullRequestReview' }, ops(calls))
  local m = mutations(calls)
  h.eq('PRR_graphite', m[1].input.pullRequestReviewId)
  h.eq({ pullRequestReviewId = 'PRR_graphite', event = 'APPROVE' }, m[2].input)
  h.eq('APPROVED', fake_state(calls).reviews.PRR_graphite)
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('the same text elsewhere in the pending review is not this comment: a nit on another line is added', function()
  local s, calls = setup_review('samebody', { edit = function(p, d)
    p.prs['acme/shop#12'].pending = { id = 'PRR_g', commit = rev(d, 'stack/cart'), comments = {
      { id = 'PRRC_g', databaseId = 70, path = 'src/cart.ts', line = 3, body = 'nit' } } }
    p.reviews.PRR_g = 'PENDING'
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'nit', { in_review = true })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  local text = asked[1].msg
  h.ok(text:find('+ src/cart.ts:12  nit', 1, true) and not text:find('in your pending review already', 1, true), text)
  h.ok(text:find('already has 1 comment from elsewhere', 1, true) and text:find('    src/cart.ts:3', 1, true), text)
  h.eq({ 'addPullRequestReviewThread', 'submitPullRequestReview' }, ops(calls))
  h.eq({ line = 12, body = 'nit' }, { line = mutations(calls)[1].input.line, body = mutations(calls)[1].input.body })
  h.ok(get(s, a.id).forge_post.comment_id ~= 'PRRC_g', 'not given Graphite\'s comment')
  view.close()
end)

h.test('a reply with the same text in another thread of the pending review is not this reply', function()
  local threads = { ['acme/shop#12'] = {
    gh_thread('T_a', 18, { gh_comment('PRRC_a', 'Rounded?') }),
    gh_thread('T_b', 13, { gh_comment('PRRC_b', 'Copy?') }),
  } }
  local s, calls = setup_review('replies', { threads = threads, edit = function(p, d)
    p.prs['acme/shop#12'].pending = { id = 'PRR_g', commit = rev(d, 'stack/cart'), comments = {
      { id = 'PRRC_gr', databaseId = 71, path = 'src/cart.ts', line = 13, body = 'Done', replyTo = { id = 'PRRC_b' } } } }
    p.reviews.PRR_g = 'PENDING'
  end })
  add_comment(s, 'src/cart.ts', 'add', 18, 18, 'Done', {
    in_review = true, forge_reply = { thread_id = 'T_a', pr = 12, repo = 'github.com/acme/shop', comment_id = 'PRRC_a' } })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.ok(asked[1].msg:find('1 reply from revuey', 1, true) and asked[1].msg:find('src/cart.ts:13 (reply)', 1, true), asked[1].msg)
  h.eq({ 'addPullRequestReviewThreadReply', 'submitPullRequestReview' }, ops(calls))
  h.eq('T_a', mutations(calls)[1].input.pullRequestReviewThreadId)
  view.close()
end)

h.test('closing the body editor without changes (:q) goes back to the confirmation; the submit is never held', function()
  local s = setup_review('bodyq')
  local asked = answer({ 1 }) -- Write body
  view.submit('comment')
  assert(vim.wait(10000, function()
    return require('revuey.comment_editor').current ~= nil
  end, 10), 'editor opened')
  answer({ 2 }) -- then Cancel
  vim.api.nvim_win_close(require('revuey.comment_editor').current.win, true)
  wait_job()
  h.eq(nil, fpv.job)
  h.eq(1, #asked)
  view.close()
end)

h.test('a long pending review is read page by page: a recorded comment past the first page is found, not added again', function()
  local saved = forge.PENDING_COMMENTS
  forge.PENDING_COMMENTS = 2
  local s, calls = setup_review('paged', { edit = function(p, d)
    p.prs['acme/shop#12'].pending = { id = 'PRR_g', commit = rev(d, 'stack/cart'), comments = {
      { id = 'G1', databaseId = 1, path = 'src/cart.ts', line = 3, body = 'one' },
      { id = 'G2', databaseId = 2, path = 'src/cart.ts', line = 4, body = 'two' },
      { id = 'G3', databaseId = 3, path = 'src/cart.ts', line = 5, body = 'three' },
      { id = 'MINE', databaseId = 4, path = 'src/cart.ts', line = 12, body = 'Return a copy?' },
    } }
    p.reviews.PRR_g = 'PENDING'
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true,
    forge_post = { state = 'pending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_g', comment_id = 'MINE' } })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  forge.PENDING_COMMENTS = saved
  h.ok(asked[1].msg:find('(in your pending review already)', 1, true), asked[1].msg)
  h.ok(asked[1].msg:find('already has 3 comments from elsewhere', 1, true) and asked[1].msg:find('src/cart.ts:5', 1, true), asked[1].msg)
  h.eq({ 'submitPullRequestReview' }, ops(calls))
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('a posted comment with local replies stays visible (collapsed) next to its GitHub thread', function()
  local s, calls = setup_review('replies2')
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  comments.reply(s.cm.store, a.id, 'Agent: done in abc123.', { kind = 'agent', name = 'claude' })
  comments.save(s.cm.store)
  answer({ 1 })
  view.submit('comment')
  wait_job()
  idle(s)
  local all = all_vlines(s)
  h.ok(all:find('posted to GitHub #12', 1, true), all)
  h.ok(all:find('GitHub #12', 1, true) and all:find('more line', 1, true), all)
  view.close()
end)

h.test('the PR head moved (or unpushed commits): nothing is added or submitted, the reason is shown', function()
  local s, calls = setup_review('moved', { head12 = 'f00dfeedf00dfeedf00dfeedf00dfeedf00dfeed' })
  add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 1 })
  local msgs, restore = h.capture_notify()
  view.submit('approve')
  wait_job()
  restore()
  h.eq(0, #asked, 'no confirmation: nothing to submit')
  h.eq({}, ops(calls))
  local last = msgs[#msgs].msg
  h.ok(last:find('nothing to submit', 1, true) and last:find("PR #12's head on GitHub is f00dfee, but this review shows", 1, true), last)
end)

h.test('a body: written from the confirmation; a Comment review with nothing in it needs one', function()
  local s, calls = setup_review('body')
  local asked = answer({ 1 }) -- "Write body" is the first choice here
  view.submit('comment')
  assert(vim.wait(10000, function()
    return require('revuey.comment_editor').current ~= nil
  end, 10), 'editor opened')
  h.ok(asked[1].msg:find('needs a body', 1, true), asked[1].msg)
  h.eq('&Write body\n&Cancel', asked[1].choices)
  local ed = require('revuey.comment_editor').current
  vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { 'Looks good overall.' })
  table.insert(asked, 0) -- placeholder
  fpv.ask = function(msg, choices)
    asked[#asked + 1] = { msg = msg, choices = choices }
    return 1
  end
  require('revuey.comment_editor').save()
  wait_job()
  h.ok(asked[#asked].msg:find('with a body', 1, true), asked[#asked].msg)
  h.eq('&Submit\n&Edit body\n&Cancel', asked[#asked].choices)
  h.eq({ { op = 'addPullRequestReview', alias = 's', input = { pullRequestId = 'PR_12', commitOID = rev(s.review.root, 'stack/cart'), event = 'COMMENT', body = 'Looks good overall.' } } },
    mutations(calls))
  view.close()
end)

h.test('failures reading GitHub: files and preflight errors say so and post nothing', function()
  local s, calls = setup_review('readfail', { fail = { preflight = true } })
  add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local msgs, restore = h.capture_notify()
  view.submit('comment')
  wait_job()
  restore()
  h.ok(msgs[#msgs].msg:find('could not read the pull requests from GitHub', 1, true), vim.inspect(msgs))
  h.eq({}, ops(calls))
  view.close()
  s, calls = setup_review('filesfail', { fail = { files = true } })
  add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 2 })
  msgs, restore = h.capture_notify()
  view.submit('comment')
  wait_job()
  restore()
  -- nothing can be located: no review for a Comment verdict with nothing in it but a body needed
  h.ok(asked[1].msg:find("could not read PR #12's files from GitHub", 1, true), asked[1].msg)
  h.eq({}, ops(calls))
  view.close()
end)

-- ---------------------------------------------------------------------------
-- Unit: reconcile, the atomic review, its mutation
-- ---------------------------------------------------------------------------

h.test('payload_matches and reconcile: by id first; payloads only when told apart, unclaimed and new; else unknown', function()
  local pool = {
    { id = 'G1', path = 'src/cart.ts', line = 3, body = 'nit' },
    { id = 'C1', path = 'src/cart.ts', line = 12, body = 'nit\r\n' },
    { id = 'C2', path = 'src/cart.ts', line = 12, start_line = 10, body = 'range' },
    { id = 'C3', path = 'src/cart.ts', body = 'file', subject = 'FILE' },
    { id = 'R9', path = 'src/cart.ts', line = 18, body = 'Done', reply_to = 'X_other' },
    { id = 'R1', path = 'src/cart.ts', line = 18, body = 'Done', reply_to = 'X1' },
  }
  local function p(o)
    return vim.tbl_extend('force', { kind = 'thread', path = 'src/cart.ts' }, o)
  end
  h.ok(post.payload_matches(pool[2], p({ body = 'nit', line = 12 })))
  h.ok(not post.payload_matches(pool[2], p({ body = 'nit', line = 40 })), 'another line')
  h.ok(not post.payload_matches(pool[3], p({ body = 'range', line = 12 })), 'another start')
  h.ok(post.payload_matches(pool[4], p({ body = 'file', subject = 'FILE' })))
  h.ok(post.payload_matches(pool[6], { kind = 'reply', body = 'Done' }, { X1 = true }))
  h.ok(not post.payload_matches(pool[5], { kind = 'reply', body = 'Done' }, { X1 = true }), 'another thread')
  h.ok(not post.payload_matches(pool[6], p({ body = 'Done', line = 18 })), 'a reply is no thread')
  local res = post.reconcile({
    { key = 'byid', id = 'C3', pool = pool, complete = true },
    { key = 'found', payload = p({ body = 'nit', line = 12 }), pool = pool, complete = true },
    { key = 'absent', payload = p({ body = 'other', line = 5 }), pool = pool, complete = true },
    { key = 'partial', payload = p({ body = 'other', line = 5 }), pool = pool, complete = false },
    { key = 'gone', payload = p({ body = 'nit', line = 12 }), gone = true },
    { key = 'unread', payload = p({ body = 'nit', line = 12 }) },
    { key = 'idgone', id = 'C9', pool = pool, complete = true },
    { key = 'idpartial', id = 'C9', pool = pool, complete = false },
    { key = 'claimed', payload = p({ body = 'file', subject = 'FILE' }), pool = pool, complete = true },
    { key = 'before', payload = p({ body = 'nit', line = 3 }), pool = pool, complete = true, before = { G1 = true } },
  })
  h.eq('C3', res.byid.found.id)
  h.eq('C1', res.found.found.id)
  h.eq({ absent = true }, res.absent)
  h.ok(res.partial.unknown, 'a partial read never proves absence')
  h.eq({ absent = true }, res.gone)
  h.ok(res.unread.unknown)
  h.eq({ absent = true }, res.idgone)
  h.ok(res.idpartial.unknown)
  h.ok(res.claimed.unknown, 'C3 is the recorded one of another comment')
  h.ok(res.before.unknown, 'G1 was there before: never ours')
  -- two payloads one comment matches (no side on GitHub's comments): both unknown
  local two = post.reconcile({
    { key = 'L', payload = p({ body = 'nit', line = 12, side = 'LEFT' }), pool = pool, complete = true },
    { key = 'R', payload = p({ body = 'nit', line = 12, side = 'RIGHT' }), pool = pool, complete = true },
  })
  h.ok(two.L.unknown and two.R.unknown, vim.inspect(two))
end)

h.test('find_atomic: the viewer\'s review with that commit, verdict and body, made after it was sent; else absent or unknown', function()
  local t0 = os.time({ year = 2026, month = 2, day = 1, hour = 12 })
  local e = { commit = 'abc', event = 'APPROVE', body = 'LGTM', started_at = t0 }
  local function rv(o)
    return vim.tbl_extend('force', { id = 'R', mine = true, commit = 'abc', state = 'APPROVED', body = 'LGTM', created_at = post.iso(t0 + 5), comments = {} }, o)
  end
  h.eq('R', post.find_atomic(e, { recent_read = true, recent_all = true, recent = { rv({}) } }).found.id)
  h.eq({ absent = true }, post.find_atomic(e, { recent_read = true, recent_all = true, recent = { rv({ body = 'other' }) } }))
  h.eq({ absent = true }, post.find_atomic(e, { recent_read = true, recent_all = true, recent = { rv({ created_at = post.iso(t0 - 3600) }) } }))
  h.ok(post.find_atomic(e, { recent_read = true, recent_all = false, recent_since = post.iso(t0), recent = {} }).unknown, 'older reviews not read')
  h.eq({ absent = true }, post.find_atomic(e, { recent_read = true, recent_all = false, recent_since = post.iso(t0 - 7200), recent = {} }))
  h.ok(post.find_atomic(e, { recent_read = true, recent_all = true, recent = { rv({}), rv({ id = 'R2' }) } }).unknown, 'two candidates')
  h.ok(post.find_atomic(e, nil).unknown)
end)

h.test('the atomic mutation: event, body and every thread in one addPullRequestReview', function()
  local m = forge.build_atomic_mutation({ pr_id = 'PR_12', commit = 'abc', event = 'APPROVE', body = 'LGTM', threads = {
    { path = 'a.ts', line = 9, side = 'RIGHT', start_line = 7, start_side = 'RIGHT', body = 'x "y"' },
    { path = 'b.ts', line = 3, side = 'LEFT', body = 'z' },
  } })
  h.ok(m:find('s: addPullRequestReview(input: {pullRequestId: "PR_12", commitOID: "abc", event: APPROVE, body: "LGTM", threads: [{path: "a.ts", line: 9, side: RIGHT, startLine: 7, startSide: RIGHT, body: "x \\"y\\""}, {path: "b.ts", line: 3, side: LEFT, body: "z"}]})', 1, true), m)
  h.ok(m:find('fragment pcomment on PullRequestReviewComment', 1, true), m)
  h.ok(not forge.build_atomic_mutation({ pr_id = 'P', commit = 'c', event = 'COMMENT', threads = {} }):find('threads:', 1, true))
end)

-- ---------------------------------------------------------------------------
-- Integration: preview first, atomic when possible, write-ahead, reconcile
-- ---------------------------------------------------------------------------

local function M_ledger(s)
  return fpv.ledger_read(s.cm.store).reviews
end

---Pending review on #12 bound to the reviewed head, with `cs` from elsewhere.
local function graphite(cs)
  return function(p, d)
    p.prs['acme/shop#12'].pending = { id = 'PRR_g', commit = rev(d, 'stack/cart'), comments = cs or {
      { id = 'G1', databaseId = 1, path = 'src/cart.ts', line = 3, body = 'From Graphite.' } } }
    p.reviews.PRR_g = 'PENDING'
  end
end

local function pending_ids(calls)
  local P = fake_state(calls)
  local pr = P.prs['acme/shop#12']
  local out = {}
  for _, c in ipairs(pr.pending and pr.pending.comments or {}) do
    out[#out + 1] = c.body
  end
  return out
end

local function history(calls, key)
  return fake_state(calls).prs[key or 'acme/shop#12'].history or {}
end

h.test('preview first: nothing is sent before the confirmation; Cancel leaves GitHub untouched', function()
  local s, calls = setup_review('preview', { edit = graphite() })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 3 })
  view.submit('comment')
  wait_job()
  h.eq(1, #asked)
  h.ok(asked[1].msg:find('+ src/cart.ts:12  Return a copy?', 1, true), asked[1].msg)
  h.ok(asked[1].msg:find('added to your pending review on GitHub, then submitted', 1, true), asked[1].msg)
  h.eq({}, ops(calls))
  h.eq({ nil, true }, { get(s, a.id).forge_post, get(s, a.id).in_review })
  h.eq({ 'From Graphite.' }, pending_ids(calls))
  view.close()
end)

h.test('atomic: no pending review, line comments only: one addPullRequestReview with the event and the threads', function()
  local s, calls = setup_review('atomic')
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'nit: typo', { in_review = true })
  local b = add_comment(s, 'src/cart.ts', 'add', 17, 19, 'nit: typo', { in_review = true })
  local c = add_comment(s, 'src/index.ts', 'del', 8, 8, 'Why?', { in_review = true })
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  h.ok(asked[1].msg:find('a new review, created and submitted in one step', 1, true), asked[1].msg)
  local m = mutations(calls)
  h.eq({ 'addPullRequestReview' }, ops(calls))
  h.eq({ 'APPROVE', rev(s.review.root, 'stack/cart'), 3 }, { m[1].input.event, m[1].input.commitOID, #m[1].input.threads })
  h.eq({ path = 'src/cart.ts', line = 19, side = 'RIGHT', startLine = 17, startSide = 'RIGHT', body = 'nit: typo' }, m[1].input.threads[2])
  h.eq({ path = 'src/index.ts', line = 8, side = 'LEFT', body = 'Why?' }, m[1].input.threads[3])
  local ids = {}
  for _, x in ipairs({ a, b, c }) do
    local fp = get(s, x.id).forge_post
    h.eq({ 'posted', false }, { fp.state, get(s, x.id).in_review })
    h.ok(fp.comment_id and not ids[fp.comment_id], 'its own GitHub comment')
    ids[fp.comment_id] = true
  end
  h.eq({}, M_ledger(s))
  view.close()
end)

h.test('a crash between the write-ahead and the answer: the record survives; the next submit finds it absent and adds it once', function()
  local s, calls = setup_review('crash', { edit = graphite() })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local real = forge.run_graphql
  forge.run_graphql = function(q, ...)
    if q:find('addPullRequestReviewThread(', 1, true) then
      error('Neovim was killed')
    end
    return real(q, ...)
  end
  answer({ 1 })
  view.submit('comment')
  wait_job()
  forge.run_graphql = real
  -- what was on disk when it "crashed"
  local store = comments.load(s.cm.path)
  local fp = comments.get(store, a.id).forge_post
  h.eq({ 'sending', 'PRR_g', 'Return a copy?', 12 }, { fp.state, fp.review_id, fp.payload.body, fp.payload.line })
  h.eq({}, ops(calls))
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.ok(asked[1].msg:find('+ src/cart.ts:12  Return a copy?', 1, true), asked[1].msg)
  h.eq({ 'addPullRequestReviewThread', 'submitPullRequestReview' }, ops(calls))
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('R6: an add with no answer that GitHub applies late is found once by the next submit, never added twice', function()
  local s, calls = setup_review('r6', { edit = graphite() })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local real = forge.run_graphql
  local late
  forge.run_graphql = function(q, host, on_job)
    if q:find('addPullRequestReviewThread(', 1, true) and not late then
      late = q
      return nil, 'gh timed out after 15s', {}
    end
    return real(q, host, on_job)
  end
  local msgs, restore = h.capture_notify()
  answer({ 1 })
  view.submit('approve')
  wait_job()
  restore()
  h.ok(msgs[#msgs].msg:find('GitHub did not answer while adding comments', 1, true) and msgs[#msgs].msg:find('not submitted', 1, true), vim.inspect(msgs))
  h.eq({}, ops(calls), 'no submit')
  h.eq('sending', get(s, a.id).forge_post.state)
  real(late) -- GitHub applies it late
  forge.run_graphql = real
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  h.ok(asked[1].msg:find('= src/cart.ts:12  Return a copy? (in your pending review already)', 1, true), asked[1].msg)
  h.eq({ 'addPullRequestReviewThread', 'submitPullRequestReview' }, ops(calls), 'the late add, then only the submit')
  local hist = history(calls)
  h.eq(2, #hist[#hist].comments, 'Graphite\'s and ours, once')
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('R2/R7: a record is matched by what was sent, not the comment now: edited, or now refused, it is still the one there', function()
  local s, calls, d = setup_review('r2', { edit = graphite(), fail = { lost = { 'Return a copy' } } })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  answer({ 1 })
  view.submit('approve')
  wait_job()
  h.eq('sending', get(s, a.id).forge_post.state)
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  -- edited here, and its file changed locally (the plan would refuse it now)
  local c = get(s, a.id)
  c.body = 'Return a frozen copy?'
  comments.put(s.cm.store, c)
  comments.save(s.cm.store)
  h.write(d, 'src/cart.ts', table.concat(vim.fn.readfile(d .. '/src/cart.ts'), '\n') .. '\n// local\n')
  view.refresh({ force = true })
  idle(s)
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  local text = asked[1].msg
  h.ok(text:find('= src/cart.ts:12  Return a frozen copy? (in your pending review, edited here since: GitHub has "Return a copy?")', 1, true), text)
  h.ok(not text:find('Not posted', 1, true) and not text:find('+ src/cart.ts', 1, true), text)
  h.eq({ 'addPullRequestReviewThread', 'submitPullRequestReview' }, ops(calls))
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('R3/R4: a pending review that cannot be read whole blocks its PR: no Submit, nothing sent', function()
  local saved = forge.PENDING_COMMENTS
  forge.PENDING_COMMENTS = 1
  local s, calls = setup_review('r3', { edit = function(p, d)
    graphite({ { id = 'G1', databaseId = 1, path = 'src/cart.ts', line = 3, body = 'one' },
      { id = 'MINE', databaseId = 4, path = 'src/cart.ts', line = 12, body = 'Return a copy?' } })(p, d)
    p.fail = { pages = true }
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true,
    forge_post = { state = 'pending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_g', comment_id = 'MINE' } })
  local b = add_comment(s, 'src/cart.ts', 'add', 13, 13, 'Lost one.', { in_review = true,
    forge_post = { state = 'sending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_g', sent_at = 1,
      payload = { kind = 'thread', path = 'src/cart.ts', line = 13, side = 'RIGHT', body = 'Lost one.' } } })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  forge.PENDING_COMMENTS = saved
  h.eq('&Cancel', asked[1].choices)
  h.ok(asked[1].msg:find('BLOCKED, not submitted: your pending review on GitHub could not be read whole', 1, true), asked[1].msg)
  h.ok(asked[1].msg:find('? src/cart.ts:13  Lost one. (sent earlier, GitHub did not answer: it may be there)', 1, true), asked[1].msg)
  h.eq({}, ops(calls))
  h.eq({ 'pending', 'unknown' }, { get(s, a.id).forge_post.state, get(s, b.id).forge_post.state })
  local v = vlines(s, row_of(s, 'src/cart.ts', 'add', 13))
  h.ok(v:find('maybe on GitHub #12 (unconfirmed)', 1, true), v)
  view.close()
end)

h.test('R1: a PR that comes back null (not NOT_FOUND) never makes revuey forget a pending record', function()
  local s, calls = setup_review('r1', { edit = function(p, d)
    graphite({ { id = 'MINE', databaseId = 4, path = 'src/cart.ts', line = 12, body = 'Return a copy?' } })(p, d)
    p.fail = { pr_null = true }
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true,
    forge_post = { state = 'pending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_g', comment_id = 'MINE' } })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.eq({}, ops(calls))
  h.eq('pending', get(s, a.id).forge_post.state)
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.ok(asked[#asked].msg:find('(in your pending review already)', 1, true), asked[#asked].msg)
  h.eq({ 'submitPullRequestReview' }, ops(calls))
  view.close()
end)

h.test('R5: unknown, then ci off: found absent at the next reconcile, dropped, not added', function()
  local s, calls = setup_review('r5', { edit = graphite() })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = false,
    forge_post = { state = 'unknown', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_g', sent_at = 1,
      payload = { kind = 'thread', path = 'src/cart.ts', line = 12, side = 'RIGHT', body = 'Return a copy?' } } })
  answer({ 1 })
  view.submit('approve')
  wait_job()
  h.eq({ 'submitPullRequestReview' }, ops(calls), 'Graphite\'s review submitted; ours not added')
  h.eq({ nil, false }, { get(s, a.id).forge_post, get(s, a.id).in_review })
  view.close()
end)

h.test('R8: LEFT and RIGHT with the same text on one line number, one answer lost: both unknown, the PR blocked', function()
  local s, calls = setup_review('r8', { edit = graphite(), fail = { lost = { 'nit' }, add_side = { 'LEFT' } } })
  local l = add_comment(s, 'src/index.ts', 'del', 8, 8, 'nit', { in_review = true })
  local r = add_comment(s, 'src/index.ts', 'add', 8, 8, 'nit', { in_review = true })
  answer({ 1 })
  view.submit('approve')
  wait_job()
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  h.eq('&Cancel', asked[1].choices)
  h.ok(asked[1].msg:find('GitHub has comments it cannot be told apart from', 1, true), asked[1].msg)
  h.eq({ 'unknown', 'unknown' }, { get(s, l.id).forge_post.state, get(s, r.id).forge_post.state })
  h.eq({ 'addPullRequestReviewThread', 'addPullRequestReviewThread' }, ops(calls), 'nothing more')
  -- the way out: forget one, with a warning
  local msgs, restore = h.capture_notify()
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of(s, 'src/index.ts', 'del', 8), 0 })
  vim.cmd('RevueySubmit forget')
  restore()
  h.ok(msgs[1].msg:find('it may exist on GitHub', 1, true) and msgs[1].level == vim.log.levels.WARN, vim.inspect(msgs))
  h.eq(nil, get(s, l.id).forge_post)
  view.close()
end)

h.test('a Graphite comment with the same text as a lost add is never claimed: unknown, blocked', function()
  local s, calls = setup_review('graphitetwin', { edit = function(p, d)
    graphite({ { id = 'G12', databaseId = 1, path = 'src/cart.ts', line = 12, body = 'Return a copy?' } })(p, d)
    p.fail = { lost_unapplied = { 'Return a copy' } }
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  answer({ 1 })
  view.submit('comment')
  wait_job()
  h.eq({ 'G12' }, get(s, a.id).forge_post.before)
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.eq('&Cancel', asked[1].choices)
  h.eq('unknown', get(s, a.id).forge_post.state)
  h.ok(get(s, a.id).forge_post.comment_id == nil, 'Graphite\'s comment is not ours')
  view.close()
end)

h.test('a lost atomic review: found among the PR\'s reviews by the next submit (posted, no second review)', function()
  local s, calls = setup_review('atomlost', { fail = { lost = { 'Return a copy' } } })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local msgs, restore = h.capture_notify()
  answer({ 1 })
  view.submit('approve')
  wait_job()
  restore()
  h.eq('sending', get(s, a.id).forge_post.state)
  h.eq(1, vim.tbl_count(M_ledger(s)))
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  h.eq({ 'addPullRequestReview' }, ops(calls), 'never a second review')
  h.eq('posted', get(s, a.id).forge_post.state)
  h.ok(get(s, a.id).forge_post.comment_id, 'with its id')
  h.eq({}, M_ledger(s))
  h.eq(0, #asked, 'nothing left to submit')
  view.close()
end)

h.test('a lost atomic review GitHub never made: proven absent by the next submit, sent once', function()
  local s, calls = setup_review('atomnot', { fail = { lost_unapplied = { 'Return a copy' } } })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  answer({ 1 })
  view.submit('approve')
  wait_job()
  h.eq('sending', get(s, a.id).forge_post.state)
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  h.ok(asked[1].msg:find('+ src/cart.ts:12  Return a copy?', 1, true), asked[1].msg)
  h.eq({ 'addPullRequestReview', 'addPullRequestReview' }, ops(calls))
  h.eq(1, #history(calls))
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('a verdict alone with no answer, retried: found, never a second review', function()
  local s, calls = setup_review('verdictlost', { fail = { lost = { 'APPROVE' } } })
  answer({ 1 })
  view.submit('approve')
  wait_job()
  h.eq(1, vim.tbl_count(M_ledger(s)))
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  local asked = answer({ 1 })
  local msgs, restore = h.capture_notify()
  view.submit('approve')
  wait_job()
  restore()
  h.eq(0, #asked, 'nothing left to submit')
  h.ok(msgs[#msgs].msg:find('the Approve review sent earlier without an answer was made after all', 1, true), vim.inspect(msgs))
  h.eq({ 'addPullRequestReview' }, ops(calls), 'no second one')
  h.eq({}, M_ledger(s))
  h.eq(1, #history(calls))
  view.close()
end)

h.test('pending flow: partial failure stays unsubmitted; what went in is pending; the next submit adds the rest', function()
  local s, calls = setup_review('partial', { edit = graphite(), fail = { add = { 'BAD' } } })
  local good = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local bad = add_comment(s, 'src/cart.ts', 'add', 13, 13, 'BAD one', { in_review = true })
  local msgs, restore = h.capture_notify()
  answer({ 1 })
  view.submit('comment')
  wait_job()
  restore()
  h.ok(msgs[#msgs].msg:find('1 comment was refused by GitHub; not submitted', 1, true), vim.inspect(msgs))
  h.eq({ 'addPullRequestReviewThread', 'addPullRequestReviewThread' }, ops(calls))
  h.eq({ 'pending', nil, true }, { get(s, good.id).forge_post.state, get(s, bad.id).forge_post, get(s, bad.id).in_review })
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.ok(asked[1].msg:find('= src/cart.ts:12', 1, true) and asked[1].msg:find('+ src/cart.ts:13  BAD one', 1, true), asked[1].msg)
  h.eq('submitPullRequestReview', ops(calls)[#ops(calls)])
  h.eq({ 'posted', 'posted' }, { get(s, good.id).forge_post.state, get(s, bad.id).forge_post.state })
  view.close()
end)

h.test('atomic refused by GitHub: nothing was made; the records are dropped and the comments stay in the review', function()
  local s, calls = setup_review('atomrefused', { fail = { add = { 'BAD' } } })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'BAD one', { in_review = true })
  local msgs, restore = h.capture_notify()
  answer({ 1 })
  view.submit('comment')
  wait_job()
  restore()
  h.ok(msgs[#msgs].msg:find('PR #12: Review cannot be submitted', 1, true), vim.inspect(msgs))
  h.eq({ nil, true }, { get(s, a.id).forge_post, get(s, a.id).in_review })
  h.eq({}, M_ledger(s))
  h.eq(0, #history(calls))
  view.close()
end)

h.test('a failed submit in the pending flow leaves the comments pending; the next submit only submits', function()
  local s, calls = setup_review('subfail', { edit = graphite(), fail = { submit = { 'acme/shop#12' } } })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local msgs, restore = h.capture_notify()
  answer({ 1 })
  view.submit('request-changes')
  wait_job()
  restore()
  h.ok(msgs[#msgs].msg:find('not submitted: PR #12: Review cannot be submitted', 1, true), vim.inspect(msgs))
  h.eq('pending', get(s, a.id).forge_post.state)
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  answer({ 1 })
  view.submit('request-changes')
  wait_job()
  h.eq('submitPullRequestReview', ops(calls)[#ops(calls)])
  h.eq(1, #vim.tbl_filter(function(m)
    return m.op == 'addPullRequestReviewThread'
  end, mutations(calls)))
  h.eq('posted', get(s, a.id).forge_post.state)
  view.close()
end)

h.test('a lost start of a pending review: nothing added; the next submit finds that review and uses it', function()
  local s, calls = setup_review('lostcreate', { fail = { lost_create = true } })
  local a = add_comment(s, 'src/cart.ts', 'add', 18, 18, 'Agreed.', {
    in_review = true, forge_reply = { thread_id = 'T_any', pr = 12, repo = 'github.com/acme/shop' } })
  local msgs, restore = h.capture_notify()
  answer({ 1 })
  view.submit('comment')
  wait_job()
  restore()
  h.ok(msgs[#msgs].msg:find('GitHub did not answer when the pending review was started', 1, true), vim.inspect(msgs))
  h.eq(nil, get(s, a.id).forge_post)
  local P = fake_state(calls)
  P.fail = nil
  write_state(calls, P)
  answer({ 1 })
  view.submit('comment')
  wait_job()
  h.eq(1, #vim.tbl_filter(function(m)
    return m.op == 'addPullRequestReview'
  end, mutations(calls)), 'never a second pending review')
  view.close()
end)

h.test('a pending review bound to another commit: noted; line comments whose file differs there are left out', function()
  local s, calls = setup_review('bound', { edit = function(p, d)
    p.prs['acme/shop#12'].pending = { id = 'PRR_old', commit = rev(d, 'stack/math'), comments = {
      { id = 'PRRC_o1', databaseId = 911, path = 'src/index.ts', line = 2, body = 'Old note.' } } }
    p.reviews.PRR_old = 'PENDING'
  end })
  add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 3 })
  view.submit('comment')
  wait_job()
  local text = asked[1].msg
  h.ok(text:find('Your pending review is bound to commit ' .. rev(s.review.root, 'stack/math'):sub(1, 7) .. ', not the reviewed head', 1, true), text)
  h.ok(text:find('src/cart.ts:12: your pending review on PR #12 is bound to commit', 1, true), text)
  h.eq({}, ops(calls))
  view.close()
end)

h.test('submitted elsewhere, discarded, transient: a pending record is posted, forgotten (and re-added), or kept and blocked', function()
  local s, calls = setup_review('elsewhere', { edit = function(p, d)
    p.prs['acme/shop#12'].history = { { id = 'PRR_done', state = 'COMMENTED', commit = rev(d, 'stack/cart'), body = '', comments = {
      { id = 'PRRC_done', databaseId = 2, path = 'src/cart.ts', line = 12, body = 'Return a copy?' } } } }
  end })
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true,
    forge_post = { state = 'pending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_done', comment_id = 'PRRC_done' } })
  local b = add_comment(s, 'src/cart.ts', 'add', 13, 13, 'Discarded.', { in_review = true,
    forge_post = { state = 'pending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_gone', comment_id = 'PRRC_gone' } })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.ok(asked[1].msg:find('+ src/cart.ts:13  Discarded.', 1, true), asked[1].msg)
  h.eq({ 'posted', 'posted' }, { get(s, a.id).forge_post.state, get(s, b.id).forge_post.state })
  h.eq({ 'addPullRequestReview' }, ops(calls))
  h.eq(1, #mutations(calls)[1].input.threads)
  view.close()
  -- a null that is not NOT_FOUND: kept, blocked
  local s2, calls2 = setup_review('transient', { edit = function(p)
    p.fail = { review_null = { 'PRR_x' } }
  end })
  local c = add_comment(s2, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true,
    forge_post = { state = 'sending', pr = 12, repo = 'github.com/acme/shop', review_id = 'PRR_x', sent_at = 1,
      payload = { kind = 'thread', path = 'src/cart.ts', line = 12, side = 'RIGHT', body = 'Return a copy?' } } })
  asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  h.eq('&Cancel', asked[1].choices)
  h.eq('unknown', get(s2, c.id).forge_post.state)
  h.eq({}, ops(calls2))
  view.close()
end)

h.test('full stack: every PR is named; one with only other pending comments gets no verdict', function()
  local s, calls = setup_review('fullall', { edit = function(p, d)
    p.prs['acme/shop#13'].pending = { id = 'PRR_ui', commit = rev(d, 'stack/ui'), comments = {
      { id = 'G13', databaseId = 9, path = 'src/cart.ts', line = 2, body = 'From Graphite.' } } }
    p.reviews.PRR_ui = 'PENDING'
  end })
  view.set_scope({ kind = 'full' })
  idle(s)
  add_comment(s, 'src/index.ts', 'add', 8, 8, 'One item only?', { in_review = true })
  local asked = answer({ 1 })
  view.submit('approve')
  wait_job()
  h.ok(asked[1].msg:find('PR #12 (acme/shop): 1 comment from revuey', 1, true), asked[1].msg)
  h.ok(asked[1].msg:find('PR #13: nothing to post, no review', 1, true), asked[1].msg)
  h.ok(asked[1].msg:find('PR #13: your pending review there (1 comment from elsewhere) is not submitted from the full stack', 1, true), asked[1].msg)
  h.eq({ 'addPullRequestReview' }, ops(calls))
  h.eq('PR_12', mutations(calls)[1].input.pullRequestId)
  view.close()
end)

h.test('full stack: each comment goes to the PR that added its lines; one review per PR', function()
  local s, calls = setup_review('full')
  view.set_scope({ kind = 'full' })
  idle(s)
  local ui = add_comment(s, 'src/cart.ts', 'add', 23, 23, 'Join with a comma?', { in_review = true })
  local cart = add_comment(s, 'src/index.ts', 'add', 8, 8, 'One item only?', { in_review = true })
  local early = add_comment(s, 'src/cart.ts', 'add', 13, 13, 'Return a copy?', { in_review = true })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  local t = asked[1].msg
  h.ok(t:find('src/cart.ts:13: src/cart.ts:13 was added by an earlier layer, not by PR #13', 1, true), t)
  local reviews = {}
  for _, x in ipairs(mutations(calls)) do
    reviews[x.input.pullRequestId] = x.input.threads[1].body
  end
  h.eq({ PR_12 = 'One item only?', PR_13 = 'Join with a comma?' }, reviews)
  h.eq({ 12, 13, nil }, { get(s, cart.id).forge_post.pr, get(s, ui.id).forge_post.pr, get(s, early.id).forge_post })
  view.close()
end)

h.test('uncommitted changes and lines outside the PR diff are left out with the reason; the rest is posted', function()
  local s, calls, d = setup_review('worktree', { edit = function(p)
    for _, f in ipairs(p.files['acme/shop#12']) do
      if f.filename == 'src/index.ts' then
        f.patch = f.patch:gsub('\n[^\n]*\n[^\n]*$', '')
      end
    end
  end })
  h.write(d, 'src/cart.ts', table.concat(vim.fn.readfile(d .. '/src/cart.ts'), '\n') .. '\n// local note\n')
  view.refresh({ force = true })
  idle(s)
  add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local hunks = s.review.files[require('revuey.review').units(s.review).by_path['src/index.ts']].hunks
  local last_new = hunks[#hunks].lines[#hunks[#hunks].lines].new_lnum
  add_comment(s, 'src/index.ts', 'ctx', last_new, last_new, 'Late line.', { in_review = true })
  local c = add_comment(s, 'src/index.ts', 'add', 5, 5, 'Cart import.', { in_review = true })
  local asked = answer({ 1 })
  view.submit('comment')
  wait_job()
  local t = asked[1].msg
  h.ok(t:find("src/cart.ts:12: src/cart.ts here is not the file at PR #12's head", 1, true), t)
  h.ok(t:find("src/index.ts:" .. last_new .. ": src/index.ts:" .. last_new .. " (new) is not in PR #12's diff", 1, true), t)
  h.ok(t:find('This review shows uncommitted changes', 1, true), t)
  h.eq({ 'addPullRequestReview' }, ops(calls))
  h.eq({ 'Cart import.' }, vim.tbl_map(function(x)
    return x.body
  end, mutations(calls)[1].input.threads))
  h.eq('posted', get(s, c.id).forge_post.state)
  view.close()
end)

h.test('your own PR: approve is refused before anything is sent; a comment review works', function()
  local s, calls = setup_review('own', { author = 'me' })
  add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 1 })
  local msgs, restore = h.capture_notify()
  view.submit('approve')
  wait_job()
  restore()
  h.eq(0, #asked)
  h.eq({}, ops(calls))
  h.ok(msgs[#msgs].msg:find('PR #12 is yours', 1, true), msgs[#msgs].msg)
  answer({ 1 })
  view.submit('comment')
  wait_job()
  h.eq({ 'addPullRequestReview' }, ops(calls))
  h.eq('COMMENT', mutations(calls)[1].input.event)
  view.close()
end)

h.test('batches in the pending flow: by count and by the encoded size of the bodies; PR files page by page', function()
  local saved = { forge.POST_BATCH, forge.POST_BATCH_BYTES, forge.FILES_PAGE }
  forge.POST_BATCH, forge.POST_BATCH_BYTES, forge.FILES_PAGE = 2, 1000, 1
  local s, calls = setup_review('batches', { edit = graphite() })
  add_comment(s, 'src/cart.ts', 'add', 3, 3, string.rep('"', 300), { in_review = true })
  add_comment(s, 'src/cart.ts', 'add', 4, 4, string.rep('"', 300), { in_review = true })
  add_comment(s, 'src/cart.ts', 'add', 5, 5, 'a', { in_review = true })
  add_comment(s, 'src/cart.ts', 'add', 6, 6, 'b', { in_review = true })
  add_comment(s, 'src/cart.ts', 'add', 7, 7, 'c', { in_review = true })
  answer({ 1 })
  view.submit('comment')
  wait_job()
  forge.POST_BATCH, forge.POST_BATCH_BYTES, forge.FILES_PAGE = saved[1], saved[2], saved[3]
  local adds, pages = 0, 0
  for _, x in ipairs(h.read_calls(calls)) do
    if (x.argv[5] or ''):find('addPullRequestReviewThread(', 1, true) then
      adds = adds + 1
    end
    if (x.argv[3] or ''):find('/files?per_page=1&page=', 1, true) then
      pages = pages + 1
    end
  end
  h.eq(4, adds, 'one, one, two, one')
  h.eq(3, pages, 'two files, then an empty page')
  h.eq(6, #ops(calls))
  view.close()
end)

h.test('one submit at a time; closing the review before the confirmation sends nothing; an error in the confirmation releases it', function()
  local s, calls = setup_review('close')
  local a = add_comment(s, 'src/cart.ts', 'add', 12, 12, 'Return a copy?', { in_review = true })
  local asked = answer({ 1 })
  local msgs, restore = h.capture_notify()
  view.submit('comment')
  view.submit('comment')
  h.ok(msgs[#msgs].msg:find('a review is being submitted already', 1, true), vim.inspect(msgs))
  view.close()
  wait_job()
  restore()
  h.eq(0, #asked)
  h.ok(msgs[#msgs].msg:find('the review closed before the confirmation: nothing was sent', 1, true), vim.inspect(msgs))
  h.eq({}, ops(calls))
  h.eq(nil, comments.get(comments.load(s.cm.path), a.id).forge_post)
  -- an error while asking
  s = open(s.review.root)
  idle(s)
  fpv.ask = function()
    error('boom')
  end
  msgs, restore = h.capture_notify()
  view.submit('comment')
  wait_job()
  restore()
  h.eq(nil, fpv.job)
  h.ok(msgs[#msgs].msg:find('submit stopped:', 1, true), vim.inspect(msgs))
  view.close()
end)

h.run()
