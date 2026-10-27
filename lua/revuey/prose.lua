-- Light markdown for guide prose (pure): word-wraps to a width and returns plain buffer lines plus
-- highlight spans. Supports headings, paragraphs, **bold**, *italic*, `code`, [links](url),
-- bullet and numbered lists, block quotes, GitHub callouts (> [!IMPORTANT] ...) and fenced code.
-- Markers are removed from the text; spans carry the styling.
local M = {}

local width_of = vim.api.nvim_strwidth

---Parse inline markup into plain text + spans {start, end (exclusive), group} (0-based bytes).
---@param s string
---@param base_hl? string group for the whole text
function M.inline(s, base_hl)
  local out, spans = {}, {}
  local pos, i, n = 0, 1, #s
  -- the first `_` at or after a position that can close emphasis (not followed by a word
  -- character), remembered for the range it answers: openers come left to right, so finding
  -- them all is one pass (" _a _a _a..." would otherwise rescan the rest for each)
  local us_from, us_at
  local function us_close(from)
    if us_from and from >= us_from and (us_at == false or from <= us_at) then
      return us_at or nil
    end
    local j = s:find('_', from, true)
    while j and s:sub(j + 1, j + 1):match('[%w_]') do
      j = s:find('_', j + 1, true)
    end
    us_from, us_at = from, j or false
    return j
  end
  -- the first `)` or whitespace at or after a position, remembered for the range it answers
  local ue_from, ue_at
  local function url_end(from)
    if ue_from and from >= ue_from and (ue_at == false or from <= ue_at) then
      return ue_at or nil
    end
    local j = s:find('[)%s]', from)
    ue_from, ue_at = from, j or false
    return j
  end
  local function emit(text, hl)
    if text == '' then
      return
    end
    out[#out + 1] = text
    if hl then
      spans[#spans + 1] = { pos, pos + #text, hl }
    end
    pos = pos + #text
  end
  while i <= n do
    local c = s:sub(i, i)
    if c == '`' then
      local j = s:find('`', i + 1, true)
      if j then
        emit(s:sub(i + 1, j - 1), 'RevueyGuideCode')
        i = j + 1
      else
        emit(c)
        i = i + 1
      end
    elseif s:sub(i, i + 1) == '**' or s:sub(i, i + 1) == '__' then
      local mark = s:sub(i, i + 1)
      local j = s:find(mark, i + 2, true)
      if j and j > i + 2 then
        -- nested code inside bold: keep it simple, style the whole run bold
        local inner, ispans = M.inline(s:sub(i + 2, j - 1))
        for _, sp in ipairs(ispans) do
          spans[#spans + 1] = { pos + sp[1], pos + sp[2], sp[3] }
        end
        spans[#spans + 1] = { pos, pos + #inner, 'RevueyGuideBold' }
        out[#out + 1] = inner
        pos = pos + #inner
        i = j + 2
      else
        emit(mark)
        i = i + 2
      end
    elseif (c == '*' or (c == '_' and (i == 1 or s:sub(i - 1, i - 1):match('[%s(]')))) and s:sub(i + 1, i + 1):match('%S') then
      -- *em* anywhere; _em_ only at word boundaries (snake_case stays text)
      local j
      if c == '_' then
        j = us_close(i + 1)
      else
        j = s:find(c, i + 1, true)
      end
      if j and s:sub(j - 1, j - 1):match('%S') then
        emit(s:sub(i + 1, j - 1), 'RevueyGuideItalic')
        i = j + 1
      else
        emit(c)
        i = i + 1
      end
    elseif c == '[' then
      -- the text stops at the next bracket (so `[[[...` is one pass) and the URL ends at the
      -- first `)` or space after it, found once for a run of links (url_end), so `[a](` repeated
      -- is one pass too; URLs may hold `[` (`?filter[status]=open`)
      local text, p = s:match('^%[([^%[%]]+)%]%(()', i)
      local e = p and url_end(p)
      if text and e and e > p and s:sub(e, e) == ')' then
        emit(text, 'RevueyGuideLink')
        i = e + 1
      else
        emit(c)
        i = i + 1
      end
    else
      local j = s:find('[`*_%[]', i + 1)
      -- a lone '_' inside words (snake_case) is text; only '__' is markup
      while j and s:sub(j, j) == '_' and s:sub(j + 1, j + 1) ~= '_' and s:sub(j - 1, j - 1):match('[%w_]') do
        j = s:find('[`*_%[]', j + 1)
      end
      emit(s:sub(i, (j or n + 1) - 1))
      i = j or n + 1
    end
  end
  local text = table.concat(out)
  if base_hl and #text > 0 then
    table.insert(spans, 1, { 0, #text, base_hl })
  end
  return text, spans
end

---Greedy word wrap of `text` (with spans) into lines of at most `width` cells. `first` and `rest`
---are prefixes for the first and following lines (with their own highlight `prefix_hl`).
---@return {text:string, hls:table}[]
function M.wrap(text, spans, width, first, rest, prefix_hl)
  first, rest = first or '', rest or first or ''
  local words = {}
  for s, e in text:gmatch('()%S+()') do
    words[#words + 1] = { s, e - 1 }
  end
  local lines = {}
  local function emit(a, b) -- byte range [a, b] of text (1-based, inclusive)
    local prefix = #lines == 0 and first or rest
    local seg = a and text:sub(a, b) or ''
    local hls = {}
    if prefix_hl and #prefix > 0 then
      hls[#hls + 1] = { 0, #prefix, prefix_hl }
    end
    if a then
      for _, sp in ipairs(spans) do
        local s0, e0 = math.max(sp[1], a - 1), math.min(sp[2], b)
        if e0 > s0 then
          hls[#hls + 1] = { #prefix + s0 - (a - 1), #prefix + e0 - (a - 1), sp[3] }
        end
      end
    end
    -- off: byte offset of this line in the paragraph's text; pre: bytes of prefix before it
    lines[#lines + 1] = { text = prefix .. seg, hls = hls, off = a and (a - 1) or 0, pre = #prefix }
  end
  if #words == 0 then
    emit(nil)
    return lines
  end
  local start, last = words[1][1], words[1][2]
  for k = 2, #words do
    local w = words[k]
    local prefix = #lines == 0 and first or rest
    if width_of(prefix .. text:sub(start, w[2])) > width then
      emit(start, last)
      start = w[1]
    end
    last = w[2]
  end
  emit(start, last)
  return lines
end

local CALLOUTS = {
  NOTE = 'RevueyGuideNoteCallout',
  TIP = 'RevueyGuideTip',
  IMPORTANT = 'RevueyGuideImportant',
  WARNING = 'RevueyGuideWarning',
  CAUTION = 'RevueyGuideCaution',
}

---Render markdown to lines of at most `width` cells.
---@param md string
---@param width integer
---@param opts? {base_hl?: string}
---@return {text:string, hls:table}[]
function M.render(md, width, opts)
  opts = opts or {}
  width = math.max(width, 20)
  local src = vim.split((md or ''):gsub('\r\n', '\n'), '\n', { plain = true })
  local out = {}
  local para = 0 -- block counter: each output line knows its block (para) and offset (off)
  local function tag(from)
    for k = from, #out do
      out[k].para = out[k].para or para
    end
  end
  local function blank()
    if #out > 0 and out[#out].text ~= '' then
      out[#out + 1] = { text = '', hls = {} }
    end
  end
  local function paragraph(text, first, rest, prefix_hl, base_hl)
    local plain, spans = M.inline(text, base_hl or opts.base_hl)
    para = para + 1
    local from = #out + 1
    vim.list_extend(out, M.wrap(plain, spans, width, first, rest, prefix_hl))
    tag(from)
  end
  local i = 1
  while i <= #src do
    local line = src[i]
    local trimmed = vim.trim(line)
    if trimmed == '' then
      blank()
      i = i + 1
    elseif trimmed:match('^```') then
      blank()
      i = i + 1
      while i <= #src and not vim.trim(src[i]):match('^```') do
        local t = '  ' .. src[i]
        para = para + 1
        out[#out + 1] = { text = t, hls = { { 0, #t, 'RevueyGuideCode' } }, para = para, off = 0, pre = 2 }
        i = i + 1
      end
      i = i + 1
      blank()
    elseif trimmed:match('^#+%s') then
      blank()
      paragraph(trimmed:gsub('^#+%s+', ''), '', '', nil, 'RevueyGuideHeading')
      i = i + 1
    elseif trimmed:match('^>') then
      -- block quote / callout: gather the quoted lines
      local body = {}
      while i <= #src and vim.trim(src[i]):match('^>') do
        body[#body + 1] = (vim.trim(src[i]):gsub('^>%s?', ''))
        i = i + 1
      end
      local kind = body[1] and body[1]:match('^%[!(%u+)%]')
      local hl = kind and CALLOUTS[kind] or 'RevueyGuideQuote'
      blank()
      if kind then
        body[1] = vim.trim(body[1]:gsub('^%[!%u+%]', ''))
        local label = '▎ ' .. kind:sub(1, 1) .. kind:sub(2):lower()
        local rest_text = vim.trim(table.concat(body, ' '))
        para = para + 1
        if rest_text == '' then
          out[#out + 1] = { text = label, hls = { { 0, #label, hl } }, para = para, off = 0, pre = #label }
        else
          local plain, spans = M.inline(rest_text)
          -- label on the first line, in the callout colour
          local lines = M.wrap(plain, spans, width, label .. ': ', '▎ ', hl)
          table.insert(lines[1].hls, 1, { 0, #label + 1, hl })
          for _, l in ipairs(lines) do
            -- the bar keeps the callout colour; the label is bold
            l.hls[#l.hls + 1] = { 0, #'▎', hl }
          end
          lines[1].hls[#lines[1].hls + 1] = { #'▎ ', #label, 'RevueyGuideBold' }
          local from = #out + 1
          vim.list_extend(out, lines)
          tag(from)
        end
      else
        paragraph(table.concat(body, ' '), '▎ ', '▎ ', hl, 'RevueyGuideQuoteText')
      end
      blank()
    elseif trimmed:match('^[-*+]%s') or trimmed:match('^%d+[.)]%s') then
      -- list item, with continuation lines that are indented
      local indent = #line:match('^(%s*)')
      local marker = trimmed:match('^([-*+])%s') and '•' or trimmed:match('^(%d+[.)])')
      local text = trimmed:gsub('^[-*+]%s+', ''):gsub('^%d+[.)]%s+', '')
      i = i + 1
      while i <= #src and vim.trim(src[i]) ~= '' and src[i]:match('^%s+') and not vim.trim(src[i]):match('^[-*+]%s')
        and not vim.trim(src[i]):match('^%d+[.)]%s')
      do
        text = text .. ' ' .. vim.trim(src[i])
        i = i + 1
      end
      local pad = string.rep(' ', math.min(indent, 4))
      local first = pad .. marker .. ' '
      local before = #out
      paragraph(text, first, pad .. string.rep(' ', width_of(marker) + 1), nil)
      table.insert(out[before + 1].hls, 1, { #pad, #pad + #marker, 'RevueyGuideListMarker' })
    else
      -- paragraph: join until a blank line or another block
      local text = trimmed
      i = i + 1
      while i <= #src do
        local t = vim.trim(src[i])
        if t == '' or t:match('^#+%s') or t:match('^>') or t:match('^```') or t:match('^[-*+]%s') or t:match('^%d+[.)]%s') then
          break
        end
        text = text .. ' ' .. t
        i = i + 1
      end
      blank()
      paragraph(text, '', '', nil)
    end
  end
  while #out > 0 and out[#out].text == '' do
    out[#out] = nil
  end
  return out
end

return M
