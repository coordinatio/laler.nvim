local util = require("laler.util")

local M = {}

---@param n any
---@return boolean
local function valid_n_variants(n)
  return type(n) == "number" and n >= 1 and n <= 9 and math.floor(n) == n
end

---@param p table
---@param pid string
---@param require_template boolean
---@return boolean, string?
local function validate_prompt_fields(p, pid, require_template)
  if require_template or p.template ~= nil then
    if type(p.template) ~= "string" then
      return false, "prompt '" .. pid .. "' must have a string template"
    end
    if not p.template:find("{{text}}", 1, true) then
      return false, "prompt '" .. pid .. "' template must include {{text}}"
    end
  end
  if p.label ~= nil and type(p.label) ~= "string" then
    return false, "prompt '" .. pid .. "' label must be a string"
  end
  if p.description ~= nil and type(p.description) ~= "string" then
    return false, "prompt '" .. pid .. "' description must be a string"
  end
  if p.n_variants ~= nil and not valid_n_variants(p.n_variants) then
    return false, "prompt '" .. pid .. "' n_variants must be an integer between 1 and 9"
  end
  return true
end

---@return table
function M.defaults()
  return {
    adapter = "pi",
    model = nil,
    thinking = nil,
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
    if not valid_n_variants(cfg.n_variants) then
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
  if cfg.model ~= nil then
    if type(cfg.model) ~= "string" or cfg.model == "" then
      return false, "model must be a non-empty string"
    end
  end
  if type(cfg.adapter) == "table" and cfg.adapter.model ~= nil then
    if type(cfg.adapter.model) ~= "string" or cfg.adapter.model == "" then
      return false, "adapter.model must be a non-empty string"
    end
  end
  if cfg.thinking ~= nil and type(cfg.thinking) ~= "boolean" then
    return false, "thinking must be a boolean"
  end
  if type(cfg.adapter) == "table" and cfg.adapter.thinking ~= nil then
    if type(cfg.adapter.thinking) ~= "boolean" then
      return false, "adapter.thinking must be a boolean"
    end
  end
  if cfg.mappings ~= nil and cfg.mappings ~= false and type(cfg.mappings) ~= "table" then
    return false, "mappings must be false or a table"
  end
  if cfg.prompts ~= nil then
    if type(cfg.prompts) ~= "table" then
      return false, "prompts must be a table"
    end
    local n = 0
    local seen = {}
    local prompts_list = util.is_list(cfg.prompts)
    if prompts_list then
      for i, p in ipairs(cfg.prompts) do
        n = n + 1
        if type(p) ~= "table" then
          return false, "prompt " .. i .. " must be a table"
        end
        if type(p.id) ~= "string" or p.id == "" then
          return false, "prompt " .. i .. " must have a string id"
        end
        if p.id:find("%s") then
          return false, "prompt id must not contain whitespace"
        end
        if seen[p.id] then
          return false, "duplicate prompt id '" .. p.id .. "'"
        end
        seen[p.id] = true
        local pok, perr = validate_prompt_fields(p, p.id, true)
        if not pok then
          return false, perr
        end
      end
    else
      local builtin_ids = {}
      for _, bp in ipairs(require("laler.prompt.catalog").builtin()) do
        builtin_ids[bp.id] = true
      end
      for id, p in pairs(cfg.prompts) do
        n = n + 1
        if type(p) ~= "table" then
          return false, "prompt '" .. tostring(id) .. "' must be a table"
        end
        if p.id ~= nil and p.id ~= id then
          return false, "prompt map key '" .. tostring(id) .. "' must match id '" .. tostring(p.id) .. "'"
        end
        local pid = p.id or id
        if type(pid) ~= "string" or pid == "" then
          return false, "prompt must have a string id"
        end
        if pid:find("%s") then
          return false, "prompt id must not contain whitespace"
        end
        if seen[pid] then
          return false, "duplicate prompt id '" .. pid .. "'"
        end
        seen[pid] = true
        local pok, perr = validate_prompt_fields(p, pid, not builtin_ids[pid])
        if not pok then
          return false, perr
        end
      end
    end
    if n == 0 then
      return false, "prompts must be non-empty"
    end
  end
  if cfg.default_prompt ~= nil then
    if type(cfg.default_prompt) ~= "string" or cfg.default_prompt == "" then
      return false, "unknown default_prompt"
    end
    local known = {}
    local prompts_list = cfg.prompts ~= nil and util.is_list(cfg.prompts)
    if cfg.prompts ~= nil and prompts_list then
      for _, p in ipairs(cfg.prompts) do
        if type(p) == "table" and type(p.id) == "string" then
          known[p.id] = true
        end
      end
    else
      for _, p in ipairs(require("laler.prompt.catalog").builtin()) do
        known[p.id] = true
      end
      if cfg.prompts ~= nil then
        for id, p in pairs(cfg.prompts) do
          if type(p) == "table" then
            local pid = p.id or id
            if type(pid) == "string" then
              known[pid] = true
            end
          end
        end
      end
    end
    if not known[cfg.default_prompt] then
      return false, "unknown default_prompt"
    end
  end
  return true
end

return M
