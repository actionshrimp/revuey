-- LSP readiness with an in-process fake server (no external server needed). During warm-up
-- (before a client's first finished `$/progress` report or first successful answer) requests wait
-- while it reports work in progress, e.g. tsserver loading its project, beyond the settle time.
-- After warm-up progress never delays a request (rust-analyzer's check on save), a report older
-- than a bound is ignored (a server that never ends one), and detaching clears the state.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
require('revuey').setup({ state_dir = h.tmpdir('lsp-ready-state'), lsp_settle_ms = 100 })
local lsp = require('revuey.lsp')

local dir = h.tmpdir('lsp-ready')
h.write(dir, 'a.txt', 'one\ntwo\n')
local abs = dir .. '/a.txt'

---Start a fake client on the file's hidden buffer; returns it with its dispatchers and the list of
---requests it received.
local function start(name)
  local fake = { requests = {} }
  local function server(dispatchers)
    fake.dispatch = dispatchers
    local closing, id = false, 0
    return {
      request = function(method, _, callback)
        id = id + 1
        fake.requests[#fake.requests + 1] = method
        if method == 'initialize' then
          callback(nil, { capabilities = { definitionProvider = true } })
        elseif method == 'textDocument/definition' then
          vim.schedule(function() -- answers arrive later, like a real server's
            callback(nil, { uri = vim.uri_from_fname(abs), range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 3 } } })
          end)
        else
          callback(nil, nil)
        end
        return true, id
      end,
      notify = function()
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
        vim.schedule(function() -- like a process exiting
          dispatchers.on_exit(0, 0)
        end)
      end,
    }
  end
  local buf = lsp.file_buffer(abs)
  fake.id = vim.lsp.start({ name = name, cmd = server, root_dir = dir }, { bufnr = buf, reuse_client = function()
    return false
  end })
  assert(fake.id, 'fake client started')
  assert(vim.wait(2000, function()
    local c = vim.lsp.get_client_by_id(fake.id)
    return c and c.initialized
  end, 10), 'initialized')
  function fake.progress(token, kind)
    fake.dispatch.notification('$/progress', { token = token, value = { kind = kind, title = 'Loading project' } })
  end
  function fake.stop()
    for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
      c:stop(true)
    end
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ name = name }) == 0
    end, 10)
  end
  return fake
end

---Send a definition request; returns a function giving its result once it arrived.
local function request()
  local result
  lsp.request({ abs = abs, lnum = 1, col = 0, text = 'one' }, 'textDocument/definition', function(err, res)
    result = { err = err, res = res }
  end, nil, { on_fail = function(msg)
    result = { fail = msg }
  end })
  return function()
    return result
  end
end

---ms until the request's answer arrived (or nil within `ms`).
local function answered_within(get, ms)
  local t0 = vim.uv.hrtime()
  if not vim.wait(ms, function()
    return get() ~= nil
  end, 10) then
    return nil
  end
  return (vim.uv.hrtime() - t0) / 1e6
end

h.test('warm-up: requests wait for $/progress to end, beyond the settle time', function()
  local fake = start('revuey-fake-1')
  fake.progress('load', 'begin')
  local got = request()
  -- well past lsp_settle_ms (100ms): still waiting, nothing sent
  h.eq(nil, answered_within(got, 800))
  h.eq(false, vim.tbl_contains(fake.requests, 'textDocument/definition'))
  fake.progress('load', 'end')
  h.ok(answered_within(got, 2000), 'request went out after the progress ended')
  h.eq(nil, got().fail)
  h.ok(got().res and got().res.range, vim.inspect(got()))
  fake.stop()
end)

h.test('after warm-up a later progress report (check on save) does not delay requests', function()
  local fake = start('revuey-fake-2')
  h.ok(answered_within(request(), 2000), 'first request')
  fake.progress('check', 'begin') -- e.g. rust-analyzer's cargo check after a save, never ended here
  local ms = answered_within(request(), 2000)
  h.ok(ms and ms < 500, 'answered in ' .. tostring(ms) .. 'ms')
  -- also after warm-up ended by a finished report rather than an answer
  local fake2 = start('revuey-fake-3')
  fake2.progress('load', 'begin')
  fake2.progress('load', 'end')
  fake2.progress('index', 'begin')
  vim.wait(150)
  ms = answered_within(request(), 2000)
  h.ok(ms and ms < 500, 'answered in ' .. tostring(ms) .. 'ms')
  fake.stop()
  fake2.stop()
end)

h.test('a report that never ends stops counting after a bound', function()
  local saved = lsp.progress_max_ms
  lsp.progress_max_ms = 300
  local fake = start('revuey-fake-4')
  fake.progress('stuck', 'begin') -- the server crashed mid-report, or forgot the end
  local ms = answered_within(request(), 3000)
  h.ok(ms and ms < 1000, 'answered in ' .. tostring(ms) .. 'ms (bound 300ms)')
  lsp.progress_max_ms = saved
  fake.stop()
end)

h.test('detaching clears the progress state of a client', function()
  local fake = start('revuey-fake-5')
  fake.progress('load', 'begin')
  h.ok(lsp.progress_state(fake.id), 'tracked')
  fake.stop()
  h.ok(vim.wait(2000, function()
    return lsp.progress_state(fake.id) == nil
  end, 10), 'cleared on exit')
end)

h.run()
