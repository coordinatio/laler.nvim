local M = {}

---@type table<string, laler.LlmClient|fun(opts?: { model?: string, thinking?: boolean }): laler.LlmClient>
local registry = {}

---@param name string
---@param client laler.LlmClient|fun(opts?: { model?: string, thinking?: boolean }): laler.LlmClient
function M.register(name, client)
  registry[name] = client
end

---@param name string
---@param opts? { model?: string, thinking?: boolean }
---@return laler.LlmClient?
function M.get(name, opts)
  local c = registry[name]
  if type(c) == "function" then
    return c(opts)
  end
  return c
end

---@param model any
---@return string?
local function normalize_model(model)
  if type(model) == "string" and model ~= "" then
    return model
  end
  return nil
end

---@param thinking any
---@return boolean?
local function normalize_thinking(thinking)
  if type(thinking) == "boolean" then
    return thinking
  end
  return nil
end

--- Prefer adapter-table field over top-level (`false` must not lose to `or`).
---@param adapter_val any
---@param opts_val any
---@param normalize fun(v: any): any
---@return any
local function pick_opt(adapter_val, opts_val, normalize)
  if adapter_val ~= nil then
    return normalize(adapter_val)
  end
  return normalize(opts_val)
end

--- Named built-in without generic override fields (`cmd` / `build` / `args` / …).
---@param adapter table
---@return boolean
local function is_named_builtin(adapter)
  if type(adapter.name) ~= "string" or adapter.name == "" then
    return false
  end
  if adapter.cmd ~= nil or adapter.build ~= nil or adapter.args ~= nil or adapter.env ~= nil or adapter.cwd ~= nil then
    return false
  end
  return registry[adapter.name] ~= nil
end

--- Resolve adapter config: string name or table (generic / named built-in).
---@param adapter string|table
---@param opts? { model?: string, thinking?: boolean }
---@return laler.LlmClient
function M.resolve(adapter, opts)
  opts = opts or {}
  if type(adapter) == "table" then
    local model = pick_opt(adapter.model, opts.model, normalize_model)
    local thinking = pick_opt(adapter.thinking, opts.thinking, normalize_thinking)
    if is_named_builtin(adapter) then
      return M.get(adapter.name, { model = model, thinking = thinking })
    end
    local generic_opts = vim.tbl_extend("force", {}, adapter)
    if model then
      generic_opts.model = model
    end
    if thinking ~= nil then
      generic_opts.thinking = thinking
    end
    return require("laler.llm.generic").new(generic_opts)
  end
  if type(adapter) ~= "string" then
    error("laler: adapter must be a string or table")
  end
  local client = M.get(adapter, {
    model = normalize_model(opts.model),
    thinking = normalize_thinking(opts.thinking),
  })
  if not client then
    error("laler: unknown adapter '" .. adapter .. "'")
  end
  return client
end

-- Built-in registrations (lazy factories to avoid circular requires at load)
M.register("pi", function(opts)
  return require("laler.llm.pi").new(opts)
end)
M.register("cursor", function(opts)
  return require("laler.llm.cursor").new(opts)
end)
M.register("opencode", function(opts)
  return require("laler.llm.opencode").new(opts)
end)

return M
