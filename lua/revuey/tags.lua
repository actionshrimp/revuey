-- Tags on comments: labels for grouping AI findings and agent comments (by review pass, skill,
-- topic). Pure (no window/buffer UI), shared by the UI and `bin/revuey tag`.
--
--   * Stored per comment as `tags = {[tag] = {at = ms, off = true?}}`: one entry per tag ever
--     set, with when it was last set or removed. Merged per tag, the newest entry winning
--     (comments.merge), so a tag added by the CLI survives an accept or a dismiss made at the same
--     time in the UI, and a removal survives a re-add only when it is newer.
--   * Default tags are computed, never stored: an AI finding's skill, else the name of the run
--     that made it (`ai.run`; findings from before it: the author's name). A stored `off` entry
--     hides a default too.
--   * Tags are cleaned where they come in: lower case, `a-z 0-9 . _ -`, other characters runs
--     made `-`, at most MAX_LEN characters, at most MAX_TAGS per comment.
local M = {}

M.MAX_LEN = 24
M.MAX_TAGS = 16

---A tag as stored and shown, or nil when nothing is left of it.
function M.clean(t)
  if type(t) ~= 'string' then
    return nil
  end
  t = vim.trim(t):lower():gsub('^#+', ''):gsub('[^%w%._%-]+', '-')
  t = t:gsub('^[%-%._]+', ''):gsub('[%-%._]+$', '')
  if #t > M.MAX_LEN then
    t = t:sub(1, M.MAX_LEN):gsub('[%-%._]+$', '')
  end
  return t ~= '' and t or nil
end

---Clean a list of tags (strings, or a comma or space separated text): unique, in order.
---@return string[] tags, string[] rejected what was given but cleaned to nothing
function M.clean_list(list)
  if type(list) == 'string' then
    list = vim.split(list, '[%s,]+', { trimempty = true })
  end
  local out, seen, bad = {}, {}, {}
  for _, t in ipairs(list or {}) do
    local c = M.clean(t)
    if not c then
      bad[#bad + 1] = tostring(t)
    elseif not seen[c] then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return out, bad
end

---The default tags of comment `c` (computed): an AI finding's skill, else its run's name.
---@return string[]
function M.defaults(c)
  if type(c) ~= 'table' or type(c.ai) ~= 'table' then
    return {}
  end
  local run = type(c.ai.run) == 'table' and c.ai.run or {}
  local who = run.name or (type(c.ai.author) == 'table' and c.ai.author.name) or (c.author and c.author.kind == 'ai' and c.author.name)
  local t = M.clean(run.skill) or M.clean(who)
  return t and { t } or {}
end

---The stored entries of `c` (cleaned keys, valid entries only).
local function entries(c)
  local out = {}
  if type(c) == 'table' and type(c.tags) == 'table' then
    for k, v in pairs(c.tags) do
      if type(k) == 'string' and type(v) == 'table' and M.clean(k) == k then
        out[k] = v
      end
    end
  end
  return out
end

---The tags of comment `c` as shown: defaults and the ones set, minus the ones removed, sorted
---with the defaults first.
---@return string[]
function M.of(c)
  local e = entries(c)
  local out, seen = {}, {}
  for _, t in ipairs(M.defaults(c)) do
    if not (e[t] and e[t].off) and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  local set = {}
  for t, v in pairs(e) do
    if not v.off and not seen[t] then
      set[#set + 1] = t
    end
  end
  table.sort(set)
  vim.list_extend(out, set)
  return out
end

---Does `c` carry tag `t` (as shown)?
function M.has(c, t)
  return vim.tbl_contains(M.of(c), t)
end

---Tags of `c` set after it was made (by the user or an agent): not the ones given on import.
function M.touched(c)
  for _, v in pairs(entries(c)) do
    if (tonumber(v.at) or 0) > (tonumber(c.created_at) or 0) then
      return true
    end
  end
  return false
end

---Set (`on`) or remove tags on a copy of `c`. Returns the copy and whether anything changed, or
---nil and a message (too many tags).
---@param list string[] cleaned tags
---@return table? c, boolean|string changed_or_err
function M.apply(c, list, on, now)
  local out = vim.deepcopy(c)
  local e = entries(out)
  local shown = {}
  for _, t in ipairs(M.of(out)) do
    shown[t] = true
  end
  local changed = false
  local defaults = {}
  for _, t in ipairs(M.defaults(out)) do
    defaults[t] = true
  end
  for _, t in ipairs(list) do
    if on and not shown[t] then
      -- a default that was removed comes back by dropping its `off`
      e[t] = { at = now }
      shown[t], changed = true, true
    elseif not on and shown[t] then
      e[t] = { at = now, off = true }
      shown[t], changed = nil, true
    end
  end
  local n = 0
  for _ in pairs(shown) do
    n = n + 1
  end
  if n > M.MAX_TAGS then
    return nil, ('at most %d tags on a comment'):format(M.MAX_TAGS)
  end
  -- an `off` for a tag that is no default and was never on is noise: dropped
  for t, v in pairs(e) do
    if v.off and not defaults[t] and not (c.tags and c.tags[t]) then
      e[t] = nil
    end
  end
  out.tags = next(e) and e or nil
  return out, changed
end

---Replace the tags of a copy of `c` with `list` (as shown): what is missing is removed.
---@return table? c, boolean|string changed_or_err
function M.replace(c, list, now)
  local want = {}
  for _, t in ipairs(list) do
    want[t] = true
  end
  local drop = {}
  for _, t in ipairs(M.of(c)) do
    if not want[t] then
      drop[#drop + 1] = t
    end
  end
  local out, ch = M.apply(c, drop, false, now)
  if not out then
    return nil, ch
  end
  local out2, ch2 = M.apply(out, list, true, now)
  if not out2 then
    return nil, ch2
  end
  return out2, ch or ch2
end

---Merge two comments' tag maps: per tag the newest entry (ties: `a`'s).
function M.merge(a, b)
  if type(b) ~= 'table' or next(b) == nil then
    return a
  end
  if type(a) ~= 'table' or next(a) == nil then
    return vim.deepcopy(b)
  end
  local out = vim.deepcopy(a)
  for t, v in pairs(b) do
    local cur = out[t]
    if type(v) == 'table' and (type(cur) ~= 'table' or (tonumber(v.at) or 0) > (tonumber(cur.at) or 0)) then
      out[t] = vim.deepcopy(v)
    end
  end
  return out
end

---Every tag in use on `list` (comments), sorted, with how many carry it.
---@return {tag:string, n:integer}[]
function M.in_use(list)
  local n = {}
  for _, c in ipairs(list) do
    for _, t in ipairs(M.of(c)) do
      n[t] = (n[t] or 0) + 1
    end
  end
  local out = {}
  for t, k in pairs(n) do
    out[#out + 1] = { tag = t, n = k }
  end
  table.sort(out, function(x, y)
    return x.tag < y.tag
  end)
  return out
end

---"#pass #security" for display ('' without tags). `skip`: a tag left out (the author's name in
---a thread box, which says it already).
function M.text(list, skip)
  local out = {}
  for _, t in ipairs(list) do
    if t ~= skip then
      out[#out + 1] = '#' .. t
    end
  end
  return table.concat(out, ' ')
end

return M
