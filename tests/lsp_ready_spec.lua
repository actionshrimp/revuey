-- LSP readiness with an in-process fake server (no external server needed): requests wait while
-- the server reports work in progress (`$/progress` begin without end, e.g. a project loading),
-- beyond the settle time, and go out once it ends.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
require('revuey').setup({ state_dir = h.tmpdir('lsp-ready-state'), lsp_settle_ms = 100 })
local lsp = require('revuey.lsp')

local dir = h.tmpdir('lsp-ready')
h.write(dir, 'a.txt', 'one\ntwo\n')
local abs = dir .. '/a.txt'

local dispatch, requests = nil, {}
local function server(dispatchers)
  dispatch = dispatchers
  local closing, id = false, 0
  return {
    request = function(method, _, callback)
      id = id + 1
      requests[#requests + 1] = method
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
    end,
  }
end

h.test('requests wait for $/progress to end, beyond the settle time', function()
  local buf = lsp.file_buffer(abs)
  local client_id = vim.lsp.start({ name = 'revuey-fake', cmd = server, root_dir = dir }, { bufnr = buf })
  h.ok(client_id, 'fake client started')
  h.ok(vim.wait(2000, function()
    local c = vim.lsp.get_client_by_id(client_id)
    return c and c.initialized
  end, 10), 'initialized')
  dispatch.notification('$/progress', { token = 'load', value = { kind = 'begin', title = 'Loading project' } })
  local result
  lsp.request({ abs = abs, lnum = 1, col = 0, text = 'one' }, 'textDocument/definition', function(err, res)
    result = { err = err, res = res }
  end, nil, { on_fail = function(msg)
    result = { fail = msg }
  end })
  -- well past lsp_settle_ms (100ms): still waiting, nothing sent
  vim.wait(800, function()
    return result ~= nil
  end, 20)
  h.eq(nil, result)
  h.eq(false, vim.tbl_contains(requests, 'textDocument/definition'))
  dispatch.notification('$/progress', { token = 'load', value = { kind = 'end' } })
  h.ok(vim.wait(2000, function()
    return result ~= nil
  end, 20), 'request went out after the progress ended')
  h.eq(nil, result.fail)
  h.ok(result.res and result.res.range, vim.inspect({ result, requests }))
  vim.lsp.get_client_by_id(client_id):stop(true)
end)

h.run()
