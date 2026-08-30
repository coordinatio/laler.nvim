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
    local line = M._item_line(it)
    lines[#lines + 1] = line
    by_line[line] = it.id
  end

  fzf.fzf_exec(lines, {
    prompt = (opts.prompt or "laler") .. "> ",
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or not selected[1] then
          if on_cancel then
            on_cancel()
          end
          return
        end
        local id = by_line[selected[1]] or M._id_from_line(selected[1])
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
