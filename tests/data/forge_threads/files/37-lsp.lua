      )
    then
      configs[#configs + 1] = config
    end
  end
  return configs
end

local lsp_enable_autocmd_id --- @type integer?

--- @param v any
local function validate_cmd(v)
  if type(v) == 'table' then
    if vim.fn.executable(v[1]) == 0 then
      return false, v[1] .. ' is not executable'
    end
    return true
  end
  return type(v) == 'function'
end

--- @param config vim.lsp.Config
local function validate_config(config)
  validate('cmd', config.cmd, validate_cmd, 'expected function or table with executable command')
  validate('reuse_client', config.reuse_client, 'function', true)
  validate('filetypes', config.filetypes, 'table', true)
end

--- Returns true if:
--- 1. the config is managed by vim.lsp,
--- 2. it applies to the given buffer, and
--- 3. its config is valid (in particular: its `cmd` isn't broken).
---
--- @param bufnr integer
--- @param config vim.lsp.Config
--- @param logging boolean
local function can_start(bufnr, config, logging)
  if
    type(config.filetypes) == 'table'
    and not vim.tbl_contains(config.filetypes, vim.bo[bufnr].filetype)
  then
    return false
  end

  local config_ok, err = pcall(validate_config, config)
  if not config_ok then
    if logging then
      log.error(('invalid "%s" config: %s'):format(config.name, err))
    end
    return false
  end

  return true
end

--- @param bufnr integer
--- @param config vim.lsp.Config
local function start_config(bufnr, config)
  return vim.lsp.start(config, {
    bufnr = bufnr,
    reuse_client = config.reuse_client,
    _root_markers = config.root_markers,
  })
end

--- @param bufnr integer
local function lsp_enable_callback(bufnr)
  -- Only ever attach to buffers (including "help") that represent an actual file.
  if vim.bo[bufnr].buftype ~= '' and vim.bo[bufnr].buftype ~= 'help' then
    return
  end

  -- Stop any clients that no longer apply to this buffer.
  local clients = lsp.get_clients({ bufnr = bufnr, _uninitialized = true })
  for _, client in ipairs(clients) do
    -- Don't index into lsp.config[…] unless is_enabled() is true.
    if
      lsp.is_enabled(client.name)
      -- Check that the client is managed by vim.lsp.config before deciding to detach it!
      and lsp.config[client.name]
    then
      if can_start(bufnr, lsp.config[client.name], false) then
        -- When switch between lsp supported filetype (e.g. json to jsonc like #39498),
        -- client should send `textDocument/didClose` + `textDocument/didOpen` with new language id
        local new_language_id = client.get_language_id(bufnr, vim.bo[bufnr].filetype)
        local old_language_id = client.attached_buffers[bufnr] ---@type string?
        if old_language_id and old_language_id ~= new_language_id then
          client:_text_document_did_close_handler(bufnr)
          client.attached_buffers[bufnr] = new_language_id
          client:_text_document_did_open_handler(bufnr)
        end
      else
        lsp.buf_detach_client(bufnr, client.id)
      end
    end
  end

  -- Start any clients that apply to this buffer.
  for name in vim.spairs(lsp._enabled_configs) do
    local config = lsp.config[name]
    if config and can_start(bufnr, config, true) then
      -- Deepcopy config so changes done in the client
      -- do not propagate back to the enabled configs.
      config = vim.deepcopy(config)

      if type(config.root_dir) == 'function' then
        local fname = vim.fs.basename(api.nvim_buf_get_name(bufnr))
        ---@param root_dir string?
        config.root_dir(bufnr, function(root_dir)
          config.root_dir = root_dir
          vim.schedule(function()
            if not api.nvim_buf_is_valid(bufnr) then
              log.info(('lsp.enable: buffer disappeared, skipping: %d "%s"'):format(bufnr, fname))
              return
            end
            start_config(bufnr, config)
          end)
        end)
      else
        start_config(bufnr, config)
      end
    end
  end
end

--- Enables a [lsp-config]: automatically attaches the client to any buffer based on the config
--- `filetypes`, `root_markers`, and `root_dir`. See [lsp-activate] for details.
---
--- To disable, pass `enable=false`: Stops related clients and servers (force-stops servers after
--- a timeout, unless `exit_timeout=false`).
---
--- Raises an error under the following conditions:
--- - `{name}` is not a valid LSP config name (for example, `'*'`).
--- - `{name}` corresponds to an LSP config file which raises an error.
---
--- If an error is raised when multiple names are provided, this function will
--- have no side-effects; it will not enable/disable any configs, including
--- ones which contain no errors.
---
--- Examples:
---
--- ```lua
--- vim.lsp.enable('clangd')
--- vim.lsp.enable({'emmylua_ls', 'pyright'})
--- ```
---
--- Example: To _dynamically_ decide whether LSP is activated, define a |lsp-root_dir()| function
--- which calls `on_dir()` only when you want that config to activate:
---
--- ```lua
--- vim.lsp.config('emmylua_ls', {
---   root_dir = function(bufnr, on_dir)
---     if vim.fs.ext(vim.fn.bufname(bufnr)) ~= 'txt' then
---       on_dir(vim.fn.getcwd())
---     end
---   end
--- })
--- ```
---
---@since 13
---
--- @param name string|string[] Name(s) of client(s) to enable.
--- @param enable? boolean If `true|nil`, enables auto-activation of the given LSP config on current
--- and future buffers. If `false`, disables auto-activation and stops related LSP clients and
--- servers (force-stops servers after `exit_timeout` milliseconds).
function lsp.enable(name, enable)
  validate('name', name, { 'string', 'table' })

  local names = vim._ensure_list(name) --[[@as string[] ]]

  -- Check for errors, and abort with no side-effects if there is one.
  for _, nm in ipairs(names) do
    if nm:match('%*') then
      error('LSP config name cannot contain wildcard ("*")')
    end

    -- Raise error if `lsp.config[nm]` raises an error, instead of waiting for
    -- the error to be triggered by `lsp_enable_callback()`.
    if enable ~= false then
      _ = lsp.config[nm]
    end
  end

  -- Now that there can be no errors, enable/disable all names.
  for _, nm in ipairs(names) do
    lsp._enabled_configs[nm] = enable ~= false and {} or nil
  end

  if not next(lsp._enabled_configs) then
    -- If there are no remaining LSPs enabled, remove the enable autocmd.
    if lsp_enable_autocmd_id then
      api.nvim_del_autocmd(lsp_enable_autocmd_id)
      lsp_enable_autocmd_id = nil
    end
  else
    -- Only ever create autocmd once to reuse computation of config merging.
    lsp_enable_autocmd_id = lsp_enable_autocmd_id
      or nvim_on('FileType', api.nvim_create_augroup('nvim.lsp.enable'), function(ev)
        lsp_enable_callback(ev.buf)
      end)
  end

  -- Ensure any pre-existing buffers start/stop their LSP clients.
  if enable ~= false then
    if (vim.v.vim_did_enter == 1 or vim.fn.did_filetype() == 1) and next(lsp._enabled_configs) then
      vim.cmd.doautoall('nvim.lsp.enable FileType')
    end
  else
    for _, nm in ipairs(names) do
      for _, client in ipairs(lsp.get_clients({ name = nm })) do
        client:stop(client.exit_timeout)
      end
    end
  end
end

--- Checks if the given LSP config is enabled (globally, not per-buffer).
---
--- Unlike `vim.lsp.config['…']`, this does not have the side-effect of resolving the config.
---
--- @param name string Config name
--- @return boolean
function lsp.is_enabled(name)
  return lsp._enabled_configs[name] ~= nil
