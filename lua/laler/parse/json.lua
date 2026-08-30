---@implements laler.VariantParser
local M = {}

---@param s string
---@return string?
local function extract_json_blob(s)
  if not s or s == "" then
    return nil
  end

  -- fenced ```json ... ```
  local fenced = s:match("```json%s*([\r\n].-[\r\n])```")
    or s:match("```json%s*(.-)```")
    or s:match("```%s*([\r\n]%s*{.-}[%s\r\n]*)```")
  if fenced then
    local trimmed = vim.trim(fenced)
    if trimmed:sub(1, 1) == "{" then
      return trimmed
    end
  end

  -- first { ... matching last } (scan for outermost object)
  local start = s:find("{", 1, true)
  if not start then
    return nil
  end
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
      -- skip strings
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
    return nil
  end
  return s:sub(start, finish)
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
    if type(v.text) ~= "string" or v.text == "" then
      return nil, "variant " .. i .. ' missing "text"'
    end
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
      text = v.text,
      notes = notes,
    }
  end
  if #out == 0 then
    return nil, "variants array is empty"
  end
  return out
end

---@param stdout string
---@return boolean, laler.Variant[]|string
function M:parse(stdout)
  local blob = extract_json_blob(stdout)
  if not blob then
    return false, "could not find JSON object in model output"
  end
  local ok, data = pcall(vim.json.decode, blob)
  if not ok then
    return false, "JSON decode failed: " .. tostring(data)
  end
  local variants, err = normalize(data)
  if not variants then
    return false, err
  end
  return true, variants
end

return M
