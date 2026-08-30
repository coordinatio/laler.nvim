---@implements laler.PromptComposer
local M = {}

local JSON_WRAPPER = [[

---
OUTPUT FORMAT (required):
Reply with ONLY a JSON object (no markdown fences, no commentary) of the form:
{
  "variants": [
    {
      "label": "short-name",
      "text": "full corrected text",
      "notes": ["brief learning note explaining a change"]
    }
  ]
}
Rules:
- Do not change the meaning of the text.
- Preserve markdown and code fences.
- Language focus: {{language}}
- Provide exactly {{n_variants}} variants when possible.
- Each notes entry should teach the user why the change improves the language.
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
  local body = fill(prompt.template, ctx)
  local wrapper = fill(JSON_WRAPPER, ctx)
  return body .. wrapper
end

return M
