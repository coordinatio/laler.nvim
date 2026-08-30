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
  if cfg.n_variants ~= nil then
    if
      type(cfg.n_variants) ~= "number"
      or cfg.n_variants < 1
      or cfg.n_variants > 9
      or math.floor(cfg.n_variants) ~= cfg.n_variants
    then
      return false, "n_variants must be an integer between 1 and 9"
    end
  end
  if cfg.timeout_ms ~= nil then
    if type(cfg.timeout_ms) ~= "number" or cfg.timeout_ms < 1 or math.floor(cfg.timeout_ms) ~= cfg.timeout_ms then
      return false, "timeout_ms must be an integer >= 1"
    end
  end
  if cfg.adapter ~= nil and type(cfg.adapter) ~= "string" and type(cfg.adapter) ~= "table" then
    return false, "adapter must be a string name or a table"
  end
  if cfg.mappings ~= nil and cfg.mappings ~= false and type(cfg.mappings) ~= "table" then
    return false, "mappings must be false or a table"
  end
  if cfg.prompts ~= nil then
    if type(cfg.prompts) ~= "table" then
      return false, "prompts must be a table"
    end
    local n = 0
    local is_list = false
    if vim.islist then
      is_list = vim.islist(cfg.prompts)
    else
      is_list = cfg.prompts[1] ~= nil
    end
    if is_list then
      for i, p in ipairs(cfg.prompts) do
        n = n + 1
        if type(p) ~= "table" then
          return false, "prompt " .. i .. " must be a table"
        end
        if type(p.id) ~= "string" or p.id == "" then
          return false, "prompt " .. i .. " must have a string id"
        end
        if type(p.template) ~= "string" then
          return false, "prompt '" .. p.id .. "' must have a string template"
        end
      end
    else
      for id, p in pairs(cfg.prompts) do
        n = n + 1
        if type(p) ~= "table" then
          return false, "prompt '" .. tostring(id) .. "' must be a table"
        end
        local pid = p.id or id
        if type(pid) ~= "string" or pid == "" then
          return false, "prompt must have a string id"
        end
        if type(p.template) ~= "string" then
          return false, "prompt '" .. tostring(pid) .. "' must have a string template"
        end
      end
    end
    if n == 0 then
      return false, "prompts must be non-empty"
    end
  end
  return true
end

return M
