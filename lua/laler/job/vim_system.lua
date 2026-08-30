---@implements laler.JobRunner
local M = {}

local seq = 0
local active = nil ---@type { obj: vim.SystemObj, gen: integer }?

--- Cap so a runaway CLI cannot freeze Neovim on parse/UI.
M.MAX_OUTPUT_BYTES = 2000000

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

---@param spec_env table<string, string>|nil
---@return table<string, string>
local function child_env(spec_env)
  return vim.tbl_extend("force", {
    NVIM = "",
    NVIM_LISTEN_ADDRESS = "",
  }, spec_env or {})
end

--- Test helper: child env with blank NVIM* so agent CLIs do not attach to the parent.
M._child_env = child_env

---@param obj vim.SystemCompleted
---@return boolean
local function job_success(obj)
  local code = obj.code or -1
  local signal = obj.signal or 0
  return code == 0 and signal == 0
end

---@param obj vim.SystemObj
---@return boolean
local function is_closing(obj)
  local ok_close, closing = pcall(function()
    return obj:is_closing()
  end)
  return ok_close and closing
end

---@param obj vim.SystemObj
local function sigkill(obj)
  if not is_closing(obj) then
    pcall(function()
      obj:kill(9)
    end)
  end
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
    -- Blank NVIM* so nested agent CLIs do not attach to this editor.
    -- spec.env is merged on top (OPENCODE_PERMISSION still wins).
    env = child_env(spec.env),
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
    local signal = obj.signal or 0
    local success = job_success(obj)
    if #stdout > M.MAX_OUTPUT_BYTES or #stderr > M.MAX_OUTPUT_BYTES then
      stdout = stdout:sub(1, M.MAX_OUTPUT_BYTES)
      success = false
      stderr = "output too large"
    end
    vim.schedule(function()
      local _, still = resolve_exit(gen, seq, active and active.gen or nil)
      if not still then
        return
      end
      callbacks.on_exit(success, stdout, stderr, code, signal)
    end)
  end)

  if not ok then
    callbacks.on_exit(false, "", tostring(obj_or_err), -1)
    return
  end
  active = { obj = obj_or_err, gen = gen }

  -- vim.system timeout typically sends TERM only; SIGKILL a trapping CLI
  -- so the loading UI does not sit on "Thinking…".
  if type(opts.timeout_ms) == "number" and opts.timeout_ms > 0 then
    local timed = obj_or_err
    local timed_gen = gen
    vim.defer_fn(function()
      if not active or active.obj ~= timed or active.gen ~= timed_gen then
        return
      end
      sigkill(timed)
    end, opts.timeout_ms + 1000)
  end
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
    -- SystemObj:wait(timeout) kills the process on timeout; wait(0) is not a
    -- poll. Skip if already closing, otherwise SIGKILL this dying object only.
    sigkill(dying.obj)
  end, 1000)
end

---@return boolean
function M:is_running()
  return active ~= nil
end

return M
