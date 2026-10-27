-- The pull request description shown at the top of the diff view (pure): GitHub Markdown as its
-- author wrote it (`body`) cleaned into the light Markdown `prose.lua` renders, then laid out as
-- rows: a title row, the body (wrapped, indented) and a blank row, with the part past
-- `max_lines` marked as a fold. Nothing is fetched: images and links stay text.
--
-- Cleaning, outside code (fenced blocks and inline `code` are left alone):
--   * HTML comments (`<!-- ... -->`, PR templates' instructions) are removed, across lines too;
--     a line that held only a comment goes, so a template's comments leave no blank runs;
--   * images become text, `(image: alt)`, Markdown and `<img>` alike;
--   * the HTML GitHub allows is turned into its Markdown or dropped, keeping the text:
--     `<details>`/`<summary>` (the summary as a `▸` line, the content shown), `<br>`, `<p>`,
--     `<b>`, `<code>`, `<a>`, headings, lists...; tags not in that list stay as typed
--     (`Vec<String>` is text);
--   * entities (`&amp;`, `&#39;`...), task list boxes (`- [x]` -> `☑`), setext headings,
--     `~~~` fences; blank runs collapse to one line.
-- Tables and horizontal rules, which prose would run into a paragraph, get rows of their own.
local prose = require('revuey.prose')

local M = {}

M.MAX_LINES = 6 -- body lines shown while collapsed (forge.description.max_lines)

-- HTML tags GitHub renders (and the PR templates use) that are replaced by their text
local TAGS = {}
for _, t in ipairs({
  'a', 'abbr', 'b', 'blockquote', 'br', 'center', 'code', 'dd', 'del', 'details', 'div', 'dl', 'dt', 'em',
  'font', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'i', 'img', 'ins', 'kbd', 'li', 'mark', 'ol', 'p',
  'picture', 'pre', 'q', 's', 'samp', 'small', 'source', 'span', 'strike', 'strong', 'sub', 'summary',
  'sup', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'tt', 'u', 'ul', 'var', 'video', 'input',
}) do
  TAGS[t] = true
end

local ENTITIES = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", nbsp = ' ', mdash = '—', ndash = '–', hellip = '…', copy = '©' }

local function entities(s)
  return (s:gsub('&(#?)([xX]?)(%w+);', function(hash, x, name)
    if hash == '#' then
      local n = tonumber(name, x ~= '' and 16 or 10)
      if n and n > 0 and n < 0x110000 then
        return vim.fn.nr2char(n)
      end
      return nil
    end
    return ENTITIES[name:lower()]
  end))
end

local function attr(tag, name)
  return tag:match(name .. '%s*=%s*"([^"]*)"') or tag:match(name .. "%s*=%s*'([^']*)'")
end

local function image_text(alt)
  alt = vim.trim(alt or '')
  return alt ~= '' and ('(image: ' .. alt .. ')') or '(image)'
end

---One HTML tag (`<...>` including brackets) as Markdown, or nil to keep it as typed.
local function tag_text(tag)
  local url = tag:match('^<(https?://[^%s<>]+)>$')
  if url then -- an autolink
    return url
  end
  local close, name = tag:match('^<(/?)(%a[%w]*)')
  name = name and name:lower()
  if not name or not TAGS[name] then
    return nil
  end
  if name == 'img' then
    return close == '' and image_text(attr(tag, 'alt')) or ''
  elseif name == 'video' or name == 'source' or name == 'picture' then
    return (close == '' and name == 'video') and '(video)' or ''
  elseif name == 'input' then -- a task list box written in HTML
    return tag:find('checked', 1, true) and '☑ ' or '☐ '
  elseif name == 'br' then
    return '\n'
  elseif name == 'hr' then
    return '\n---\n'
  elseif name == 'summary' then
    return close == '' and '\n▸ ' or '\n'
  elseif name == 'li' then
    return close == '' and '\n- ' or ''
  elseif name:match('^h%d$') then
    return close == '' and ('\n' .. ('#'):rep(tonumber(name:sub(2))) .. ' ') or '\n'
  elseif name == 'b' or name == 'strong' then
    return '**'
  elseif name == 'i' or name == 'em' then
    return '*'
  elseif name == 'code' or name == 'tt' or name == 'kbd' or name == 'samp' then
    return '`'
  elseif name == 'details' or name == 'p' or name == 'div' or name == 'ul' or name == 'ol' or name == 'table'
    or name == 'tr' or name == 'blockquote' or name == 'pre' or name == 'center' or name == 'dl' or name == 'dt' or name == 'dd' then
    return '\n'
  elseif name == 'td' or name == 'th' then
    return close == '' and ' ' or ' |'
  end
  return ''
end

---Text outside inline code: images, HTML tags, entities.
local function plain_segment(s)
  -- Markdown images, inline and by reference (a linked image keeps its link around the text)
  s = s:gsub('!%[([^%]]*)%]%b()', image_text)
  s = s:gsub('!%[([^%]]*)%]%[[^%]]*%]', image_text)
  s = s:gsub('<[^<>]+>', function(tag)
    return tag_text(tag)
  end)
  return entities(s)
end

---A line outside fenced code: inline code spans kept as they are, the rest cleaned.
local function clean_line(line)
  local out, i = {}, 1
  while i <= #line do
    local a, b = line:find('`+', i)
    if not a then
      out[#out + 1] = plain_segment(line:sub(i))
      break
    end
    local ticks = line:sub(a, b)
    local c, d = line:find(ticks, b + 1, true)
    if not c then
      out[#out + 1] = plain_segment(line:sub(i))
      break
    end
    out[#out + 1] = plain_segment(line:sub(i, a - 1))
    out[#out + 1] = line:sub(a, d)
    i = d + 1
  end
  return table.concat(out)
end

---Remove HTML comments from a line; `open` says a comment started on an earlier line. Returns
---the rest, whether a comment is still open, and whether anything was removed.
local function strip_comments(line, open)
  local out, i, removed = {}, 1, false
  while i <= #line do
    if open then
      local e = line:find('-->', i, true)
      removed = true
      if not e then
        return table.concat(out), true, true
      end
      open, i = false, e + 3
    else
      local a = line:find('<!--', i, true)
      if not a then
        out[#out + 1] = line:sub(i)
        break
      end
      out[#out + 1] = line:sub(i, a - 1)
      open, i, removed = true, a + 4, true
    end
  end
  return table.concat(out), open, removed
end

local function fence_of(line)
  local indent, mark = line:match('^(%s*)(```+)')
  if not mark then
    indent, mark = line:match('^(%s*)(~~~+)')
  end
  if mark and #indent <= 3 then
    return mark
  end
end

local function is_blank(l)
  return l:match('^%s*$') ~= nil
end

local function is_list(l)
  return l:match('^%s*[-*+]%s') or l:match('^%s*%d+[.)]%s')
end

---The description as the light Markdown prose.render knows ('' when nothing is left: no body,
---only a template's comments, whitespace).
---@param body? string
---@return string
function M.clean(body)
  if type(body) ~= 'string' or body == '' then
    return ''
  end
  local src = vim.split((body:gsub('\r\n?', '\n')), '\n', { plain = true })
  local lines = {}
  local fence, comment = nil, false
  for _, raw in ipairs(src) do
    if fence then
      local m = fence_of(raw)
      if m and m:sub(1, 1) == fence:sub(1, 1) and #m >= #fence and is_blank(raw:gsub('^%s*[`~]+', '')) then
        fence = nil
        lines[#lines + 1] = '```' -- prose knows backtick fences only
      else
        lines[#lines + 1] = raw
      end
    else
      local line, removed
      line, comment, removed = strip_comments(raw, comment)
      if removed and is_blank(line) then
        -- a line that held only a comment: gone, not a blank line
      else
        local m = fence_of(line)
        if m then
          fence = m
          lines[#lines + 1] = '```'
        else
          line = clean_line(line):gsub('%s+$', '')
          for _, l in ipairs(vim.split(line, '\n', { plain = true })) do
            -- task list boxes
            l = l:gsub('^(%s*[-*+]%s+)%[[xX]%]%s', '%1☑ '):gsub('^(%s*[-*+]%s+)%[ %]%s', '%1☐ ')
            local prev = lines[#lines]
            local setext = l:match('^%s*=+%s*$') and '#' or (l:match('^%s*%-%-+%s*$') and '##')
            if setext and prev and not is_blank(prev) and not is_list(prev) and not prev:match('^%s*[#>|]') and prev ~= '```' then
              lines[#lines] = setext .. ' ' .. vim.trim(prev)
            elseif l:match('^%s*%*%s*%*%s*%*[%s%*]*$') or l:match('^%s*_%s*_%s*_[%s_]*$') or l:match('^%s*%-%s*%-%s*%-[%s%-]*$') then
              lines[#lines + 1] = '---' -- a rule (render gives it a row)
            else
              lines[#lines + 1] = l
            end
          end
        end
      end
    end
  end
  if fence then
    lines[#lines + 1] = '```'
  end
  -- blank runs to one line, none at the ends
  local out = {}
  for _, l in ipairs(lines) do
    if is_blank(l) then
      if #out > 0 and out[#out] ~= '' then
        out[#out + 1] = ''
      end
    else
      out[#out + 1] = l
    end
  end
  while #out > 0 and out[#out] == '' do
    out[#out] = nil
  end
  -- a fence left empty by the cleaning, or only fences: nothing to show
  local text = table.concat(out, '\n')
  if vim.trim((text:gsub('```', ''))) == '' then
    return ''
  end
  return text
end

---Rows of cleaned Markdown at `width` cells: prose for the text, a row per table row and rule.
---@return {text:string, hls:table}[]
function M.render_body(md, width)
  local segs, cur = {}, nil
  local function seg(kind)
    if not cur or cur.kind ~= kind or kind == 'rule' then
      cur = { kind = kind, lines = {} }
      segs[#segs + 1] = cur
    end
    return cur
  end
  local fence = false
  for _, l in ipairs(vim.split(md or '', '\n', { plain = true })) do
    if l:match('^%s*```') then
      fence = not fence
      table.insert(seg('md').lines, l)
    elseif fence then
      table.insert(seg('md').lines, l)
    elseif l == '---' then
      seg('rule')
    elseif l:match('^%s*|') then
      table.insert(seg('table').lines, vim.trim(l))
    else
      table.insert(seg('md').lines, l)
    end
  end
  local rows = {}
  local function add_blank()
    if #rows > 0 and rows[#rows].text ~= '' then
      rows[#rows + 1] = { text = '', hls = {} }
    end
  end
  for _, sg in ipairs(segs) do
    if sg.kind == 'rule' then
      add_blank()
      local t = ('─'):rep(math.min(width, 40))
      rows[#rows + 1] = { text = t, hls = { { 0, #t, 'RevueyForgeDescriptionRule' } } }
      rows[#rows + 1] = { text = '', hls = {} }
    elseif sg.kind == 'table' then
      add_blank()
      for _, l in ipairs(sg.lines) do
        if l:match('^|?[%s:|%-]+$') and l:find('-', 1, true) then
          local t = ('─'):rep(math.min(width, math.max(3, vim.api.nvim_strwidth(l))))
          rows[#rows + 1] = { text = t, hls = { { 0, #t, 'RevueyForgeDescriptionRule' } } }
        else
          local text, spans = prose.inline(l)
          rows[#rows + 1] = { text = text, hls = spans }
        end
      end
      rows[#rows + 1] = { text = '', hls = {} }
    else
      local r = prose.render(table.concat(sg.lines, '\n'), width)
      if #r > 0 then
        add_blank()
        for _, x in ipairs(r) do
          rows[#rows + 1] = { text = x.text, hls = x.hls }
        end
      end
    end
  end
  while #rows > 0 and rows[#rows].text == '' do
    rows[#rows] = nil
  end
  while #rows > 0 and rows[1].text == '' do
    table.remove(rows, 1)
  end
  return rows
end

local INDENT = '  '

---Rows for one PR's description: the title (`PR #12 · title`, `draft` when it is one), the body
---indented, then a blank row. A body longer than `max_lines` + 1 rows has the rest as a fold
---(`fold = {first, last}`, indices into `rows`, the rows a collapsed description hides).
---@param pr {number:integer, title:string, draft?:boolean}
---@param md string cleaned body (M.clean), not empty
---@param width integer text width of the window
---@param o? {max_lines?:integer}
---@return {rows:{text:string, hls:table}[], fold?:integer[], more?:integer}
function M.render(pr, md, width, o)
  o = o or {}
  local max = math.max(1, o.max_lines or M.MAX_LINES)
  local num = 'PR #' .. pr.number
  local title = num .. ' · ' .. ((pr.title or ''):gsub('[\r\n]+', ' '))
  local hls = { { 0, #title, 'RevueyForgeDescriptionTitle' }, { 0, #num, 'RevueyForgeNumber' } }
  if pr.draft then
    hls[#hls + 1] = { #title, #title + #' · draft', 'RevueyForgeDraft' }
    title = title .. ' · draft'
  end
  local rows = { { text = title, hls = hls } }
  local body = M.render_body(md, math.max(20, width - #INDENT))
  for _, r in ipairs(body) do
    local shifted = {}
    for _, hl in ipairs(r.hls or {}) do
      shifted[#shifted + 1] = { hl[1] + #INDENT, hl[2] + #INDENT, hl[3] }
    end
    rows[#rows + 1] = { text = r.text == '' and '' or (INDENT .. r.text), hls = shifted }
  end
  local out = { rows = rows }
  -- fold only when it hides at least two rows (a one-row fold saves nothing)
  if #body > max + 1 then
    out.fold = { 1 + max + 1, 1 + #body }
    out.more = #body - max
  end
  rows[#rows + 1] = { text = '', hls = {} }
  return out
end

return M
