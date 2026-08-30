local M = {}

---@return table
function M.defaults()
  return {
    adapter = "pi",
    language = "en",
    n_variants = 3,
    default_prompt = "correct",
    remember_last_prompt = true,
    picker = nil,
    mappings = false,
    timeout_ms = 60000,
    prompts = nil, -- filled from catalog defaults when nil
  }
end

---@param user table|nil
---@return table
function M.merge(user)
  local cfg = vim.tbl_deep_extend("force", M.defaults(), user or {})
  return cfg
end

---@param cfg table
---@return boolean, string?
function M.validate(cfg)
  if type(cfg) ~= "table" then
    return false, "config must be a table"
  end
  if cfg.n_variants ~= nil and (type(cfg.n_variants) ~= "number" or cfg.n_variants < 1) then
    return false, "n_variants must be a positive number"
  end
  if cfg.timeout_ms ~= nil and (type(cfg.timeout_ms) ~= "number" or cfg.timeout_ms < 0) then
    return false, "timeout_ms must be a non-negative number"
  end
  if cfg.adapter ~= nil and type(cfg.adapter) ~= "string" and type(cfg.adapter) ~= "table" then
    return false, "adapter must be a string name or a table"
  end
  if cfg.mappings ~= nil and cfg.mappings ~= false and type(cfg.mappings) ~= "table" then
    return false, "mappings must be false or a table"
  end
  return true
end

return M
