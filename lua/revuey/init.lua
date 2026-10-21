local M = {}

---@param opts? table see lua/revuey/config.lua for defaults
function M.setup(opts)
  require('revuey.config').set(opts)
end

---Open a review of the current branch against `base` (default: configured/detected default branch).
---@param opts? {base?:string, cwd?:string, standalone?:boolean, on_ready?:fun(session)}
function M.open(opts)
  require('revuey.view').open(opts)
end

function M.close()
  require('revuey.view').close()
end

return M
