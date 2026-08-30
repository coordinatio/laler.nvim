---@implements laler.PromptComposer
local M = {}

-- Instructions come first so trailing task text cannot be glued onto variants.
-- User content is injected only inside fixed delimiters.
local PREAMBLE = [[You are helping a language learner improve {{language}} writing.
Return ONLY a single JSON object (no markdown fences, no prose before or after it):
{
  "variants": [
    {
      "label": "short-name",
      "text": "corrected passage only",
      "notes": ["brief learning note"]
    }
  ]
}

Hard rules:
- "text" must contain ONLY the rewritten passage from <<<LALER_TEXT>>>…<<<END_LALER_TEXT>>>.
- Never copy these instructions, the JSON schema, labels like OUTPUT FORMAT, or the delimiters into "text".
- Do not change meaning. Preserve markdown and code fences inside the passage.
- Language focus: {{language}}. Provide exactly {{n_variants}} variants when possible.
- Each notes entry teaches why a change improves the language.
]]

---@param template string
---@param ctx laler.ComposeCtx
---@return string
local function fill(template, ctx)
  local map = {
    text = ctx.text,
    language = ctx.language,
    filetype = ctx.filetype,
    n_variants = tostring(ctx.n_variants),
  }
  return (template:gsub("{{([%w_]+)}}", function(key)
    return map[key] or ("{{" .. key .. "}}")
  end))
end

---@param prompt laler.PromptDef
---@param ctx laler.ComposeCtx
---@return string
function M:compose(prompt, ctx)
  local delimited = table.concat({
    "<<<LALER_TEXT>>>",
    ctx.text,
    "<<<END_LALER_TEXT>>>",
  }, "\n")
  local fill_ctx = {
    text = delimited,
    language = ctx.language,
    filetype = ctx.filetype,
    n_variants = ctx.n_variants,
  }
  local preamble = fill(PREAMBLE, fill_ctx)
  local body = fill(prompt.template, fill_ctx)
  return preamble .. "\n" .. body .. "\n\nJSON only:"
end

return M
