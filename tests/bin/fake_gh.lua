-- Lua half of tests/bin/gh: records the call and answers `gh api graphql` from canned PRs.
local argv = { 'gh' }
for i = 1, #arg do
  argv[#argv + 1] = arg[i]
end
local log = os.getenv('REVUEY_FAKE_GH_LOG')
if log and log ~= '' then
  local out = assert(io.open(log, 'a'))
  out:write(vim.json.encode({ argv = argv, cwd = vim.uv.cwd() }), '\n')
  out:close()
end

local scenario = os.getenv('REVUEY_FAKE_GH') or 'ok'
if scenario == 'slow' then
  scenario = 'ok'
end
if log and log ~= '' then
  -- this process's pid (the shell script execs nvim), so tests can check it was stopped
  local fd = assert(io.open(log .. '.pid', 'w'))
  fd:write(tostring(vim.uv.os_getpid()))
  fd:close()
end
if scenario == 'fail' then
  io.stderr:write('error connecting to api.github.com\n')
  os.exit(1)
elseif scenario == 'garbage' then
  io.stdout:write('<html>not json</html>\n')
  os.exit(0)
elseif scenario == 'ratelimit' then
  io.stdout:write(vim.json.encode({ errors = { { type = 'RATE_LIMITED', message = 'API rate limit exceeded' } } }), '\n')
  io.stderr:write('gh: API rate limit exceeded\n')
  os.exit(1)
elseif scenario == 'errors' then
  io.stdout:write(vim.json.encode({ data = vim.NIL, errors = { { message = 'Something went wrong' } } }), '\n')
  os.exit(1)
end

if argv[2] ~= 'api' or argv[3] ~= 'graphql' then
  io.stderr:write('fake gh: unsupported command\n')
  os.exit(2)
end
local query
for i = 4, #argv do
  local q = argv[i]:match('^query=(.*)$')
  if q then
    query = q
  end
end
local prs = {}
local file = os.getenv('REVUEY_FAKE_GH_PRS')
if file and file ~= '' then
  local fd = assert(io.open(file, 'r'))
  prs = vim.json.decode(fd:read('*a'))
  fd:close()
end
-- `_parents`: { ["me/shop"] = "acme/shop" } (forks); `_null`: repos that resolve to null (with a
-- GraphQL error and exit 1, as gh does for partial data)
local parents, null = prs._parents or {}, {}
for _, r in ipairs(prs._null or {}) do
  null[r] = true
end
local data, errors = {}, {}
local pat = '(l%d+): repository%(owner: (%b""), name: (%b"")%) { pullRequests%(headRefName: (%b"")'
for alias, owner, name, branch in (query or ''):gmatch(pat) do
  local repo = vim.json.decode(owner) .. '/' .. vim.json.decode(name)
  branch = vim.json.decode(branch)
  if null[repo] then
    data[alias] = vim.NIL
    errors[#errors + 1] = { type = 'NOT_FOUND', message = 'Could not resolve to a Repository with the name \'' .. repo .. '\'.' }
  else
    local parent = vim.NIL
    if parents[repo] then
      parent = { nameWithOwner = parents[repo], pullRequests = { nodes = prs[parents[repo] .. ':' .. branch] or {} } }
    end
    data[alias] = { nameWithOwner = repo, pullRequests = { nodes = prs[repo .. ':' .. branch] or {} }, parent = parent }
  end
end
io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
if #errors > 0 then
  io.stderr:write('gh: ' .. errors[1].message .. '\n')
  os.exit(1)
end
