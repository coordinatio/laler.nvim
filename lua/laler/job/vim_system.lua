---@implements laler.JobRunner
local M = {}

local seq = 0
local active = nil ---@type { obj: vim.SystemObj, gen: integer }?

---@param job_gen integer
---@param current_seq integer
---@param active_gen integer|nil
---@return boolean should_clear_active
---@return boolean should_deliver
local function resolve_exit(job_gen, current_seq, active_gen)
  local clear = active_gen ~= nil and active_gen == job_gen
  local deliver = job_gen == current_seq
  return clear, deliver
end

--- Test helper: whether a callback for `job_gen` should clear the handle / run on_exit.
M._resolve_exit = resolve_exit

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

  seq = seq + 1
  local gen = seq

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
    cwd = spec.cwd or vim.fn.getcwd(),
    env = merge_env(spec.env),
    text = true,
    timeout = opts.timeout_ms,
  }, function(obj)
    local clear, deliver = resolve_exit(gen, seq, active and active.gen or nil)
    if clear then
      active = nil
    end
    if not deliver then
      return
    end
    local stdout = obj.stdout or ""
    local stderr = obj.stderr or ""
    local code = obj.code or -1
    local success = code == 0
    vim.schedule(function()
      local _, still = resolve_exit(gen, seq, active and active.gen or nil)
      if not still then
        return
      end
      callbacks.on_exit(success, stdout, stderr, code)
    end)
  end)

  if not ok then
    callbacks.on_exit(false, "", tostring(obj_or_err), -1)
    return
  end
  active = { obj = obj_or_err, gen = gen }
end

function M:cancel()
  seq = seq + 1
  if not active then
    return
  end
  local dying = active
  active = nil
  pcall(function()
    dying.obj:kill(15)
  end)
  vim.defer_fn(function()
    -- Only SIGKILL this SystemObj; never a newer job (generation / identity).
    if active and (active.obj == dying.obj or active.gen == dying.gen) then
      return
    end
    local finished = false
    pcall(function()
      local result = dying.obj:wait(0)
      if result ~= nil then
        finished = true
      end
    end)
    if not finished then
      pcall(function()
        dying.obj:kill(9)
      end)
    end
  end, 1000)
end

---@return boolean
function M:is_running()
  return active ~= nil
end

return M
