---@implements laler.Picker
local M = {}

---@param items laler.PickerItem[]
---@param opts { prompt?: string, default_id?: string }
---@param on_choice fun(id: string)
---@param on_cancel? fun()
function M:pick(items, opts, on_choice, on_cancel)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return require("laler.picker.vim_ui"):pick(items, opts, on_choice, on_cancel)
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  opts = opts or {}
  local chosen = false

  pickers
    .new({}, {
      prompt_title = opts.prompt or "laler prompt",
      finder = finders.new_table({
        results = items,
        entry_maker = function(it)
          return {
            value = it.id,
            display = it.description and (it.label .. " — " .. it.description) or it.label,
            ordinal = it.label .. " " .. (it.description or "") .. " " .. it.id,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function select()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.value then
            chosen = true
            on_choice(entry.value)
          elseif on_cancel then
            on_cancel()
          end
        end
        actions.select_default:replace(select)
        map("i", "<CR>", select)
        map("n", "<CR>", select)
        return true
      end,
    })
    :find()

  -- Telescope close without selection: listen via autocmd is heavy; rely on user Esc.
  -- If they close without selecting, telescope may not call us — acceptable for v1.
  _ = chosen
end

return M
