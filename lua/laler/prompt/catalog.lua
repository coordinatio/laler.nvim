local util = require("laler.util")

local M = {}

---@param n any
---@param id string
local function check_n_variants(n, id)
  if n == nil then
    return
  end
  if type(n) ~= "number" or n < 1 or n > 9 or math.floor(n) ~= n then
    error("laler: prompt '" .. id .. "' n_variants must be an integer between 1 and 9")
  end
end

---@param p any
---@param id_hint? string
---@return laler.PromptDef
local function normalize_prompt(p, id_hint)
  if type(p) ~= "table" then
    if id_hint then
      error("laler: prompt '" .. tostring(id_hint) .. "' must be a table")
    end
    error("laler: prompt must be a table")
  end
  local def = vim.tbl_extend("force", {}, p)
  def.id = def.id or id_hint
  if type(def.id) ~= "string" or def.id == "" then
    error("laler: prompt missing string id")
  end
  if def.id:find("%s") then
    error("laler: prompt id must not contain whitespace")
  end
  if type(def.template) ~= "string" then
    error("laler: prompt '" .. def.id .. "' must have a string template")
  end
  if not def.template:find("{{text}}", 1, true) then
    error("laler: prompt '" .. def.id .. "' template must include {{text}}")
  end
  check_n_variants(def.n_variants, def.id)
  if def.label ~= nil and type(def.label) ~= "string" then
    error("laler: prompt '" .. def.id .. "' label must be a string")
  end
  if def.description ~= nil and type(def.description) ~= "string" then
    error("laler: prompt '" .. def.id .. "' description must be a string")
  end
  if type(def.label) ~= "string" or def.label == "" then
    def.label = def.id
  end
  return def
end

---@return laler.PromptDef[]
function M.builtin()
  return {
    {
      id = "correct",
      label = "Correct",
      description = "Grammar + native-speaker fluency",
      template = [[Analyze the {{language}} passage inside {{text_open}}…{{text_close}} for formal correctness and how closely it matches what a native speaker would write.

Provide {{n_variants}} corrected {{variant_noun}}:
{{variant_list}}

Passage:
{{text}}]],
    },
    {
      id = "formal",
      label = "Formal",
      description = "More formal register",
      template = [[Rewrite the {{language}} passage inside {{text_open}}…{{text_close}} in a more formal register.
Provide {{n_variants}} {{variant_noun}}:
{{variant_list}}

Passage:
{{text}}]],
    },
    {
      id = "casual",
      label = "Casual",
      description = "More casual / conversational",
      template = [[Rewrite the {{language}} passage inside {{text_open}}…{{text_close}} in a more casual, conversational register.
Provide {{n_variants}} {{variant_noun}}:
{{variant_list}}

Passage:
{{text}}]],
    },
    {
      id = "concise",
      label = "Concise",
      description = "Shorter and clearer",
      template = [[Rewrite the {{language}} passage inside {{text_open}}…{{text_close}} to be more concise and clear without losing meaning.
Provide {{n_variants}} {{variant_noun}}:
{{variant_list}}

Passage:
{{text}}]],
    },
  }
end

---@param opts { prompts?: laler.PromptDef[]|table<string, laler.PromptDef>, default_prompt?: string, remember_last_prompt?: boolean }
---@return laler.PromptCatalog
function M.new(opts)
  opts = opts or {}
  local list = {}
  local by_id = {}

  ---@param def laler.PromptDef
  local function push(def)
    if by_id[def.id] then
      error("laler: duplicate prompt id '" .. def.id .. "'")
    end
    list[#list + 1] = def
    by_id[def.id] = def
  end

  local source = opts.prompts
  if source == nil then
    source = M.builtin()
  end

  if util.is_list(source) then
    for _, p in ipairs(source) do
      push(normalize_prompt(p))
    end
  else
    for _, p in ipairs(M.builtin()) do
      push(normalize_prompt(p))
    end
    local extras = {}
    local seen_user = {}
    for id, p in pairs(source) do
      if type(p) ~= "table" then
        error("laler: prompt '" .. tostring(id) .. "' must be a table")
      end
      if p.id ~= nil and p.id ~= id then
        error("laler: prompt map key '" .. tostring(id) .. "' must match id '" .. tostring(p.id) .. "'")
      end
      local pid = p.id or id
      if seen_user[pid] then
        error("laler: duplicate prompt id '" .. tostring(pid) .. "'")
      end
      seen_user[pid] = true
      local base = type(pid) == "string" and by_id[pid] or nil
      if base then
        local def = normalize_prompt(vim.tbl_extend("force", base, p), pid)
        for i, existing in ipairs(list) do
          if existing.id == def.id then
            list[i] = def
            break
          end
        end
        by_id[def.id] = def
      else
        extras[#extras + 1] = normalize_prompt(p, id)
      end
    end
    table.sort(extras, function(a, b)
      return a.id < b.id
    end)
    for _, def in ipairs(extras) do
      list[#list + 1] = def
      by_id[def.id] = def
    end
  end

  if opts.prompts ~= nil and #list == 0 then
    error("laler: prompts must be non-empty")
  end

  local default_prompt = opts.default_prompt
  if default_prompt ~= nil then
    if type(default_prompt) ~= "string" or default_prompt == "" or not by_id[default_prompt] then
      error("laler: unknown default_prompt '" .. tostring(default_prompt) .. "'")
    end
  end
  local remember = opts.remember_last_prompt ~= false
  local last_id = nil

  ---@type laler.PromptCatalog
  local catalog = {}

  function catalog:list()
    return vim.list_extend({}, list)
  end

  function catalog:get(id)
    return by_id[id]
  end

  function catalog:default_id()
    if remember and last_id and by_id[last_id] then
      return last_id
    end
    if default_prompt and by_id[default_prompt] then
      return default_prompt
    end
    if list[1] then
      return list[1].id
    end
    error("laler: no prompts configured")
  end

  function catalog:remember(id)
    if remember and by_id[id] then
      last_id = id
    end
  end

  return catalog
end

return M
