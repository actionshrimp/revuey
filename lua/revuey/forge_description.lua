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

local ENTITIES = {
  amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", nbsp = ' ', ensp = ' ', emsp = ' ', thinsp = ' ',
  mdash = '—', ndash = '–', hellip = '…', copy = '©', reg = '®', trade = '™', deg = '°', plusmn = '±',
  times = '×', divide = '÷', middot = '·', bull = '•', sect = '§', para = '¶', laquo = '«', raquo = '»',
  lsquo = '‘', rsquo = '’', ldquo = '“', rdquo = '”', sbquo = '‚', bdquo = '„', prime = '′', Prime = '″',
  larr = '←', rarr = '→', uarr = '↑', darr = '↓', harr = '↔', lArr = '⇐', rArr = '⇒', hArr = '⇔',
  ne = '≠', le = '≤', ge = '≥', asymp = '≈', infin = '∞', minus = '−', check = '✓', cross = '✗',
  euro = '€', pound = '£', yen = '¥', cent = '¢', micro = 'µ', frac12 = '½', frac14 = '¼', frac34 = '¾',
  shy = '', zwj = '', zwnj = '',
}

---UTF-8 for a code point (no surrogates, no controls but tab: those are dropped).
local function utf8_char(n)
  if n < 32 and n ~= 9 or n == 127 or (n >= 0xD800 and n <= 0xDFFF) or n >= 0x110000 or n < 1 then
    return ''
  elseif n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  elseif n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40, 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local function entities(s)
  if not s:find('&', 1, true) then
    return s
  end
  return (s:gsub('&(#?)([xX]?)(%w+);', function(hash, x, name)
    if hash == '#' then
      local n = tonumber(name, x ~= '' and 16 or 10)
      return n and utf8_char(n) or nil
    end
    return ENTITIES[name] or ENTITIES[name:lower()]
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

---Markdown images, inline `![alt](url "title")` and by reference `![alt][ref]`, as text (a
---linked image keeps its link around the text). Scanned by hand in one pass: every search stops
---at the next bracket or parenthesis, so a hostile body (`![![![...`) stays linear.
local function images(s)
  if not s:find('![', 1, true) then
    return s
  end
  local out, i = {}, 1
  while true do
    local a = s:find('![', i, true)
    if not a then
      break
    end
    local close = s:find('[%[%]]', a + 2)
    local e
    if close and s:sub(close, close) == ']' then
      e = select(2, s:find('^%([^()%[%]]*%)', close + 1)) or select(2, s:find('^%[[^%[%]]*%]', close + 1))
    end
    if e then
      out[#out + 1] = s:sub(i, a - 1)
      out[#out + 1] = image_text(s:sub(a + 2, close - 1))
      i = e + 1
    else
      out[#out + 1] = s:sub(i, a)
      i = a + 1
    end
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

local TAG_MAX = 512 -- longest tag looked at (a long `<img src=... alt=...>` is ~250 bytes)

---End of the HTML tag starting at `a` (`<` then a letter or `/`): its `>`, past quoted
---attribute values (`<a title="x>y">`), or nil when it does not close on this line within
---TAG_MAX bytes (the bound keeps `<a "<a "<a "...` linear).
local function tag_end(s, a)
  local j, limit = a + 1, a + TAG_MAX
  while true do
    local k = s:find('[\'"<>]', j)
    if not k or k > limit then
      return nil
    end
    local c = s:sub(k, k)
    if c == '>' then
      return k
    elseif c == '<' then
      return nil -- `a < b` or another tag: this one never closed
    end
    local q = s:find(c, k + 1, true)
    if not q then
      return nil
    end
    j = q + 1
  end
end

---HTML tags as their text (tag_text), unknown ones and a lone `<` kept.
local function tags(s)
  if not s:find('<', 1, true) then
    return s
  end
  local out, i = {}, 1
  while true do
    local a = s:find('<', i, true)
    if not a then
      break
    end
    local e = s:sub(a + 1, a + 1):match('[%a/]') and tag_end(s, a)
    local t = e and tag_text(s:sub(a, e))
    if t then
      out[#out + 1] = s:sub(i, a - 1)
      out[#out + 1] = t
      i = e + 1
    else
      out[#out + 1] = s:sub(i, a)
      i = a + 1
    end
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

---Text outside inline code: images, HTML tags, entities.
local function plain_segment(s)
  return entities(tags(images(s)))
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
---the rest, whether a comment is still open, and whether anything was removed. Not inside
---inline code (`` `<!--` `` is text) or an HTML tag's attribute values (`<a title="<!--">`);
---`<!-->` and `<!--->` are complete (empty) comments, as in CommonMark.
local function strip_comments(line, open)
  local out, i, removed, n = {}, 1, false, #line
  while i <= n do
    if open then
      local e = line:find('-->', i, true)
      removed = true
      if not e then
        return table.concat(out), true, true
      end
      open, i = false, e + 3
    else
      local a = line:find('[`<]', i)
      if not a then
        out[#out + 1] = line:sub(i)
        break
      end
      out[#out + 1] = line:sub(i, a - 1)
      local c = line:sub(a, a)
      if c == '`' then
        local _, b = line:find('^`+', a)
        local _, d = line:find(line:sub(a, b), b + 1, true)
        -- a code span is kept whole; an unmatched run of backticks is text
        out[#out + 1] = line:sub(a, d or b)
        i = (d or b) + 1
      elseif line:sub(a, a + 3) == '<!--' then
        removed = true
        local empty = line:match('^<!%-%-%->', a) or line:match('^<!%-%->', a)
        if empty then
          i = a + #empty
        else
          open, i = true, a + 4
        end
      elseif line:sub(a + 1, a + 1):match('[%a/]') and tag_end(line, a) then
        -- an HTML tag: kept whole, so `<!--` in an attribute value starts no comment
        local stop = tag_end(line, a)
        out[#out + 1] = line:sub(a, stop)
        i = stop + 1
      else
        out[#out + 1] = c
        i = a + 1
      end
    end
  end
  return table.concat(out), open, removed
end

local function fence_of(line)
  local indent, mark = line:match('^(%s*)(```+)')
  if not mark then
    indent, mark = line:match('^(%s*)(~~~+)')
  end
  if mark then -- at any indent (a fence inside a list item is indented)
    return mark
  end
end

local function is_blank(l)
  return l:match('^%s*$') ~= nil
end

local function is_list(l)
  return l:match('^%s*[-*+]%s') or l:match('^%s*%d+[.)]%s')
end

local memo, memo_n = {}, 0

---The description as the light Markdown prose.render knows ('' when nothing is left: no body,
---only a template's comments, whitespace). Memoised by body.
---@param body? string
---@return string
function M.clean(body)
  if type(body) ~= 'string' or body == '' then
    return ''
  end
  -- the signature check cleans every lookup's bodies: once per distinct body
  local hit = memo[body]
  if hit then
    return hit
  end
  local text = M.clean_uncached(body)
  if memo_n >= 64 then
    memo, memo_n = {}, 0
  end
  memo[body], memo_n = text, memo_n + 1
  return text
end

---M.clean without the memo.
function M.clean_uncached(body)
  -- control characters (ESC sequences and the like) are never drawn: dropped, tabs kept
  body = body:gsub('\r\n?', '\n'):gsub('[%z\1-\8\11\12\14-\31\127]', '')
  local src = vim.split(body, '\n', { plain = true })
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
  local function delimiter(l)
    return l and l:find('-', 1, true) and l:find('|', 1, true) and l:match('^[%s|:%-]+$') ~= nil
  end
  local fence, in_table = false, false
  local src = vim.split(md or '', '\n', { plain = true })
  for k, l in ipairs(src) do
    if l:match('^%s*```') then
      fence, in_table = not fence, false
      table.insert(seg('md').lines, l)
    elseif fence then
      table.insert(seg('md').lines, l)
    elseif l == '---' then
      in_table = false
      seg('rule')
    elseif l:match('^%s*|') or (in_table and l:find('|', 1, true)) or (l:find('|', 1, true) and delimiter(src[k + 1])) then
      -- a table row: with a leading `|`, or any row of a table whose header has a delimiter row
      in_table = true
      table.insert(seg('table').lines, vim.trim(l))
    else
      in_table = false
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
        if delimiter(l) or (l:match('^[%s:%-]+$') and l:find('-', 1, true)) then
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
