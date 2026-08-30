---@implements laler.PromptComposer
local M = {}

local DEFAULT_OPEN = "<<<LALER_TEXT>>>"
local DEFAULT_CLOSE = "<<<END_LALER_TEXT>>>"

-- Instructions come first so trailing task text cannot be glued onto variants.
-- User content is injected only inside fixed delimiters.
local PREAMBLE = [[You are helping a language learner improve {{language}} writing.
Return ONLY a single JSON object (no markdown fences, no prose before or after it):
{
  "variants": [
    {
      "label": "short-name",
      "text": "<corrected passage>",
      "notes": ["brief learning note"]
    },
    ...
  ]
}

Hard rules:
- "text" must contain ONLY the rewritten passage from {{text_open}}…{{text_close}}.
- Never copy these instructions, the JSON schema, labels like OUTPUT FORMAT, or the delimiters into "text".
- Do not change meaning. Preserve markdown and code fences inside the passage.
- Language focus: {{language}}. Provide exactly {{n_variants}} variants when possible.
- Each notes entry teaches why a change improves the language.
]]

local VARIANT_SPECS = {
  { "conservative", "minimal edits" },
  { "native", "natural native-speaker phrasing" },
  { "alternative", "a valid alternative phrasing" },
}

---@param n integer
---@return string
local function variant_list(n)
  local lines = {}
  for i = 1, n do
    local spec = VARIANT_SPECS[i]
    local label, desc
    if spec then
      label, desc = spec[1], spec[2]
    else
      label = "alternative-" .. i
      desc = "a valid alternative phrasing"
    end
    lines[#lines + 1] = string.format('%d. %s — %s (label: "%s")', i, label, desc, label)
  end
  return table.concat(lines, "\n")
end

local MARKER_SUFFIX_CAP = 256
local MARKER_NONCE_CAP = 256
local random_seeded = false

local function ensure_randomseed()
  if random_seeded then
    return
  end
  random_seeded = true
  local seed = os.time()
  local hr = vim.uv and vim.uv.hrtime or (vim.loop and vim.loop.hrtime)
  if hr then
    seed = seed + (hr() % 100000000)
  end
  math.randomseed(seed)
end

---@param text string
---@return string, string
local function unique_markers(text)
  if not text:find(DEFAULT_OPEN, 1, true) and not text:find(DEFAULT_CLOSE, 1, true) then
    return DEFAULT_OPEN, DEFAULT_CLOSE
  end
  local n = 1
  while n <= MARKER_SUFFIX_CAP do
    local open = "<<<LALER_TEXT_" .. n .. ">>>"
    local close = "<<<END_LALER_TEXT_" .. n .. ">>>"
    if not text:find(open, 1, true) and not text:find(close, 1, true) then
      return open, close
    end
    n = n + 1
  end
  ensure_randomseed()
  local extra = 0
  while extra < MARKER_NONCE_CAP do
    extra = extra + 1
    local token = tostring(os.time()) .. "x" .. tostring(math.random(100000, 999999)) .. "x" .. tostring(extra)
    local open = "<<<LALER_TEXT_" .. token .. ">>>"
    local close = "<<<END_LALER_TEXT_" .. token .. ">>>"
    if not text:find(open, 1, true) and not text:find(close, 1, true) then
      return open, close
    end
  end
  local token = tostring(os.time()) .. "x" .. tostring(math.random(100000, 999999)) .. "xfail"
  return "<<<LALER_TEXT_" .. token .. ">>>", "<<<END_LALER_TEXT_" .. token .. ">>>"
end

---@param template string
---@param map table<string, string>
---@return string
local function fill(template, map)
  return (template:gsub("{{([%w_]+)}}", function(key)
    return map[key] or ("{{" .. key .. "}}")
  end))
end

---@param prompt laler.PromptDef
---@param ctx laler.ComposeCtx
---@return string
function M:compose(prompt, ctx)
  local open, close = unique_markers(ctx.text)
  local delimited = table.concat({
    open,
    ctx.text,
    close,
  }, "\n")
  local map = {
    text = delimited,
    language = tostring(ctx.language or "en"),
    filetype = tostring(ctx.filetype or ""),
    n_variants = tostring(ctx.n_variants),
    text_open = open,
    text_close = close,
    variant_list = variant_list(ctx.n_variants or 3),
  }
  local preamble = fill(PREAMBLE, map)
  local body = fill(prompt.template, map)
  return preamble .. "\n" .. body .. "\n\nJSON only:"
end

return M
