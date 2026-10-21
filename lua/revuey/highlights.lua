-- Highlight groups. All are defined with `default = true`, so a user's `:hi` / nvim_set_hl wins.
-- Background-only diff groups are derived from DiffAdd/DiffDelete so syntax foreground shows through.
local M = {}

local function get(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl or {}
end

local function rgb(n)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

local function mix(a, b, t)
  local ar, ag, ab = rgb(a)
  local br, bg, bb = rgb(b)
  local function m(x, y)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return m(ar, br) * 65536 + m(ag, bg) * 256 + m(ab, bb)
end

function M.setup()
  local dark = vim.o.background ~= 'light'
  local normal_bg = get('Normal').bg or (dark and 0x14161b or 0xffffff)
  local add_bg = get('DiffAdd').bg or (dark and 0x1f3d2a or 0xdafbe1)
  local del_bg = get('DiffDelete').bg or (dark and 0x4a2328 or 0xffebe9)
  -- Some schemes make DiffDelete nearly invisible; make sure it is tinted red.
  if get('DiffDelete').bg == nil or get('DiffDelete').bg == normal_bg then
    del_bg = mix(normal_bg, 0xd0303a, dark and 0.25 or 0.15)
  end
  local add_text = mix(add_bg, dark and 0x3fb950 or 0x2da44e, dark and 0.35 or 0.3)
  local del_text = mix(del_bg, dark and 0xf85149 or 0xcf222e, dark and 0.35 or 0.3)

  local set = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set('RevueyAdd', { bg = add_bg })
  set('RevueyDelete', { bg = del_bg })
  set('RevueyAddText', { bg = add_text })
  set('RevueyDeleteText', { bg = del_text })
  set('RevueyContext', {})
  local added_fg = get('Added').fg or (dark and 0x3fb950 or 0x1a7f37)
  local removed_fg = get('Removed').fg or (dark and 0xf85149 or 0xcf222e)
  local linenr = get('LineNr')
  -- gutter of changed rows is tinted like the row itself (GitHub style)
  set('RevueyAddSign', { fg = added_fg, bg = add_bg, bold = true })
  set('RevueyDeleteSign', { fg = removed_fg, bg = del_bg, bold = true })
  set('RevueyLineNr', { fg = linenr.fg, bg = linenr.bg })
  set('RevueyAddLineNr', { fg = linenr.fg, bg = add_bg })
  set('RevueyDeleteLineNr', { fg = linenr.fg, bg = del_bg })
  set('RevueyFileHeader', { bg = mix(normal_bg, dark and 0xffffff or 0x000000, 0.08), bold = true })
  set('RevueyFilePath', { link = 'Directory' })
  set('RevueyHunkHeader', { link = 'Comment' })
  set('RevueyHunkHeaderBg', { bg = mix(normal_bg, 0x4078c0, dark and 0.12 or 0.08) })
  set('RevueyNote', { link = 'Comment' })
  set('RevueyFold', { link = 'Folded' })
  set('RevueyReviewed', { link = 'DiagnosticOk' })
  set('RevueyUnreviewed', { link = 'Comment' })
  set('RevueyStatusAdded', { link = 'Added' })
  set('RevueyStatusDeleted', { link = 'Removed' })
  set('RevueyStatusModified', { link = 'Changed' })
  set('RevueyStatusRenamed', { link = 'Special' })
  set('RevueyCountAdd', { link = 'Added' })
  set('RevueyCountDelete', { link = 'Removed' })
  set('RevueyPanelTitle', { link = 'Title' })
  set('RevueyMode', { link = 'Special' })
  set('RevueyUncommitted', { link = 'DiagnosticWarn' })
  set('RevueyPanelDir', { link = 'Comment' })
  set('RevueyPanelCurrent', { link = 'CursorLine' })
  set('RevueyWinbar', { link = 'WinBar' })
  -- guide view
  set('RevueyGuideTitle', { link = 'Title' })
  set('RevueyGuideSection', { bg = mix(normal_bg, dark and 0xffffff or 0x000000, 0.08), bold = true })
  set('RevueyGuideSectionNumber', { link = 'Title' })
  set('RevueyGuideHeading', { link = 'Title' })
  set('RevueyGuideBold', { bold = true })
  set('RevueyGuideItalic', { italic = true })
  set('RevueyGuideCode', { link = '@markup.raw' })
  set('RevueyGuideLink', { link = 'Underlined' })
  set('RevueyGuideListMarker', { link = 'Special' })
  set('RevueyGuideQuote', { link = 'Comment' })
  set('RevueyGuideQuoteText', { italic = true })
  set('RevueyGuideNoteCallout', { link = 'DiagnosticInfo' })
  set('RevueyGuideTip', { link = 'DiagnosticOk' })
  set('RevueyGuideImportant', { link = 'DiagnosticHint' })
  set('RevueyGuideWarning', { link = 'DiagnosticWarn' })
  set('RevueyGuideCaution', { link = 'DiagnosticError' })
  set('RevueyGuideHunkNote', { link = 'Special' })
  set('RevueyGuideMeta', { link = 'Comment' })
  set('RevueyGuideBanner', { link = 'DiagnosticWarn' })
  set('RevueyGuideOutdated', { link = 'DiagnosticWarn' })
  set('RevueyGuideSpinner', { link = 'Special' })
end

local group = vim.api.nvim_create_augroup('revuey_highlights', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = M.setup })

return M
