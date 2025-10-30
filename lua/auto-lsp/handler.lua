local vim = vim

local augroup = vim.api.nvim_create_augroup
local doautocmd = vim.api.nvim_exec_autocmds

local function doautoall(event, opts)
  local buffers = vim.api.nvim_list_bufs()
  for _, bufnr in ipairs(buffers) do
    opts.buffer = bufnr
    doautocmd(event, opts)
  end
end

local function dofiletype(ft, opts)
  local buffers = vim.api.nvim_list_bufs()
  for _, bufnr in ipairs(buffers) do
    if vim.bo[bufnr].filetype == ft then
      opts.buffer = bufnr
      doautocmd("FileType", opts)
    end
  end
end

local function notify_error(message)
  if vim.notify then
    vim.notify(message, vim.log.levels.ERROR)
  end
end

-- Configure a server, preferring the native vim.lsp.config interface and
-- falling back to the legacy nvim-lspconfig module when required.
local function configure_server(name, config)
  local lsp = vim.lsp
  if lsp ~= nil then
    local config_api = lsp.config

    if type(config_api) == "function" then
      local ok, err = pcall(config_api, name, config)
      if not ok then
        notify_error(string.format("[auto-lsp.nvim] Failed to configure %s: %s", name, err))
        return false, true
      end

      return true, true
    elseif type(config_api) == "table" then
      local meta = getmetatable(config_api)
      if meta and type(meta.__call) == "function" then
        local ok, err = pcall(meta.__call, config_api, name, config)
        if not ok then
          notify_error(string.format("[auto-lsp.nvim] Failed to configure %s: %s", name, err))
          return false, true
        end

        return true, true
      end

      local server_entry = config_api[name]
      if type(server_entry) == "table" and type(server_entry.setup) == "function" then
        local ok, err = pcall(server_entry.setup, config)
        if not ok then
          notify_error(string.format("[auto-lsp.nvim] Failed to configure %s: %s", name, err))
          return false, true
        end

        return true, true
      elseif type(server_entry) == "function" then
        local ok, err = pcall(server_entry, config)
        if not ok then
          notify_error(string.format("[auto-lsp.nvim] Failed to configure %s: %s", name, err))
          return false, true
        end

        return true, true
      end
    end
  end

  local ok, lspconfig = pcall(require, "lspconfig")
  if not ok then
    return false, false
  end

  local server = lspconfig[name]
  if type(server) ~= "table" or type(server.setup) ~= "function" then
    return false, false
  end

  local ok_setup, err = pcall(server.setup, config)
  if not ok_setup then
    notify_error(string.format("[auto-lsp.nvim] Failed to configure %s: %s", name, err))
    return false, false
  end

  return true, false
end

local function enable_server(name, enabled_servers)
  if enabled_servers[name] then
    return true
  end

  local lsp = vim.lsp
  if not lsp or type(lsp.enable) ~= "function" then
    enabled_servers[name] = true
    return true
  end

  local ok, err = pcall(lsp.enable, name)
  if ok then
    enabled_servers[name] = true
    return true
  end

  notify_error(string.format("[auto-lsp.nvim] Failed to enable %s: %s", name, err))
  return false
end

local M = {}

function M:new(opts)
  -- add user specified server filetypes to the filetype:servers mapping
  for name, config in pairs(opts.server_config) do
    if not (type(config) == "table") then
      goto continue
    end

    for _, ft in ipairs(config.filetypes or {}) do
      local ft_servers = opts.filetype_servers[ft] or {}
      if not vim.list_contains(ft_servers, name) then
        ft_servers[#ft_servers + 1] = name
      end
      opts.filetype_servers[ft] = ft_servers
    end

    ::continue::
  end

  opts.checked_filetypes = {}
  opts.checked_servers = {}
  opts.enabled_servers = {}

  return setmetatable(opts, { __index = self })
end

function M:check_server(name, recheck)
  local did_setup = self.checked_servers[name]
  if did_setup == true or (did_setup == false and not recheck) then
    return
  end

  local config = self.server_config[name]
  local exec = self.server_executable[name]

  if type(config) == "function" then
    config = config()
  elseif type(config) == "table" then
    config = config
  elseif type(config) == "boolean" then
    config = config and {}
  else
    config = exec and vim.fn.executable(exec) == 1 and {}
  end

  if config then
    if type(self.global_config) == "function" then
      self.global_config = self.global_config()
    end

    config = vim.tbl_deep_extend("force", self.global_config, config)
    local did_configure, used_native = configure_server(name, config)
    if did_configure and used_native then
      did_configure = enable_server(name, self.enabled_servers)
    end

    self.checked_servers[name] = did_configure
    return
  end

  self.checked_servers[name] = false
end

function M:check_generics(recheck)
  for _, name in ipairs(self.generic_servers) do
    vim.schedule(function()
      self:check_server(name, recheck)
    end)
  end

  vim.schedule(function()
    doautoall("BufReadPost", {
      group = augroup("lspconfig", { clear = false }),
      modeline = false,
    })
  end)
end

function M:check_filetype(ft, recheck)
  if self.checked_filetypes[ft] == true and not recheck then
    return
  end
  self.checked_filetypes[ft] = true

  local ft_servers = self.filetype_servers[ft]
  if not ft_servers then
    return
  end

  for _, name in ipairs(ft_servers) do
    vim.schedule(function()
      self:check_server(name)
    end)
  end

  vim.schedule(function()
    dofiletype(ft, {
      group = augroup("lspconfig", { clear = false }),
      modeline = false,
    })
  end)
end

function M:refresh()
  for name, did_setup in pairs(self.checked_servers) do
    if not did_setup then
      vim.schedule(function()
        self:check_server(name, true)
      end)
    end
  end

  vim.schedule(function()
    doautoall({ "FileType", "BufReadPost" }, {
      group = augroup("lspconfig", { clear = false }),
      modeline = false,
    })
  end)
end

return M
