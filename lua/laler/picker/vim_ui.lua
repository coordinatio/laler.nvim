---@implements laler.Picker
local M = {}

---@param items laler.PickerItem[]
---@param opts { prompt?: string, default_id?: string }
---@param on_choice fun(id: string)
---@param on_cancel? fun()
function M:pick(items, opts, on_choice, on_cancel)
  opts = opts or {}
  local labels = {}
  local by_label = {}
  local default_idx = 1
  for i, it in ipairs(items) do
    local label = it.label
    if it.description then
      label = label .. " — " .. it.description
    end
    labels[#labels + 1] = label
    by_label[label] = it.id
    if opts.default_id and it.id == opts.default_id then
      default_idx = i
    end
  end

  vim.ui.select(labels, {
    prompt = opts.prompt or "laler prompt",
  }, function(choice)
    if not choice then
      if on_cancel then
        on_cancel()
      end
      return
    end
    on_choice(by_label[choice])
  end)

  -- Best-effort: preselect default when using snacks/custom — vim.ui.select has no index API.
  -- Document that first item / remembered is listed first by session ordering.
  _ = default_idx
end

return M
