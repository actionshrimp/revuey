-- Map line numbers between two versions of a file (e.g. the HEAD blob and the working-tree
-- buffer) using a real diff, so unchanged lines map by position even when their text is
-- duplicated elsewhere. Pure: no editor UI.
local M = {}

local function normalize(text)
  text = text:gsub('\r\n', '\n')
  if text ~= '' and text:sub(-1) ~= '\n' then
    text = text .. '\n'
  end
  return text
end

---Map line numbers through diff hunks. `side` 1 maps a->b, 2 maps b->a (same hunks, so the two
---directions are exact inverses of each other).
local function mapper(hunks, count, side)
  return function(lnum)
    if lnum < 1 or lnum > count then
      return nil
    end
    local shift = 0
    for _, h in ipairs(hunks) do
      local s, c, oc
      if side == 1 then
        s, c, oc = h[1], h[2], h[4]
      else
        s, c, oc = h[3], h[4], h[2]
      end
      if c == 0 then
        -- pure insertion on the other side, after line s
        if s < lnum then
          shift = shift + oc
        else
          break
        end
      else
        if lnum < s then
          break
        elseif lnum < s + c then
          return nil -- changed or deleted
        end
        shift = shift + oc - c
      end
    end
    return lnum + shift
  end
end

---One diff, both directions.
---@param a string old text
---@param b string new text
---@return fun(lnum: integer): integer? a_to_b
---@return fun(lnum: integer): integer? b_to_a
function M.both(a, b)
  a, b = normalize(a), normalize(b)
  local _, a_count = a:gsub('\n', '')
  local _, b_count = b:gsub('\n', '')
  local hunks = {}
  if a ~= b then
    hunks = vim.text.diff(a, b, { result_type = 'indices', algorithm = 'histogram' }) --[[@as integer[][] ]]
  end
  return mapper(hunks, a_count, 1), mapper(hunks, b_count, 2)
end

---@param a string old text
---@param b string new text
---@return fun(lnum: integer): integer? map from a line in `a` to the same line in `b`, or nil
---  when that line was changed/deleted (or is out of range)
function M.new(a, b)
  return (M.both(a, b))
end

---Map with texts given as line lists.
function M.from_lines(a_lines, b_lines)
  return M.new(table.concat(a_lines, '\n') .. '\n', table.concat(b_lines, '\n') .. '\n')
end

return M
