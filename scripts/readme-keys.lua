-- Write the README's Keymaps tables from lua/revuey/keys.lua (the list the `g?` float shows),
-- between the `<!-- keys:begin -->` and `<!-- keys:end -->` markers:
--
--   nvim --headless --clean -l scripts/readme-keys.lua
--
-- tests/key_help_spec.lua fails when the README and keys.lua differ.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local keys = require('revuey.keys')

local path = root .. '/README.md'
local text = table.concat(vim.fn.readfile(path), '\n') .. '\n'
local _, head_end = text:find('<!%-%- keys:begin %-%->\n')
local b = text:find('<!%-%- keys:end %-%->')
assert(head_end and b, 'README.md has no keys:begin / keys:end markers')
local new = text:sub(1, head_end) .. keys.markdown() .. '\n' .. text:sub(b)
if new == text then
  print('README.md is up to date')
else
  local fd = assert(io.open(path, 'w'))
  fd:write(new)
  fd:close()
  print('README.md: Keymaps tables written')
end
