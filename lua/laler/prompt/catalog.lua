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
      list[#list + 1] = p
      by_id[p.id] = p
    end
  else
    for id, p in pairs(source) do
      local def = vim.tbl_extend("force", {}, p)
      def.id = def.id or id
      list[#list + 1] = def
      by_id[def.id] = def
    end
    table.sort(list, function(a, b)
      return a.id < b.id
    end)
  end

  local default_prompt = opts.default_prompt
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
