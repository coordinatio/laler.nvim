local M = {}

---@return laler.PromptDef[]
function M.builtin()
  return {
    {
      id = "correct",
      label = "Correct",
      description = "Grammar + native-speaker fluency",
      template = [[Analyze the {{language}} passage inside {{text_open}}…{{text_close}} for formal correctness and how closely it matches what a native speaker would write.

Provide {{n_variants}} corrected variants:
{{variant_list}}

Passage:
{{text}}]],
    },
    {
      id = "formal",
      label = "Formal",
      description = "More formal register",
      template = [[Rewrite the {{language}} passage inside {{text_open}}…{{text_close}} in a more formal register.
Provide {{n_variants}} variants with labels "formal-1", "formal-2", etc.

Passage:
{{text}}]],
    },
    {
      id = "casual",
      label = "Casual",
      description = "More casual / conversational",
      template = [[Rewrite the {{language}} passage inside {{text_open}}…{{text_close}} in a more casual, conversational register.
Provide {{n_variants}} variants with labels "casual-1", "casual-2", etc.

Passage:
{{text}}]],
    },
    {
      id = "concise",
      label = "Concise",
      description = "Shorter and clearer",
      template = [[Rewrite the {{language}} passage inside {{text_open}}…{{text_close}} to be more concise and clear without losing meaning.
Provide {{n_variants}} variants with labels "concise-1", "concise-2", etc.

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

  local source = opts.prompts
  if source == nil then
    source = M.builtin()
  end

  local is_list = false
  if type(source) == "table" then
    if vim.islist then
      is_list = vim.islist(source)
    else
      is_list = source[1] ~= nil
    end
  end

  if is_list then
    for _, p in ipairs(source) do
      if type(p) ~= "table" then
        error("laler: prompt must be a table")
      end
      local def = vim.tbl_extend("force", {}, p)
      if type(def.id) ~= "string" or def.id == "" then
        error("laler: prompt missing string id")
      end
      if by_id[def.id] then
        error("laler: duplicate prompt id '" .. def.id .. "'")
      end
      if type(def.template) ~= "string" then
        error("laler: prompt '" .. def.id .. "' must have a string template")
      end
      if type(def.label) ~= "string" or def.label == "" then
        def.label = def.id
      end
      list[#list + 1] = def
      by_id[def.id] = def
    end
  else
    for id, p in pairs(source) do
      if type(p) ~= "table" then
        error("laler: prompt '" .. tostring(id) .. "' must be a table")
      end
      local def = vim.tbl_extend("force", {}, p)
      def.id = def.id or id
      if type(def.id) ~= "string" or def.id == "" then
        error("laler: prompt missing string id")
      end
      if by_id[def.id] then
        error("laler: duplicate prompt id '" .. def.id .. "'")
      end
      if type(def.template) ~= "string" then
        error("laler: prompt '" .. def.id .. "' must have a string template")
      end
      if type(def.label) ~= "string" or def.label == "" then
        def.label = def.id
      end
      list[#list + 1] = def
      by_id[def.id] = def
    end
    table.sort(list, function(a, b)
      return a.id < b.id
    end)
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
    return list
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
