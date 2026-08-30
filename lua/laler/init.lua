local config = require("laler.config")
local session = require("laler.session")

local M = {}

---@type table|nil
M._config = nil

local operator_mode = "run" ---@type "run"|"pick"

---@param user_opts table|nil
function M.setup(user_opts)
  local cfg = config.merge(user_opts)
  local ok, err = config.validate(cfg)
  if not ok then
    error("laler: " .. err)
  end

  local catalog = require("laler.prompt.catalog").new({
    prompts = cfg.prompts,
    default_prompt = cfg.default_prompt,
    remember_last_prompt = cfg.remember_last_prompt,
  })

  local llm_reg = require("laler.llm")
  local picker_reg = require("laler.picker")

  ---@type laler.SessionCtx
  local ctx = {
    config = cfg,
    catalog = catalog,
    composer = require("laler.prompt.composer"),
    llm = llm_reg.resolve(cfg.adapter),
    jobs = require("laler.job.vim_system"),
    parser = require("laler.parse.json"),
    picker = picker_reg.resolve(cfg.picker),
    diff = require("laler.diff.vim_diff"),
    view = require("laler.view.float"),
    capture = require("laler.range"),
    apply = require("laler.apply"),
  }

  session.bind(ctx)
  M._config = cfg

  if cfg.mappings and type(cfg.mappings) == "table" then
    M._apply_mappings(cfg.mappings)
  end
end

---@param mappings { run?: string|false, pick?: string|false }
function M._apply_mappings(mappings)
  if mappings.run then
    vim.keymap.set("n", mappings.run, function()
      return M.operator_run()
    end, { desc = "laler: correct (operator)", expr = true })
    vim.keymap.set("x", mappings.run, function()
      M.run_visual()
    end, { desc = "laler: correct selection" })
  end
  if mappings.pick then
    vim.keymap.set("n", mappings.pick, function()
      return M.operator_pick()
    end, { desc = "laler: pick prompt (operator)", expr = true })
    vim.keymap.set("x", mappings.pick, function()
      M.pick_visual()
    end, { desc = "laler: pick prompt for selection" })
  end
end

function M.run_visual()
  M.setup_if_needed()
  local capture = require("laler.range")
  local range, err = capture:from_visual()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  if not range then
    vim.notify("laler: " .. (err or "no selection"), vim.log.levels.WARN)
    return
  end
  session.run(range)
end

function M.pick_visual()
  M.setup_if_needed()
  local capture = require("laler.range")
  local range, err = capture:from_visual()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  if not range then
    vim.notify("laler: " .. (err or "no selection"), vim.log.levels.WARN)
    return
  end
  session.pick_and_run(range)
end

---@return string
function M.operator_run()
  M.setup_if_needed()
  operator_mode = "run"
  vim.o.operatorfunc = "v:lua.require'laler'.operator_callback"
  return "g@"
end

---@return string
function M.operator_pick()
  M.setup_if_needed()
  operator_mode = "pick"
  vim.o.operatorfunc = "v:lua.require'laler'.operator_callback"
  return "g@"
end

---@param mode string
function M.operator_callback(mode)
  M.setup_if_needed()
  local capture = require("laler.range")
  local range, err = capture:from_operator(mode)
  if not range then
    vim.notify("laler: " .. (err or "no range"), vim.log.levels.WARN)
    return
  end
  if operator_mode == "pick" then
    session.pick_and_run(range)
  else
    session.run(range)
  end
end

---@param line1 integer
---@param line2 integer
---@param prompt_id? string
function M.run_command(line1, line2, prompt_id)
  M.setup_if_needed()
  local capture = require("laler.range")
  local range, err = capture:from_command_range(line1, line2)
  if not range then
    vim.notify("laler: " .. (err or "invalid range"), vim.log.levels.WARN)
    return
  end
  session.run_with_range(range, prompt_id ~= "" and prompt_id or nil)
end

function M.pick_command(line1, line2)
  M.setup_if_needed()
  local capture = require("laler.range")
  local range, err = capture:from_command_range(line1, line2)
  if not range then
    vim.notify("laler: " .. (err or "invalid range"), vim.log.levels.WARN)
    return
  end
  session.pick_and_run(range)
end

function M.cancel()
  if M._config then
    session.cancel()
  end
end

function M.setup_if_needed()
  if not M._config then
    M.setup({})
  end
end

return M
