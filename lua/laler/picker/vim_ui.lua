---@implements laler.Picker
local M = {}

local SEP = "\t"

---@param it laler.PickerItem
---@return string
function M._item_line(it)
  local label = it.description and (it.label .. " — " .. it.description) or it.label
  return it.id .. SEP .. label
end

---@param line string
---@return string?
function M._id_from_line(line)
  if not line or line == "" then
    return nil
  end
  return line:match("^([^\t]+)")
end

---@param line string
---@return string
function M._format_item(line)
  local id, rest = line:match("^([^\t]+)\t(.*)$")
  if rest then
    return id .. "  " .. rest
  end
  return line
end

---@param items laler.PickerItem[]
---@param opts { prompt?: string, default_id?: string }
---@param on_choice fun(id: string)
---@param on_cancel? fun()
function M:pick(items, opts, on_choice, on_cancel)
  opts = opts or {}
  local labels = {}
  local by_key = {}
  local default_idx = 1
  for i, it in ipairs(items) do
    local key = M._item_line(it)
    -- Same id+label twice: still unique so last-wins cannot steal the first.
    if by_key[key] then
      key = key .. SEP .. tostring(i)
    end
    labels[#labels + 1] = key
    by_key[key] = it.id
    if opts.default_id and it.id == opts.default_id then
      default_idx = i
    end
  end

  vim.ui.select(labels, {
    prompt = opts.prompt or "laler prompt",
    format_item = M._format_item,
  }, function(choice)
    if not choice then
      if on_cancel then
        on_cancel()
      end
      return
    end
    on_choice(by_key[choice] or M._id_from_line(choice))
  end)

  -- Best-effort: preselect default when using snacks/custom — vim.ui.select has no index API.
  -- Document that first item / remembered is listed first by session ordering.
  _ = default_idx
end

return M
