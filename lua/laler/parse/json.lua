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

--- Walk left from `pos` to the `{` that opens the enclosing object. Skips strings.
---@param s string
---@param pos integer
---@return integer?
local function enclosing_object_start(s, pos)
  local i = pos - 1
  local depth = 0
  while i >= 1 do
    local ch = s:sub(i, i)
    if ch == '"' then
      i = i - 1
      while i >= 1 do
        if s:sub(i, i) == '"' then
          local bs = 0
          local j = i - 1
          while j >= 1 and s:sub(j, j) == "\\" do
            bs = bs + 1
            j = j - 1
          end
          if bs % 2 == 0 then
            break
          end
        end
        i = i - 1
      end
    elseif ch == "}" then
      depth = depth + 1
    elseif ch == "{" then
      if depth == 0 then
        return i
      end
      depth = depth - 1
    end
    i = i - 1
  end
  return nil
end

--- Strip at most one leading/trailing `\n` or `\r\n`. Keep blank lines in the passage.
---@param text string
---@return string
local function strip_wrapping_newlines(text)
  if text:sub(1, 2) == "\r\n" then
    text = text:sub(3)
  elseif text:sub(1, 1) == "\n" then
    text = text:sub(2)
  end
  if text:sub(-2) == "\r\n" then
    text = text:sub(1, -3)
  elseif text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end
  return text
end

---@param text string
---@return string
local function scrub_variant_text(text)
  -- Fully wrapped in capture delimiters: keep the inner passage (indent intact).
  -- Do not cut mid-text on delimiter prefixes; honest text may contain them.
  local wrapped = text:match("^[\r\n]*<<<LALER_TEXT[_%w]*>>>[\r\n]*(.-)[\r\n]*<<<END_LALER_TEXT[_%w]*>>>[\r\n]*$")
  if wrapped then
    return strip_wrapping_newlines(wrapped)
  end
  return strip_wrapping_newlines(text)
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

--- Join repeated "notes" keys into one array: `"notes":["a"],"notes":["b"]` → `"notes":["a","b"]`.
---@param s string
---@return string
local function merge_duplicate_notes(s)
  local prev
  local n = 0
  while s ~= prev and n < 16 do
    prev = s
    n = n + 1
    s = s:gsub('([^%[%]])%]%s*,%s*"notes"%s*:%s*%[', "%1,", 1)
  end
  return s
end

--- Decode JSON, repairing two common model mistakes:
--- duplicate "notes" keys, and an extra `}` after a variant (T_OBJ_END).
---@param blob string
---@return table?, string?
local function decode_json(blob)
  local current = merge_duplicate_notes(blob)
  local last_err
  for _ = 1, 8 do
    local ok, data = pcall(vim.json.decode, current)
    if ok then
      return data
    end
    last_err = data
    local pos = tonumber(tostring(data):match("T_OBJ_END at character (%d+)"))
    if not pos or pos < 1 or pos > #current or current:sub(pos, pos) ~= "}" then
      break
    end
    current = current:sub(1, pos - 1) .. current:sub(pos + 1)
  end
  return nil, "JSON decode failed: " .. tostring(last_err)
end

---@param blob string
---@return laler.Variant[]?, string?
local function decode_and_normalize(blob)
  local data, err = decode_json(blob)
  if not data then
    return nil, err
  end
  return normalize(data)
end

--- Collect variant objects even when the wrapping `{"variants":[...]}` is broken.
---@param s string
---@return laler.Variant[]?
local function salvage_variants(s)
  local wrapped = { variants = {} }
  local seen = {}
  local search_at = 1
  while true do
    local found = s:find('"text"%s*:', search_at)
    if not found then
      break
    end
    search_at = found + 1
    local start = enclosing_object_start(s, found)
    if start and not seen[start] then
      seen[start] = true
      local blob = extract_object_at(s, start)
      if blob then
        local data = decode_json(blob)
        if type(data) == "table" and type(data.variants) ~= "table" and type(data.text) == "string" then
          wrapped.variants[#wrapped.variants + 1] = data
        end
      end
    end
  end
  if #wrapped.variants == 0 then
    return nil
  end
  return normalize(wrapped)
end

---@param stdout string
---@return boolean, laler.Variant[]|string
function M:parse(stdout)
  local last = nil
  local find_err = "could not find JSON object in model output"
  local last_err = find_err

  local fenced = extract_fenced(stdout)
  if fenced then
    local variants, err = decode_and_normalize(fenced)
    if variants then
      return true, variants
    end
    last_err = err or last_err
  end

  -- Prefer the last successful `variants` object. Find `"variants"` keys
  -- and walk back to the enclosing `{` so braces in text or trailing `{x}`
  -- cannot hide the root object.
  local needle = '"variants"'
  local key_starts = {}
  local search_at = 1
  while true do
    local found = stdout:find(needle, search_at, true)
    if not found then
      break
    end
    key_starts[#key_starts + 1] = found
    search_at = found + 1
  end
  for k = #key_starts, 1, -1 do
    local start = enclosing_object_start(stdout, key_starts[k])
    if start then
      local blob = extract_object_at(stdout, start)
      if blob then
        local variants, err = decode_and_normalize(blob)
        if variants then
          last = variants
          break
        elseif err then
          -- Do not let inner `{x}` decode failures replace a useful
          -- normalize error from a variants object.
          local is_decode = err:find("JSON decode failed", 1, true) ~= nil
          local have_useful = last_err ~= find_err
            and last_err:find("JSON decode failed", 1, true) == nil
          if not (is_decode and have_useful) then
            last_err = err
          end
        end
      end
    end
  end

  if last then
    return true, last
  end

  -- extract_object_at stops at an extra `}` so the full payload may still
  -- decode after repair, or as loose variant objects after the cut.
  local variants = decode_and_normalize(stdout)
  if variants then
    return true, variants
  end
  variants = salvage_variants(stdout)
  if variants then
    return true, variants
  end

  return false, last_err
end

return M
