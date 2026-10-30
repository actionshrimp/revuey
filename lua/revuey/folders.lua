-- Folders in the file panel: the review's files grouped by directory (one header per directory,
-- its files under it), the leading directories every header shares, and headers abbreviated to
-- the panel's width. No window or buffer UI (unit tested headlessly).
local M = {}

local strwidth = vim.api.nvim_strwidth

---Directory of a repo-relative path ('' at the repository root).
function M.dir(path)
  return path:match('^(.*)/[^/]*$') or ''
end

local function base(path)
  return path:match('([^/]*)$')
end

---Path components of a directory ({} for the root).
local function segments(dir)
  return dir == '' and {} or vim.split(dir, '/', { plain = true })
end

---The files grouped by directory, groups contiguous: directories in tree order (a directory
---before its subdirectories, compared component by component, the root first), files sorted by
---name within each. This is `git diff`'s path order with each directory's own files gathered
---before its subdirectories (as `ls -R` lists them). Stable; returns a new list.
---@generic T: {path:string}
---@param files T[]
---@return T[]
function M.order(files)
  local keyed = {}
  for i, f in ipairs(files) do
    keyed[i] = { f = f, segs = segments(M.dir(f.path)), name = base(f.path), i = i }
  end
  table.sort(keyed, function(a, b)
    local sa, sb = a.segs, b.segs
    for k = 1, math.min(#sa, #sb) do
      if sa[k] ~= sb[k] then
        return sa[k] < sb[k]
      end
    end
    if #sa ~= #sb then
      return #sa < #sb
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.i < b.i
  end)
  local out = {}
  for i, k in ipairs(keyed) do
    out[i] = k.f
  end
  return out
end

---Runs of consecutive files in the same directory: {dir, first, last} (file indexes). O(n).
---@param files {path:string}[]
---@return {dir:string, first:integer, last:integer}[]
function M.groups(files)
  local out = {}
  for i, f in ipairs(files) do
    local d = M.dir(f.path)
    local g = out[#out]
    if g and g.dir == d then
      g.last = i
    else
      out[#out + 1] = { dir = d, first = i, last = i }
    end
  end
  return out
end

---Leading directories every group's directory shares, keeping at least the last component of
---each (so no header becomes empty). '' when there is a single group (dropping its prefix would
---only add a line), files at the root, or nothing shared.
---@param dirs string[]
function M.common_prefix(dirs)
  if #dirs < 2 then
    return ''
  end
  local common
  for _, d in ipairs(dirs) do
    local segs = segments(d)
    if #segs == 0 then
      return ''
    end
    if not common then
      common = { unpack(segs, 1, #segs - 1) }
    else
      local n = math.min(#common, #segs - 1)
      for k = 1, n do
        if common[k] ~= segs[k] then
          n = k - 1
          break
        end
      end
      for k = #common, n + 1, -1 do
        common[k] = nil
      end
    end
    if #common == 0 then
      return ''
    end
  end
  return table.concat(common, '/')
end

---A directory component cut to its first character (two for a dotted name: `.github` -> `.g`).
local function short(seg)
  local n = seg:sub(1, 1) == '.' and 2 or 1
  return vim.fn.strcharpart(seg, 0, n)
end

---Cut from the left to `width` cells, keeping the end ('…' first).
local function cut_left(str, width)
  if width <= 0 then
    return ''
  end
  local n = vim.fn.strchars(str)
  local w, k = 0, n
  while k > 0 do
    local cw = strwidth(vim.fn.strcharpart(str, k - 1, 1))
    if w + cw > width - 1 then
      break
    end
    w, k = w + cw, k - 1
  end
  return '…' .. vim.fn.strcharpart(str, k)
end

---`path` in at most `width` display cells, fish-shell style: the first and last components stay
---whole and the middle ones are cut to their first character, the one furthest from the leaf
---first, until it fits; then `first/…/last`, then `…/last`, then the last cut from the left (its
---end stays).
function M.abbreviate(path, width)
  if strwidth(path) <= width then
    return path
  end
  local segs = vim.split(path, '/', { plain = true })
  for k = 2, #segs - 1 do
    segs[k] = short(segs[k])
    local p = table.concat(segs, '/')
    if strwidth(p) <= width then
      return p
    end
  end
  local leaf = segs[#segs]
  for _, p in ipairs({ segs[1] .. '/…/' .. leaf, '…/' .. leaf }) do
    if #segs >= 2 and strwidth(p) <= width then
      return p
    end
  end
  return cut_left(leaf, width)
end

return M
