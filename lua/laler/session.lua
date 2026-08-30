local M = {}

---@type laler.SessionCtx?
local ctx = nil

---@type { range: laler.Range, prompt_id: string, variants?: laler.Variant[], index?: integer, original?: string, raw?: string, gen: integer }?
local active = nil

local request_gen = 0

---@param c laler.SessionCtx
function M.bind(c)
  ctx = c
end

---@return laler.SessionCtx
local function require_ctx()
  if not ctx then
    error("laler: call require('laler').setup() first")
  end
  return ctx
end

local function notify(msg, level)
  vim.notify("laler: " .. msg, level or vim.log.levels.INFO)
end

---@param text string
local function yank_text(text)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  pcall(vim.fn.setreg, "*", text)
end

---@return laler.ReviewCallbacks
local function make_callbacks()
  local c = require_ctx()
  return {
    on_apply = function()
      if not active or not active.variants or not active.index then
        return
      end
      local variant = active.variants[active.index]
      if not variant then
        return
      end
      local ok, err = c.apply:apply(active.range, variant.text)
      if not ok then
        notify(err or "apply failed", vim.log.levels.ERROR)
        return
      end
      c.view:close()
      active = nil
    end,
    on_next = function()
      if not active or not active.variants then
        return
      end
      active.index = (active.index % #active.variants) + 1
      M._show_current()
    end,
    on_prev = function()
      if not active or not active.variants then
        return
      end
      active.index = active.index - 1
      if active.index < 1 then
        active.index = #active.variants
      end
      M._show_current()
    end,
    on_jump = function(index)
      if not active or not active.variants then
        return
      end
      if index >= 1 and index <= #active.variants then
        active.index = index
        M._show_current()
      end
    end,
    on_yank = function()
      if not active or not active.variants or not active.index then
        return
      end
      local variant = active.variants[active.index]
      if variant then
        yank_text(variant.text)
        notify("yanked " .. variant.label)
      end
    end,
    on_retry = function()
      if not active then
        return
      end
      M._start_job(active.range, active.prompt_id)
    end,
    on_cancel = function()
      local c2 = require_ctx()
      c2.jobs:cancel()
      c2.view:close()
      active = nil
    end,
    on_close = function()
      local c2 = require_ctx()
      c2.jobs:cancel()
      c2.view:close()
      active = nil
    end,
  }
end

function M._show_current()
  local c = require_ctx()
  if not active or not active.variants or not active.index then
    return
  end
  local variant = active.variants[active.index]
  local diff_doc = c.diff:diff(active.original or active.range.text, variant.text)
  ---@type laler.ReviewState
  local state = {
    prompt_id = active.prompt_id,
    adapter_name = c.llm.name,
    original = active.original or active.range.text,
    variants = active.variants,
    index = active.index,
    diff_doc = diff_doc,
  }
  c.view:show_review(state, make_callbacks())
end

---@param range laler.Range
---@param prompt_id string
function M._start_job(range, prompt_id)
  local c = require_ctx()
  local prompt = c.catalog:get(prompt_id)
  if not prompt then
    notify("unknown prompt '" .. prompt_id .. "'", vim.log.levels.ERROR)
    return
  end

  c.catalog:remember(prompt_id)
  request_gen = request_gen + 1
  local gen = request_gen
  active = {
    range = range,
    prompt_id = prompt_id,
    original = range.text,
    gen = gen,
  }

  local ft = ""
  if vim.api.nvim_buf_is_valid(range.bufnr) then
    ft = vim.bo[range.bufnr].filetype or ""
  end
  local composed = c.composer:compose(prompt, {
    text = range.text,
    language = c.config.language or "en",
    filetype = ft,
    n_variants = c.config.n_variants or 3,
  })

  local callbacks = make_callbacks()
  c.view:open_loading({ prompt_id = prompt_id, adapter_name = c.llm.name }, callbacks)

  local spec = c.llm:request(composed)
  c.jobs:start(spec, {
    on_exit = function(ok, stdout, stderr, code)
      if not active or active.gen ~= gen then
        return
      end
      if not ok then
        local msg = "command failed (exit " .. tostring(code) .. ")"
        if stderr and stderr ~= "" then
          msg = msg .. ": " .. vim.trim(stderr):sub(1, 200)
        end
        active.raw = (stdout or "") .. (stderr ~= "" and ("\n" .. stderr) or "")
        c.view:show_error(msg, active.raw, make_callbacks())
        return
      end

      local parsed_ok, result = c.parser:parse(stdout)
      if not parsed_ok then
        active.raw = stdout
        c.view:show_error(tostring(result), stdout, make_callbacks())
        return
      end

      ---@cast result laler.Variant[]
      active.variants = result
      active.index = 1
      M._show_current()
    end,
  }, { timeout_ms = c.config.timeout_ms })
end

---@param range laler.Range
---@param prompt_id? string
function M.run_with_range(range, prompt_id)
  local c = require_ctx()
  if not range.text or range.text == "" then
    notify("empty selection", vim.log.levels.WARN)
    return
  end
  local id = prompt_id or c.catalog:default_id()
  M._start_job(range, id)
end

--- Run with default/last prompt on captured range.
---@param range laler.Range
function M.run(range)
  M.run_with_range(range, nil)
end

--- Open picker then run.
---@param range laler.Range
function M.pick_and_run(range)
  local c = require_ctx()
  if not range.text or range.text == "" then
    notify("empty selection", vim.log.levels.WARN)
    return
  end

  local items = {}
  local default_id = c.catalog:default_id()
  -- Put default first for vim.ui.select UX
  local defs = c.catalog:list()
  local ordered = {}
  for _, p in ipairs(defs) do
    if p.id == default_id then
      table.insert(ordered, 1, p)
    else
      ordered[#ordered + 1] = p
    end
  end
  for _, p in ipairs(ordered) do
    items[#items + 1] = {
      id = p.id,
      label = p.label,
      description = p.description,
    }
  end

  c.picker:pick(items, {
    prompt = "laler prompt",
    default_id = default_id,
  }, function(id)
    M._start_job(range, id)
  end)
end

function M.cancel()
  local c = require_ctx()
  c.jobs:cancel()
  c.view:close()
  active = nil
end

---@return string[]
function M.prompt_ids()
  local c = require_ctx()
  local ids = {}
  for _, p in ipairs(c.catalog:list()) do
    ids[#ids + 1] = p.id
  end
  return ids
end

return M
