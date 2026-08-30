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
      attach_mappings = function(prompt_bufnr, _)
        local function fire_cancel()
          if chosen then
            return
          end
          chosen = true
          if on_cancel then
            on_cancel()
          end
        end
        local function select()
          if chosen then
            return
          end
          chosen = true
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.value then
            vim.schedule(function()
              on_choice(entry.value)
            end)
          elseif on_cancel then
            on_cancel()
          end
        end
        actions.select_default:replace(select)
        -- Esc / close without a choice: on_cancel once (`chosen` guards select).
        pcall(function()
          actions.close:enhance({
            post = fire_cancel,
          })
        end)
        return true
      end,
    })
    :find()
end

return M
