local config = require("laler.config")
local session = require("laler.session")

local M = {}

---@type table|nil
M._config = nil

local operator_mode = "run" ---@type "run"|"pick"

local last_map = {
  run = nil, ---@type string|nil
  pick = nil, ---@type string|nil
}

---@param lhs string|nil
local function unmap_lhs(lhs)
  if type(lhs) ~= "string" or lhs == "" then
    return
  end
  pcall(vim.keymap.del, "n", lhs)
  pcall(vim.keymap.del, "x", lhs)
end

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

  M._apply_mappings(cfg.mappings)
end

---@param mappings { run?: string|false, pick?: string|false }|false|nil
function M._apply_mappings(mappings)
  unmap_lhs(last_map.run)
  unmap_lhs(last_map.pick)
  last_map.run = nil
  last_map.pick = nil

  if type(mappings) ~= "table" then
    return
  end

  local run = mappings.run
  if type(run) == "string" and run ~= "" then
    vim.keymap.set("n", run, function()
      return M.operator_run()
    end, { desc = "laler: correct (operator)", expr = true })
    vim.keymap.set("x", run, function()
      M.run_visual()
    end, { desc = "laler: correct selection" })
    last_map.run = run
  end
  local pick = mappings.pick
  if type(pick) == "string" and pick ~= "" then
    vim.keymap.set("n", pick, function()
      return M.operator_pick()
    end, { desc = "laler: pick prompt (operator)", expr = true })
    vim.keymap.set("x", pick, function()
      M.pick_visual()
    end, { desc = "laler: pick prompt for selection" })
    last_map.pick = pick
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

--- Visual `:'<,'>Laler` inserts a line range; if last visual was char-wise
--- (`v`) and line1/line2 match `'<`/`'>`, capture columns via `from_visual()`.
--- Linewise `V` (or a range that does not match the marks) stays linewise.
--- Blockwise `\22` is not supported as char capture; fall back to linewise.
--- Bare `:Laler` (`opts.range == 0` / nil) always uses the command line range
--- so leftover `'<`/`'>` from a prior char visual is not reused.
---@param line1 integer
---@param line2 integer
---@param range_count? integer `opts.range` from the user command (0 = no range)
---@return laler.Range?, string?
function M.range_from_command(line1, line2, range_count)
  local capture = require("laler.range")
  if range_count == nil or range_count < 2 then
    return capture:from_command_range(line1, line2)
  end
  local vm = vim.fn.visualmode()
  if vm == "\22" then
    return capture:from_command_range(line1, line2)
  end
  if vm == "v" then
    local a = vim.fn.getpos("'<")
    local b = vim.fn.getpos("'>")
    if a[2] > 0 and b[2] > 0 then
      local mark1 = math.min(a[2], b[2])
      local mark2 = math.max(a[2], b[2])
      if line1 == mark1 and line2 == mark2 then
        return capture:from_visual()
      end
    end
  end
  return capture:from_command_range(line1, line2)
end

---@param line1 integer
---@param line2 integer
---@param prompt_id? string
---@param range_count? integer
function M.run_command(line1, line2, prompt_id, range_count)
  M.setup_if_needed()
  local range, err = M.range_from_command(line1, line2, range_count)
  if not range then
    vim.notify("laler: " .. (err or "invalid range"), vim.log.levels.WARN)
    return
  end
  session.run_with_range(range, prompt_id ~= "" and prompt_id or nil)
end

---@param line1 integer
---@param line2 integer
---@param range_count? integer
function M.pick_command(line1, line2, range_count)
  M.setup_if_needed()
  local range, err = M.range_from_command(line1, line2, range_count)
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

--- Command-line completion for `:Laler` prompt ids (prefix match on `arglead`).
---@param arglead? string
---@return string[]
function M.complete_prompts(arglead)
  M.setup_if_needed()
  return session.complete_prompt_ids(arglead)
end

return M
