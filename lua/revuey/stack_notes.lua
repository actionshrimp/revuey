-- Stack notes: what detection found that the user may want to know about (a layer not restacked,
-- an out-of-date parent setting, related branches outside the stack...). Pure: no UI calls.
--
-- A note is a table {kind, branch, layer?, parent?, source?, at?, branches?, text}. Each kind is
-- either 'warn' (it changes the diff shown) or 'info' (it doesn't). The panel shows a few short
-- summary lines grouped by kind (`summary`); a float lists every note in full (`details`), with
-- actions per branch (`actions`). Kinds marked `related` are about branches outside the stack, and
-- can be hidden with the ignore list (stack_ignore.lua).
local M = {}

---@class revuey.StackNote
---@field kind string
---@field branch string        the branch the note is about
---@field layer? string        the stack layer (or reviewed branch) it relates to
---@field parent? string       parent setting / parent layer
---@field source? string       where a parent setting came from: 'config'|'graphite'
---@field at? string           short commit (not_restacked: the parent's old tip)
---@field branches? string[]   fork: the child branches
---@field text string          the note in full, one or two plain sentences

---@class revuey.NotesCtx
---@field stack boolean        notes about a stack (else about a lone branch)
---@field trunk string
---@field key? string          panel key that opens the details float

local function your(ctx)
  return ctx.stack and 'your stack' or 'your branch'
end

local function this(ctx)
  return ctx.stack and 'this stack' or 'this branch'
end

local function source_name(src)
  return src == 'graphite' and 'Graphite' or "revuey's setting"
end

local function plural(n, one, many)
  return n == 1 and one or many
end

-- Per kind: level, display order, whether ignorable (`related`), title, `one` (text of a single
-- note), `many` (shared text of a group), `impact` (why it matters), `detail` (per-branch line).
M.KINDS = {
  not_restacked = {
    level = 'warn',
    title = 'Not restacked',
    one = function(n)
      return ('%s isn\'t restacked on %s. %s changed after %s was built on it (amended, new commits or rebased).'):format(
        n.branch, n.parent, n.parent, n.branch)
    end,
    many = function()
      return 'These layers aren\'t restacked on their parent. Each parent changed after the layer was built on it (amended, new commits or rebased).'
    end,
    impact = function(ns)
      if #ns == 1 then
        local n = ns[1]
        return ('Affects this review: it shows only %s\'s own commits, starting from where %s used to be (%s). Rebase %s onto %s to fix it.'):format(
          n.branch, n.parent, n.at or '?', n.branch, n.parent)
      end
      return 'Affects this review: each layer shows only its own commits, starting from where its parent used to be. Rebase them onto their parents to fix it.'
    end,
    detail = function(n)
      return ('on %s, from its old tip %s'):format(n.parent, n.at or '?')
    end,
  },
  stale_parent = {
    level = 'warn',
    title = 'Parent setting out of date',
    one = function(n)
      return ('%s\'s parent is set to %s (in %s), but %s isn\'t built on %s.'):format(n.branch, n.parent, source_name(n.source), n.branch, n.parent)
    end,
    many = function()
      return 'These layers have a parent setting, but they aren\'t built on that parent.'
    end,
    impact = function(ns, ctx)
      if #ns == 1 then
        return ('Affects this review: %s is compared with %s instead. Fix the parent setting, or clear it.'):format(ns[1].branch, ctx.trunk)
      end
      return ('Affects this review: they are compared with %s instead. Fix the parent settings, or clear them.'):format(ctx.trunk)
    end,
    detail = function(n)
      return ('parent set to %s'):format(n.parent)
    end,
  },
  unknown_parent = {
    level = 'warn',
    title = 'Parent setting names a missing branch',
    one = function(n)
      return ('%s\'s parent is set to "%s" (in %s), but there\'s no local branch with that name.'):format(n.branch, n.parent, source_name(n.source))
    end,
    many = function()
      return 'These branches have a parent setting that names a branch that doesn\'t exist here.'
    end,
    impact = function()
      return 'Affects this review: revuey guessed the parent instead. Clear the setting, or set another parent.'
    end,
    detail = function(n)
      return ('parent set to "%s"'):format(n.parent)
    end,
  },
  cycle = {
    level = 'warn',
    title = 'Parent settings form a loop',
    one = function(n)
      return ('The parent settings loop back to %s, so they can\'t all be right.'):format(n.parent)
    end,
    impact = function(ns, ctx)
      return ('Affects this review: %s is compared with %s instead. Clear one of the parent settings.'):format(ns[1].branch, ctx.trunk)
    end,
    detail = function(n)
      return ('loops at %s'):format(n.parent)
    end,
  },
  newer_copy = {
    level = 'warn',
    related = true,
    title = 'Built on an old version of another branch',
    one = function(n)
      return ('%s contains an older version of a commit that\'s now on %s (%s was amended or rebased since). %s may be built on an outdated copy of %s.'):format(
        n.layer, n.branch, n.branch, n.layer, n.branch)
    end,
    many = function(_, ctx)
      return ('%s contains older versions of commits that are now on these branches (they were amended or rebased since). It may be built on outdated copies of them.'):format(
        ctx.stack and 'Your stack' or 'Your branch')
    end,
    impact = function(ns)
      if #ns == 1 then
        local n = ns[1]
        return ('May affect this review: it can include old commits that belong to %s. If %s is the parent of %s, rebase %s onto it.'):format(
          n.branch, n.branch, n.layer, n.layer)
      end
      return 'May affect this review: it can include old commits that belong to them. If one is the parent, rebase onto it.'
    end,
    detail = function(n)
      return ('newer copy of a commit in %s'):format(n.layer)
    end,
  },
  outdated_copy = {
    level = 'info',
    related = true,
    title = 'Built on an outdated copy of your stack',
    one = function(n, ctx)
      return ('%s contains an older version of a commit that\'s now in %s (it was amended or rebased since). It may be built on an outdated copy of %s.'):format(
        n.branch, your(ctx), your(ctx))
    end,
    many = function(_, ctx)
      return ('These branches contain older versions of commits that are now in %s (they were amended or rebased since). They may be built on an outdated copy of %s.'):format(
        your(ctx), your(ctx))
    end,
    impact = function(ns)
      local it = #ns == 1 and 'it' or 'them'
      return ('Doesn\'t affect this review. If you no longer need %s, delete or ignore %s.'):format(it, it)
    end,
    detail = function(n)
      return ('old copy of %s'):format(n.layer)
    end,
  },
  other_copy = {
    level = 'info',
    related = true,
    title = 'Another version of a commit in your stack',
    one = function(n)
      return ('%s contains a different version of a commit in %s: one of them was amended or rebased.'):format(n.branch, n.layer)
    end,
    many = function(_, ctx)
      return ('These branches contain different versions of commits in %s: some were amended or rebased.'):format(your(ctx))
    end,
    impact = function(ns)
      if #ns == 1 then
        return ('Doesn\'t affect this review. It is often a backport or a backup of %s.'):format(ns[1].layer)
      end
      return 'Doesn\'t affect this review. They are often backports or backups.'
    end,
    detail = function(n)
      return ('other version of a commit in %s'):format(n.layer)
    end,
  },
  outside = {
    level = 'warn',
    related = true,
    title = 'Shares commits with your stack',
    one = function(n, ctx)
      return ('%s shares commits with %s but isn\'t part of %s.'):format(n.branch, n.layer, this(ctx))
    end,
    many = function(_, ctx)
      return ('These branches share commits with %s but aren\'t part of it.'):format(your(ctx))
    end,
    impact = function(ns)
      if #ns == 1 then
        local n = ns[1]
        return ('May affect this review: if %s is the branch %s was built on and it moved since, %s\'s diff includes %s\'s commits. Then rebase %s onto %s.'):format(
          n.branch, n.layer, n.layer, n.branch, n.layer, n.branch)
      end
      return 'May affect this review: if one is the branch your stack was built on and it moved since, the diff includes its commits. Then rebase onto it.'
    end,
    detail = function(n)
      return ('shares commits with %s'):format(n.layer)
    end,
  },
  side = {
    level = 'info',
    related = true,
    title = 'Side branches',
    one = function(n, ctx)
      return ('%s is built on %s but isn\'t part of %s. It\'s a side branch.'):format(n.branch, n.layer, this(ctx))
    end,
    many = function(_, ctx)
      return ('These branches are built on a layer of %s but aren\'t part of it. They\'re side branches.'):format(your(ctx))
    end,
    impact = function()
      return 'Doesn\'t affect this review.'
    end,
    detail = function(n)
      return ('built on %s'):format(n.layer)
    end,
  },
  squashed = {
    level = 'warn',
    title = 'Commits already in trunk are skipped',
    one = function(n, ctx)
      return ('The first %d commit%s of %s %s already in %s as squash merges (lower branches merged, %s not rebased since).'):format(
        n.count, n.count == 1 and '' or 's', n.branch, n.count == 1 and 'is' or 'are', ctx.trunk, n.branch)
    end,
    many = function(_, ctx)
      return ('The first commits of these branches are already in %s as squash merges (lower branches merged, not rebased since).'):format(ctx.trunk)
    end,
    impact = function(ns, ctx)
      if #ns == 1 then
        local n = ns[1]
        return ('Affects this review: it shows only %s\'s own commits, from %s; the skipped ones are already in %s. Rebase %s onto %s to remove this note. If the match is wrong, the diff is missing those commits.'):format(
          n.branch, n.at or '?', ctx.trunk, n.branch, ctx.trunk)
      end
      return ('Affects this review: each shows only its own commits; the skipped ones are already in %s. Rebase onto %s to remove this note.'):format(ctx.trunk, ctx.trunk)
    end,
    detail = function(n)
      return ('%d commit%s skipped, diff from %s'):format(n.count, n.count == 1 and '' or 's', n.at or '?')
    end,
  },
  landed = {
    level = 'info',
    title = 'Looks landed',
    one = function(n, ctx)
      local text = ('%s looks landed in %s: its changes are already there.'):format(n.branch, ctx.trunk)
      if n.count then
        text = text .. (' Its diff shows only its own last commits; %d earlier commit%s that %s already has %s left out.'):format(
          n.count, n.count == 1 and '' or 's', ctx.trunk, n.count == 1 and 'is' or 'are')
      end
      return text
    end,
    many = function(_, ctx)
      return ('These layers look landed in %s: their changes are already there.'):format(ctx.trunk)
    end,
    impact = function()
      return 'Doesn\'t affect this review. Landed layers are dimmed, and the layers above still compare with them.'
    end,
  },
  fork = {
    level = 'info',
    title = 'The stack stops at a fork',
    one = function(n)
      return ('%d branches are built on %s. A stack is a single line of branches, so it stops at %s.'):format(#(n.branches or {}), n.branch, n.branch)
    end,
    impact = function()
      return 'Doesn\'t affect this review. Check out one of these branches to review it with its stack.'
    end,
  },
  same_commit = {
    level = 'info',
    related = true,
    title = 'Same commit as a layer',
    one = function(n)
      return ('%s points at the same commit as %s. revuey shows that commit as %s.'):format(n.branch, n.layer, n.layer)
    end,
    many = function()
      return 'These branches point at the same commit as a layer. revuey shows the layer\'s name.'
    end,
    impact = function()
      return 'Doesn\'t affect this review. To name a layer differently, set parents with :RevueyStackParent.'
    end,
    detail = function(n)
      return ('same commit as %s'):format(n.layer)
    end,
  },
  parent_landed = {
    level = 'info',
    title = 'Parent already merged',
    one = function(n, ctx)
      return ('%s, set as the parent of %s, is already merged into %s.'):format(n.parent, n.branch, ctx.trunk)
    end,
    many = function(_, ctx)
      return ('These branches have a parent setting that is already merged into %s.'):format(ctx.trunk)
    end,
    impact = function(_, ctx)
      return ('Doesn\'t affect this review: they are compared with %s. You can clear the parent setting.'):format(ctx.trunk)
    end,
    detail = function(n)
      return ('parent %s'):format(n.parent)
    end,
  },
}

-- Display order of kinds (float sections).
M.ORDER = {
  'not_restacked', 'squashed', 'stale_parent', 'unknown_parent', 'cycle', 'newer_copy',
  'outdated_copy', 'other_copy', 'outside', 'side', 'landed', 'fork', 'same_commit', 'parent_landed',
}
for i, k in ipairs(M.ORDER) do
  M.KINDS[k].order = i
end

-- Kinds sharing one summary line ("3 related branches outside this stack").
M.RELATED_SUMMARY = { outdated_copy = true, other_copy = true, side = true }

---Build a note with its full text.
---@param kind string
---@param fields table
---@param ctx revuey.NotesCtx
---@return revuey.StackNote
function M.new(kind, fields, ctx)
  local n = vim.tbl_extend('force', { kind = kind }, fields)
  n.text = M.KINDS[kind].one(n, ctx)
  return n
end

---'warn' when the note changes the diff shown, else 'info'.
function M.level(note)
  return M.KINDS[note.kind] and M.KINDS[note.kind].level or 'info'
end

---Informational notes about branches outside the stack, which the ignore list can hide. Notes
---that affect the diff are never hidden.
function M.ignorable(note)
  local k = M.KINDS[note.kind]
  return k ~= nil and k.related == true and k.level == 'info'
end

---Split notes by the ignore list. `patterns` are globs (stack_ignore).
---@return revuey.StackNote[] shown, {branch:string, kind:string, pattern:string}[] ignored
function M.filter(notes, patterns)
  local ign = require('revuey.stack_ignore')
  local shown, ignored = {}, {}
  for _, n in ipairs(notes) do
    local p = M.ignorable(n) and ign.match(patterns, n.branch)
    if p then
      ignored[#ignored + 1] = { branch = n.branch, kind = n.kind, pattern = p }
    else
      shown[#shown + 1] = n
    end
  end
  return shown, ignored
end

---Group notes by kind, in display order.
---@return {kind:string, level:string, title:string, notes:revuey.StackNote[]}[]
function M.groups(notes)
  local by = {}
  for _, n in ipairs(notes or {}) do
    if M.KINDS[n.kind] then
      by[n.kind] = by[n.kind] or {}
      table.insert(by[n.kind], n)
    end
  end
  local out = {}
  for _, k in ipairs(M.ORDER) do
    if by[k] then
      table.sort(by[k], function(a, b)
        return a.branch < b.branch
      end)
      out[#out + 1] = { kind = k, level = M.KINDS[k].level, title = M.KINDS[k].title, notes = by[k] }
    end
  end
  return out
end

local function uniq_count(list, field)
  local seen, n = {}, 0
  for _, x in ipairs(list) do
    if not seen[x[field]] then
      seen[x[field]] = true
      n = n + 1
    end
  end
  return n
end

---Short summary lines for the panel, grouped by kind, warnings first. At most `max` lines (the
---last one says how many more there are).
---@param notes revuey.StackNote[]
---@param ignored? {branch:string, kind:string}[]
---@param ctx revuey.NotesCtx
---@param max? integer default 3
---@return {glyph:string, text:string, level:string}[]
function M.summary(notes, ignored, ctx, max)
  max = max or 3
  ignored = ignored or {}
  local lines = {}
  local function add(glyph, text, level)
    lines[#lines + 1] = { glyph = glyph, text = text, level = level }
  end
  local function ignored_of(pred)
    local list = {}
    for _, x in ipairs(ignored) do
      if pred(x.kind) then
        list[#list + 1] = x
      end
    end
    return uniq_count(list, 'branch')
  end
  local related = {}
  local related_done = false
  for _, g in ipairs(M.groups(notes)) do
    local ns, k, n1 = g.notes, g.kind, g.notes[1]
    local c = #ns
    if k == 'not_restacked' then
      add('⚠', c == 1 and ('%s not restacked on %s'):format(n1.branch, n1.parent) or ('%d layers not restacked'):format(c), 'warn')
    elseif k == 'squashed' then
      add('⚠', c == 1 and ('%s skips %d commit%s already in %s'):format(n1.branch, n1.count, n1.count == 1 and '' or 's', ctx.trunk)
        or ('%d branches skip commits already in %s'):format(c, ctx.trunk), 'warn')
    elseif k == 'stale_parent' then
      add('⚠', c == 1 and ('%s: parent setting out of date'):format(n1.branch) or ('%d parent settings out of date'):format(c), 'warn')
    elseif k == 'unknown_parent' then
      add('⚠', c == 1 and ('%s: parent %s not found'):format(n1.branch, n1.parent) or ('%d parent settings name missing branches'):format(c), 'warn')
    elseif k == 'cycle' then
      add('⚠', 'parent settings form a loop', 'warn')
    elseif k == 'newer_copy' then
      add('⚠', c == 1 and ('%s may be built on an old %s'):format(n1.layer, n1.branch) or ('may be built on old copies of %d branches'):format(c), 'warn')
    elseif k == 'outside' then
      add('⚠', c == 1 and ('%s shares commits with %s'):format(n1.branch, n1.layer) or ('%d branches share commits with %s'):format(c, ctx.stack and 'the stack' or n1.layer), 'warn')
    elseif M.RELATED_SUMMARY[k] then
      vim.list_extend(related, ns)
      if not related_done then
        related_done = true
        lines[#lines + 1] = { related = true } -- filled in below, once all related kinds are in
      end
    elseif k == 'landed' then
      add('●', c == 1 and ('%s looks landed in %s'):format(n1.branch, ctx.trunk) or ('%d layers look landed in %s'):format(c, ctx.trunk), 'info')
    elseif k == 'fork' then
      add('●', ('stack stops at %s: %d branches on it'):format(n1.branch, #(n1.branches or {})), 'info')
    elseif k == 'same_commit' then
      local layers = uniq_count(ns, 'layer')
      local n = uniq_count(ns, 'branch')
      local text = layers == 1 and ('%d other %s at %s'):format(n, plural(n, 'branch', 'branches'), n1.layer)
        or ('%d other branches at layer commits'):format(n)
      local ign = ignored_of(function(kind)
        return kind == 'same_commit'
      end)
      add('●', text .. (ign > 0 and (' (%d ignored)'):format(ign) or ''), 'info')
    elseif k == 'parent_landed' then
      add('●', c == 1 and ('%s\'s parent is already in %s'):format(n1.branch, ctx.trunk) or ('%d parents already in %s'):format(c, ctx.trunk), 'info')
    end
  end
  for i, l in ipairs(lines) do
    if l.related then
      local n = uniq_count(related, 'branch')
      local ign = ignored_of(function(kind)
        return M.RELATED_SUMMARY[kind] or false
      end)
      lines[i] = {
        glyph = '○',
        text = ('%d related %s%s'):format(n, plural(n, 'branch', 'branches'), ctx.stack and ' outside this stack' or '')
          .. (ign > 0 and (' (%d ignored)'):format(ign) or ''),
        level = 'info',
      }
    end
  end
  if #lines > max then
    local rest = #lines - (max - 1)
    lines = vim.list_slice(lines, 1, max - 1)
    lines[#lines + 1] = {
      glyph = '…',
      text = ('%d more%s'):format(rest, ctx.key and (': press %s for details'):format(ctx.key) or ''),
      level = 'info',
    }
  end
  return lines
end

---Actions for one branch entry of a note.
---@return {key:string, id:string, label:string, branch?:string, parent?:string, pattern?:string}[]
function M.actions(note, branch)
  local acts = {}
  local k = note.kind
  -- only when the setting would hold (no "parent setting out of date" warning right after)
  if (k == 'newer_copy' or k == 'outside') and note.layer and note.parent_ok then
    acts[#acts + 1] = {
      key = 'p', id = 'parent', branch = note.layer, parent = note.branch,
      label = ('set %s as the parent of %s'):format(note.branch, note.layer),
    }
  end
  if (k == 'stale_parent' or k == 'unknown_parent' or k == 'cycle' or k == 'parent_landed') and note.source == 'config' then
    acts[#acts + 1] = {
      key = 'c', id = 'clear', branch = note.branch,
      label = ('clear the parent setting of %s'):format(note.branch),
    }
  end
  if M.ignorable(note) then
    local b = branch or note.branch
    local suggest = require('revuey.stack_ignore').suggest(b)
    acts[#acts + 1] = { key = 'x', id = 'ignore', pattern = b, label = ('ignore %s'):format(b) }
    acts[#acts + 1] = { key = 'X', id = 'pattern', pattern = suggest, label = ('ignore a pattern (%s)'):format(suggest) }
  end
  return acts
end

local HINT = { p = 'p parent', c = 'c clear', x = 'x ignore', X = 'X pattern', u = 'u un-ignore' }

---Wrap text to `width` display cells at word boundaries; every line starts with `indent`.
function M.wrap(text, width, indent)
  indent = indent or ''
  local out, line = {}, indent
  local room = width - vim.fn.strdisplaywidth(indent)
  local words = {}
  for word in text:gmatch('%S+') do
    -- a word longer than a line (a long branch name) is split rather than overflowing
    while room > 0 and vim.fn.strdisplaywidth(word) > room do
      local cut, w = 0, 0
      while w + vim.fn.strdisplaywidth(vim.fn.strcharpart(word, cut, 1)) <= room do
        w = w + vim.fn.strdisplaywidth(vim.fn.strcharpart(word, cut, 1))
        cut = cut + 1
      end
      cut = math.max(cut, 1)
      words[#words + 1] = vim.fn.strcharpart(word, 0, cut)
      word = vim.fn.strcharpart(word, cut)
    end
    words[#words + 1] = word
  end
  for _, word in ipairs(words) do
    if line ~= indent and vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
      out[#out + 1] = line
      line = indent .. word
    else
      line = line == indent and (indent .. word) or (line .. ' ' .. word)
    end
  end
  if line ~= indent then
    out[#out + 1] = line
  end
  return out
end

---Full listing for the details float: per kind a heading, what it means, why it matters, and the
---branches involved (one row each, with the keys of its actions). Then the ignore list.
---@param notes revuey.StackNote[]
---@param ignored {branch:string, kind:string, pattern:string}[]
---@param patterns {pattern:string, source:string}[] effective ignore list
---@param ctx revuey.NotesCtx
---@param width integer
---@return {lines:string[], hls:{[1]:integer, [2]:integer, [3]:integer, [4]:string}[], rows:table<integer, table>, hints:table<integer, string>}
function M.details(notes, ignored, patterns, ctx, width)
  local lines, hls, rows, hints = {}, {}, {}, {}
  local function add(text, hl, from)
    lines[#lines + 1] = text
    if hl then
      hls[#hls + 1] = { #lines, from or 0, #text, hl }
    end
    return #lines
  end
  local function para(text, hl)
    for _, l in ipairs(M.wrap(text, width, '  ')) do
      add(l, hl)
    end
  end
  local function entry(text, detail, e)
    local hint = {}
    for _, a in ipairs(e.actions or {}) do
      hint[#hint + 1] = HINT[a.key]
    end
    local base = '    ' .. text
    detail = detail or ''
    if vim.fn.strdisplaywidth(base) > width then
      -- a name longer than the float: wrap it in chunks (every chunk acts on the entry)
      local chunk, w = '', 0
      for k = 0, vim.fn.strchars(text) - 1 do
        local ch = vim.fn.strcharpart(text, k, 1)
        local cw = vim.fn.strdisplaywidth(ch)
        if w + cw > width - 4 and chunk ~= '' then
          local r = add('    ' .. chunk)
          hls[#hls + 1] = { r, 4, #lines[r], 'RevueyStackBranch' }
          rows[r] = e
          chunk, w = '', 0
        end
        chunk, w = chunk .. ch, w + cw
      end
      base = '    ' .. chunk
    end
    local inline = detail ~= '' and vim.fn.strdisplaywidth(base .. '  ' .. detail) <= width
    local row = add(base .. (inline and ('  ' .. detail) or ''))
    hls[#hls + 1] = { row, 4, #base, 'RevueyStackBranch' }
    if #base < #lines[row] then
      hls[#hls + 1] = { row, #base, #lines[row], 'RevueyStackNote' }
    end
    rows[row] = e
    if detail ~= '' and not inline then
      -- too long for one line: the detail goes on its own (wrapped) lines below the branch
      for _, l in ipairs(M.wrap(detail, width, '      ')) do
        rows[add(l, 'RevueyStackNote')] = e
      end
    end
    if #hint > 0 then
      hints[row] = table.concat(hint, '  ')
    end
  end
  local groups = M.groups(notes)
  if #groups == 0 then
    add(' No notes about ' .. this(ctx) .. '.', 'RevueyStackNote')
  end
  for gi, g in ipairs(groups) do
    if gi > 1 then
      add('')
    end
    local kind = M.KINDS[g.kind]
    local warn = g.level == 'warn'
    local title = kind.title:gsub('your stack', your(ctx))
    local head = (warn and '⚠ ' or (kind.related and '○ ' or '● ')) .. title
    for _, l in ipairs(M.wrap(head, width, '')) do
      add(l, warn and 'RevueyStackWarn' or 'RevueyStackTitle')
    end
    local meaning = (#g.notes == 1 or not kind.many) and g.notes[1].text or kind.many(g.notes, ctx)
    if g.kind == 'fork' then
      meaning = g.notes[1].text
    end
    para(meaning)
    para(kind.impact(g.notes, ctx), warn and 'RevueyStackWarn' or 'RevueyStackNote')
    if g.kind == 'fork' then
      for _, b in ipairs(g.notes[1].branches or {}) do
        entry(b, '', { note = g.notes[1], branch = b, actions = {} })
      end
    else
      for _, n in ipairs(g.notes) do
        entry(n.branch, kind.detail and kind.detail(n) or '', { note = n, branch = n.branch, actions = M.actions(n) })
      end
    end
  end
  if #patterns > 0 or #ignored > 0 then
    add('')
    add('Ignored branches', 'RevueyStackTitle')
    local n = uniq_count(ignored, 'branch')
    para(n > 0 and ('Notes about %d %s are hidden by these patterns.'):format(n, plural(n, 'branch', 'branches'))
      or 'No notes are hidden by these patterns right now.', 'RevueyStackNote')
    for _, p in ipairs(patterns) do
      local hidden = 0
      for _, x in ipairs(ignored) do
        if x.pattern == p.pattern then
          hidden = hidden + 1
        end
      end
      local detail = (p.source == 'config' and 'from your config' or 'this repo') .. (hidden > 0 and (', hides %d'):format(hidden) or '')
      entry(p.pattern, detail, {
        pattern_entry = p,
        actions = p.source == 'repo' and { { key = 'u', id = 'unignore', pattern = p.pattern, label = ('stop ignoring %s'):format(p.pattern) } } or {},
      })
    end
  end
  return { lines = lines, hls = hls, rows = rows, hints = hints }
end

---Notes, ignored notes and wording context of a review (stack or lone branch).
---@return revuey.StackNote[], table[], revuey.NotesCtx
function M.of_review(review, key)
  if review.stack then
    return review.stack.notes or {}, review.stack.ignored or {}, { stack = true, trunk = review.stack.trunk, key = key }
  end
  return review.notes or {}, review.notes_ignored or {}, { stack = false, trunk = review.base, key = key }
end

return M
