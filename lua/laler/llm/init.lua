local M = {}

---@type table<string, laler.LlmClient|fun(): laler.LlmClient>
local registry = {}

---@param name string
---@param client laler.LlmClient|fun(): laler.LlmClient
function M.register(name, client)
  registry[name] = client
end

---@param name string
---@return laler.LlmClient?
function M.get(name)
  local c = registry[name]
  if type(c) == "function" then
    return c()
  end
  return c
end

--- Resolve adapter config: string name or table (generic).
---@param adapter string|table
---@return laler.LlmClient
function M.resolve(adapter)
  if type(adapter) == "table" then
    return require("laler.llm.generic").new(adapter)
  end
  if type(adapter) ~= "string" then
    error("laler: adapter must be a string or table")
  end
  local client = M.get(adapter)
  if not client then
    error("laler: unknown adapter '" .. adapter .. "'")
  end
  return client
end

-- Built-in registrations (lazy factories to avoid circular requires at load)
M.register("pi", function()
  return require("laler.llm.pi")
end)
M.register("cursor", function()
  return require("laler.llm.cursor")
end)
M.register("opencode", function()
  return require("laler.llm.opencode")
end)

return M
