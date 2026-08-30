---@implements laler.VariantParser
local M = {}

local PLACEHOLDER_TEXTS = {
  ["corrected passage only"] = true,
  ["<corrected passage>"] = true,
}

---@param s string
---@return string?
local function extract_fenced(s)
  if not s or s == "" then
    return nil
  end
  local fenced = s:match("```json%s*([\r\n].-[\r\n])```")
    or s:match("```json%s*(.-)```")
    or s:match("```%s*([\r\n]%s*{.-}[%s\r\n]*)```")
  if fenced then
    local trimmed = vim.trim(fenced)
    if trimmed:sub(1, 1) == "{" then
      return trimmed
    end
  end
  return nil
end

--- Extract a balanced `{ ... }` object starting at `start`. Skips strings.
---@param s string
---@param start integer
---@return string? blob
---@return integer? finish inclusive index of closing brace
local function extract_object_at(s, start)
  local depth = 0
  local finish = nil
  local i = start
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "{" then
      depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        finish = i
        break
      end
    elseif ch == '"' then
      i = i + 1
      while i <= n do
        local c = s:sub(i, i)
        if c == "\\" then
          i = i + 2
        elseif c == '"' then
          break
        else
          i = i + 1
        end
      end
    end
    i = i + 1
  end
  if not finish then
    return nil, nil
  end
  return s:sub(start, finish), finish
end

---@param s string
---@return integer?
local function first_delimiter(s)
  local open = s:find("<<<LALER_TEXT", 1, true)
  local close = s:find("<<<END_LALER_TEXT", 1, true)
  if open and close then
    return math.min(open, close)
  end
  return open or close
end

---@param text string
---@return string
local function scrub_variant_text(text)
  -- Fully wrapped in capture delimiters: keep the inner passage.
  local wrapped = text:match("^%s*<<<LALER_TEXT[_%w]*>>>%s*(.-)%s*<<<END_LALER_TEXT[_%w]*>>>%s*$")
  if wrapped then
    return vim.trim(wrapped)
  end
  -- Leakage of prompt delimiters (including suffixed unique markers): cut there.
  local idx = first_delimiter(text)
  if idx then
    text = text:sub(1, idx - 1)
  end
  return vim.trim(text)
end

---@param data table
---@return laler.Variant[]?, string?
local function normalize(data)
  if type(data) ~= "table" then
    return nil, "JSON root is not an object"
  end
  local variants = data.variants
  if type(variants) ~= "table" then
    return nil, 'missing "variants" array'
  end
  local out = {}
  for i, v in ipairs(variants) do
    if type(v) ~= "table" then
      return nil, "variant " .. i .. " is not an object"
    end
    if type(v.text) == "string" and v.text ~= "" then
      local text = scrub_variant_text(v.text)
      if text ~= "" and not PLACEHOLDER_TEXTS[text] then
        local notes = v.notes
        if notes == nil then
          notes = {}
        elseif type(notes) == "string" then
          notes = { notes }
        elseif type(notes) ~= "table" then
          return nil, "variant " .. i .. ' "notes" must be array or string'
        else
          local cleaned = {}
          for _, n in ipairs(notes) do
            if type(n) == "string" then
              cleaned[#cleaned + 1] = n
            end
          end
          notes = cleaned
        end
        out[#out + 1] = {
          label = type(v.label) == "string" and v.label ~= "" and v.label or ("variant-" .. i),
          text = text,
          notes = notes,
        }
      end
    end
  end
  if #out == 0 then
    return nil, "no valid variants"
  end
  return out
end

---@param blob string
---@return laler.Variant[]?, string?
local function decode_and_normalize(blob)
  local ok, data = pcall(vim.json.decode, blob)
  if not ok then
    return nil, "JSON decode failed: " .. tostring(data)
  end
  return normalize(data)
end

---@param stdout string
---@return boolean, laler.Variant[]|string
function M:parse(stdout)
  local last = nil
  local last_err = "could not find JSON object in model output"

  local function consider(blob)
    local variants, err = decode_and_normalize(blob)
    if variants then
      last = variants
    else
      last_err = err or last_err
    end
  end

  local fenced = extract_fenced(stdout)
  if fenced then
    consider(fenced)
  end

  local i = 1
  local n = #stdout
  while i <= n do
    local start = stdout:find("{", i, true)
    if not start then
      break
    end
    local blob, finish = extract_object_at(stdout, start)
    if not blob or not finish then
      i = start + 1
    else
      consider(blob)
      i = finish + 1
    end
  end

  if last then
    return true, last
  end
  return false, last_err
end

return M
