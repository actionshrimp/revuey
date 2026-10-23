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
local data = {}
local pat = '(l%d+): repository%(owner: (%b""), name: (%b"")%) { pullRequests%(headRefName: (%b"")'
for alias, owner, name, branch in (query or ''):gmatch(pat) do
  local key = vim.json.decode(owner) .. '/' .. vim.json.decode(name) .. ':' .. vim.json.decode(branch)
  data[alias] = { pullRequests = { nodes = prs[key] or {} } }
end
io.stdout:write(vim.json.encode({ data = data }), '\n')
