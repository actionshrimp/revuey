-- Export of review comments (pure): Markdown designed for pasting into an AI session, and JSON
-- with the full data for tools. Used by :RevueyCommentsExport and `bin/revuey comments`.
local comments = require('revuey.comments')

local M = {}

local function author_name(a)
  a = a or {}
  if a.name and a.name ~= '' then
    return a.name
  end
  return ({ user = 'Reviewer', ai = 'AI', agent = 'Agent' })[a.kind] or 'Reviewer'
end
M.author_name = author_name

---Short scope wording of a review info table.
function M.scope_label(r)
  if r.scope == 'full' then
    local layers = r.layers and #r.layers > 0 and (' (' .. table.concat(r.layers, ', ') .. ')') or ''
    return 'full stack' .. layers
  elseif r.scope == 'layer' then
    return 'stack layer ' .. (r.branch or '?') .. (r.parent and (' on ' .. r.parent) or '')
  end
  return 'branch'
end

local function fence_for(lines)
  local longest = 2
  for _, l in ipairs(lines) do
    for run in l:gmatch('`+') do
      longest = math.max(longest, #run)
    end
  end
  return string.rep('`', longest + 1)
end

---Select comments of a store for export.
---@param opts? {all?:boolean}
function M.select(store, opts)
  opts = opts or {}
  return comments.list(store, { include_resolved = opts.all, include_drafts = opts.all })
end

local function status_note(c)
  local notes = {}
  if c.author and c.author.kind and c.author.kind ~= 'user' then
    notes[#notes + 1] = 'by ' .. author_name(c.author) .. (c.author.kind == 'agent' and c.author.name and c.author.name:lower() ~= 'agent' and ' (agent)' or '')
      .. (c.author.kind == 'ai' and c.author.name and ' (AI review)' or '')
  end
  if type(c.forge_reply) == 'table' then
    notes[#notes + 1] = ('a reply to GitHub #%s thread %s'):format(tostring(c.forge_reply.pr), tostring(c.forge_reply.url or ''))
  end
  if c.outdated then
    notes[#notes + 1] = 'outdated: the code changed since this comment was made'
  end
  if c.status == 'resolved' then
    notes[#notes + 1] = 'resolved'
  elseif c.status == 'draft' then
    notes[#notes + 1] = 'draft'
  elseif c.status == 'dismissed' then
    notes[#notes + 1] = 'dismissed'
  elseif c.status == 'accepted' then
    notes[#notes + 1] = 'accepted from an AI review'
  end
  if c.ai and c.status ~= 'accepted' then
    notes[#notes + 1] = (c.ai.severity or 'minor') .. (c.status == 'saved' and ', not triaged yet' or '')
  end
  return #notes > 0 and (' (' .. table.concat(notes, '; ') .. ')') or ''
end

---Markdown for one or more reviews: `{ {review = info, comments = list}, ... }`.
---@param reviews {review:table, comments:revuey.Comment[]}[]
---@return string
function M.markdown(reviews)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  for ri, entry in ipairs(reviews) do
    local r = entry.review or {}
    local list = entry.comments or {}
    if ri > 1 then
      add('')
      add('---')
      add('')
    end
    local repo = r.repo and vim.fs.basename(r.repo) or '?'
    add(('# Review comments: %s → %s'):format(r.branch or '?', r.base or '?'))
    add('')
    add(('- Repo: %s%s'):format(repo, r.repo and (' (' .. r.repo .. ')') or ''))
    add('- Branch: ' .. (r.branch or '?'))
    add('- Scope: ' .. M.scope_label(r))
    add('- Base: ' .. (r.base or '?') .. (r.merge_base and (' (merge-base ' .. r.merge_base:sub(1, 8) .. ')') or ''))
    add('')
    if #list == 0 then
      add('No comments.')
    else
      add(
        ('%d comment%s, ordered by file and line. Each gives the file, the line range and side (new: the code after the change, old: the code before it), the diff lines it is about, and the reviewer\'s note.'):format(
          #list,
          #list == 1 and '' or 's'
        )
      )
    end
    for i, c in ipairs(list) do
      add('')
      local where = c.file_level and (c.anchor.path .. ' (whole file)')
        or (comments.location(c) .. ' (' .. (c.anchor.side or 'new') .. ')')
      add(('## %d. %s%s'):format(i, where, status_note(c)))
      local snippet = c.anchor.snippet or {}
      if not c.file_level and #snippet > 0 then
        local fence = fence_for(snippet)
        add('')
        add(fence .. 'diff')
        for _, l in ipairs(snippet) do
          add(l)
        end
        add(fence)
      end
      add('')
      add(vim.trim(c.body or ''))
      local replies = {}
      for _, rep in ipairs(c.thread or {}) do
        if not rep.deleted then
          replies[#replies + 1] = rep
        end
      end
      if #replies > 0 then
        add('')
        add('Replies:')
        for _, rep in ipairs(replies) do
          local body = vim.split(vim.trim(rep.body or ''), '\n', { plain = true })
          add(('- **%s**: %s'):format(author_name(rep.author), body[1] or ''))
          for k = 2, #body do
            add('  ' .. body[k])
          end
        end
      end
    end
  end
  return table.concat(out, '\n') .. '\n'
end

---JSON with the full data (tombstones left out): `{version, reviews = [{review, comments}]}`.
---@param reviews {review:table, comments:revuey.Comment[]}[]
function M.json(reviews)
  local list = {}
  for _, entry in ipairs(reviews) do
    list[#list + 1] = {
      review = next(entry.review or {}) and entry.review or vim.empty_dict(),
      comments = entry.comments or {},
    }
  end
  return vim.json.encode({ version = comments.VERSION, reviews = list }) .. '\n'
end

local DELIVERY = {
  sent = 'waiting for the agent',
  seen = 'acknowledged by the agent',
  answered = 'answered by the agent',
}

---One message sent to an agent (`bin/revuey show <id>`): where it is, the review it belongs to,
---the code, the comment and its thread, then how to answer.
---@param c revuey.Comment
---@param r table review info
---@param bin? string how to call bin/revuey in the hints
function M.message(c, r, bin)
  bin = bin or 'revuey'
  r = r or {}
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  local where = c.file_level and (c.anchor.path .. ' (whole file)') or (comments.location(c) .. ' (' .. (c.anchor.side or 'new') .. ')')
  add('# Message ' .. c.id)
  add('')
  add('- Location: ' .. where .. (c.outdated and ' (outdated: the code changed since)' or ''))
  add(('- Repo: %s%s'):format(r.repo and vim.fs.basename(r.repo) or '?', r.repo and (' (' .. r.repo .. ')') or ''))
  add('- Branch: ' .. (r.branch or '?'))
  add('- Scope: ' .. M.scope_label(r))
  add('- Base: ' .. (r.base or '?') .. (r.merge_base and (' (merge-base ' .. r.merge_base:sub(1, 8) .. ')') or ''))
  local d = comments.delivery(c)
  if c.sent_at then
    add(('- Sent: %s (%s)'):format(os.date('!%Y-%m-%d %H:%M:%S UTC', math.floor(c.sent_at / 1000)), DELIVERY[d] or d))
  end
  if c.status ~= 'saved' then
    add('- Status: ' .. tostring(c.status))
  end
  add('')
  add('Side: new is the code after the change, old the code before it. The file is in the repo; read more of it as needed.')
  local snippet = c.anchor.snippet or {}
  if not c.file_level and #snippet > 0 then
    local fence = fence_for(snippet)
    add('')
    add('## Code')
    add('')
    add(fence .. 'diff')
    for _, l in ipairs(snippet) do
      add(l)
    end
    add(fence)
  end
  add('')
  add('## Comment (' .. author_name(c.author) .. (c.author and c.author.kind == 'ai' and ', an AI review finding the user sent you to follow up' or '') .. ')')
  add('')
  add(vim.trim(c.body or ''))
  local replies = {}
  for _, rep in ipairs(c.thread or {}) do
    if not rep.deleted then
      replies[#replies + 1] = rep
    end
  end
  if #replies > 0 then
    add('')
    add('## Thread')
    for _, rep in ipairs(replies) do
      local body = vim.split(vim.trim(rep.body or ''), '\n', { plain = true })
      local mark = rep.id == c.sent_reply and ' (the message sent to you)' or ''
      add('')
      add(('- **%s**%s: %s'):format(author_name(rep.author), mark, body[1] or ''))
      for k = 2, #body do
        add('  ' .. body[k])
      end
    end
  end
  add('')
  add('---')
  add(('Answer: `%s reply %s "<text>"` (`-` reads it from stdin). Handled without a reply: `%s ack %s`.'):format(bin, c.id, bin, c.id))
  return table.concat(out, '\n') .. '\n'
end

---Export in `format` ('markdown' default, or 'json').
function M.render(format, reviews)
  if format == 'json' then
    return M.json(reviews)
  end
  return M.markdown(reviews)
end

return M
