---@implements laler.JobRunner
local M = {}

local active = nil ---@type vim.SystemObj?

---@param env table<string, string>|nil
---@return table<string, string>?
local function merge_env(env)
  if not env then
    return nil
  end
  local base = vim.fn.environ()
  for k, v in pairs(env) do
    base[k] = v
  end
  return base
end

---@param spec laler.JobSpec
---@param callbacks laler.JobCallbacks
---@param opts? { timeout_ms?: integer }
function M:start(spec, callbacks, opts)
  self:cancel()
  opts = opts or {}

  if vim.fn.executable(spec.cmd) ~= 1 then
    callbacks.on_exit(false, "", spec.cmd .. " not found in PATH", 127)
    return
  end

  local cmd = { spec.cmd }
  vim.list_extend(cmd, spec.args or {})

  if callbacks.on_start then
    callbacks.on_start()
  end

  local ok, obj_or_err = pcall(vim.system, cmd, {
    stdin = spec.stdin,
    cwd = spec.cwd,
    env = merge_env(spec.env),
    text = true,
    timeout = opts.timeout_ms,
  }, function(obj)
    active = nil
    local stdout = obj.stdout or ""
    local stderr = obj.stderr or ""
    local code = obj.code or -1
    local success = code == 0
    vim.schedule(function()
      callbacks.on_exit(success, stdout, stderr, code)
    end)
  end)

  if not ok then
    callbacks.on_exit(false, "", tostring(obj_or_err), -1)
    return
  end
  active = obj_or_err
end

function M:cancel()
  if active then
    pcall(function()
      active:kill(15)
    end)
    active = nil
  end
end

---@return boolean
function M:is_running()
  return active ~= nil
end

return M
