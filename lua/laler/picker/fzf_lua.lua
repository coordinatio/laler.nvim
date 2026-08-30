---@implements laler.Picker
local M = {}

---@param items laler.PickerItem[]
---@param opts { prompt?: string, default_id?: string }
---@param on_choice fun(id: string)
---@param on_cancel? fun()
function M:pick(items, opts, on_choice, on_cancel)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return require("laler.picker.vim_ui"):pick(items, opts, on_choice, on_cancel)
  end

  opts = opts or {}
  local lines = {}
  local by_line = {}
  for _, it in ipairs(items) do
    local line = it.description and (it.label .. " — " .. it.description) or it.label
    lines[#lines + 1] = line
    by_line[line] = it.id
  end

  fzf.fzf_exec(lines, {
    prompt = (opts.prompt or "laler") .. "> ",
    actions = {
      ["default"] = function(selected)
        if not selected or not selected[1] then
          if on_cancel then
            on_cancel()
          end
          return
        end
        local id = by_line[selected[1]]
        if id then
          on_choice(id)
        elseif on_cancel then
          on_cancel()
        end
      end,
    },
  })
end

return M
