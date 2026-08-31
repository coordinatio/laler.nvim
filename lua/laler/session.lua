local M = {}

---@type laler.SessionCtx?
local ctx = nil

---@type { range: laler.Range, prompt_id: string, variants?: laler.Variant[], index?: integer, original?: string, raw?: string, gen: integer }?
local active = nil

local request_gen = 0
local pick_gen = 0
local pending_pick_range = nil ---@type laler.Range?

--- Byte cap so a mistaken whole-buffer range is not sent to the model.
M.MAX_RANGE_BYTES = 100000
--- Line cap (newlines + 1); refuse accidental huge captures.
M.MAX_RANGE_LINES = 10000

local stop_session

---@param c laler.SessionCtx
function M.bind(c)
  if ctx then
    stop_session()
  end
  ctx = c
  -- Keep request_gen / pick_gen monotonic so a custom JobRunner that still
  -- delivers an old callback cannot collide with a new job after rebind.
  active = nil
  pending_pick_range = nil
end

--- Test helper: in-flight review/job, or nil when stopped.
function M._active()
  return active
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

---@param text string
---@return boolean
local function too_large(text)
  if type(text) ~= "string" then
    return true
  end
  if #text > M.MAX_RANGE_BYTES then
    return true
  end
  local nlines = 1
  for _ in text:gmatch("\n") do
    nlines = nlines + 1
    if nlines > M.MAX_RANGE_LINES then
      return true
    end
  end
  return false
end

--- Test helper: whether captured text exceeds the send cap.
---@param text string
---@return boolean
function M._too_large(text)
  return too_large(text)
end

---@param range laler.Range
---@return boolean rejected
local function reject_oversize(range)
  if not range or not too_large(range.text) then
    return false
  end
  notify("selection too large", vim.log.levels.WARN)
  require_ctx().capture:delete_marks(range)
  return true
end

---@param range laler.Range?
---@return boolean rejected
local function reject_empty(range)
  if range and range.text and range.text ~= "" then
    return false
  end
  notify("empty selection", vim.log.levels.WARN)
  if range then
    require_ctx().capture:delete_marks(range)
  end
  return true
end

---@param range laler.Range
---@return boolean rejected
local function reject_unwritable(range)
  if not range or type(range.bufnr) ~= "number" then
    return false
  end
  if not vim.api.nvim_buf_is_valid(range.bufnr) then
    return false
  end
  local bo = vim.bo[range.bufnr]
  if bo.modifiable and not bo.readonly then
    return false
  end
  notify("buffer is not modifiable", vim.log.levels.WARN)
  require_ctx().capture:delete_marks(range)
  return true
end

--- Drop a pending picker so a stale `on_choice` is ignored (`gen ~= pick_gen`).
local function invalidate_pick()
  pick_gen = pick_gen + 1
  if pending_pick_range then
    require_ctx().capture:delete_marks(pending_pick_range)
    pending_pick_range = nil
  end
end

stop_session = function()
  local c = require_ctx()
  invalidate_pick()
  c.jobs:cancel()
  if active then
    c.capture:delete_marks(active.range)
  end
  c.view:close()
  active = nil
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
      c.capture:delete_marks(active.range)
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
        local text = variant.text
        if c.apply and c.apply.normalize_apply_text then
          text = c.apply.normalize_apply_text(text)
        end
        yank_text(text)
        notify("yanked " .. variant.label)
      end
    end,
    on_retry = function()
      if not active then
        return
      end
      local range = active.range
      local prompt_id = active.prompt_id
      if range.start_mark ~= nil or range.end_mark ~= nil then
        local refreshed = c.capture.refresh_from_marks and c.capture:refresh_from_marks(range)
        if not refreshed then
          notify("selection is gone", vim.log.levels.WARN)
          stop_session()
          return
        end
        active.original = range.text
      end
      if reject_empty(range) or reject_oversize(range) then
        -- Close UI and drop `active` so Apply cannot write a vanished span.
        stop_session()
        return
      end
      M._start_job(range, prompt_id)
    end,
    on_cancel = function()
      stop_session()
    end,
    on_close = function()
      stop_session()
    end,
  }
end

function M._show_current()
  local c = require_ctx()
  if not active or not active.variants or not active.index then
    return
  end
  local variant = active.variants[active.index]
  local shown = variant.text
  if c.apply and c.apply.normalize_apply_text then
    shown = c.apply.normalize_apply_text(shown)
  end
  local diff_doc = c.diff:diff(active.original or active.range.text, shown)
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
  if reject_unwritable(range) then
    return
  end
  local prompt = c.catalog:get(prompt_id)
  if not prompt then
    notify("unknown prompt '" .. prompt_id .. "'", vim.log.levels.ERROR)
    if not active or active.range ~= range then
      c.capture:delete_marks(range)
    end
    return
  end

  -- Cancel the previous CLI before compose/request so a failed start cannot
  -- leave the old process running (`jobs:start` is never reached then).
  c.jobs:cancel()

  if pending_pick_range and pending_pick_range ~= range then
    c.capture:delete_marks(pending_pick_range)
  end
  pending_pick_range = nil

  if active and active.range ~= range then
    c.capture:delete_marks(active.range)
  end

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
  local ok_compose, composed = pcall(function()
    return c.composer:compose(prompt, {
      text = range.text,
      language = c.config.language or "en",
      filetype = ft,
      n_variants = c.config.n_variants or 3,
    })
  end)
  if not ok_compose then
    c.view:show_error(tostring(composed), nil, make_callbacks())
    return
  end

  -- range.cwd is from capture; last-resort getcwd() is before the float (:lcd).
  local cwd = range.cwd or vim.fn.getcwd()
  local callbacks = make_callbacks()
  c.view:open_loading({ prompt_id = prompt_id, adapter_name = c.llm.name }, callbacks)

  local ok_req, spec = pcall(function()
    return c.llm:request(composed)
  end)
  if not ok_req then
    c.view:show_error(tostring(spec), nil, make_callbacks())
    return
  end
  if type(spec) ~= "table" or type(spec.cmd) ~= "string" or spec.cmd == "" then
    c.view:show_error("invalid command", nil, make_callbacks())
    return
  end
  spec.cwd = spec.cwd or cwd

  local ok_start, start_err = pcall(function()
    c.jobs:start(spec, {
      on_exit = function(ok, stdout, stderr, code, signal)
        if not active or active.gen ~= gen then
          return
        end
        if not ok then
          local msg
          if code == 124 then
            local ms = c.config and c.config.timeout_ms
            if ms then
              msg = "timed out after " .. tostring(ms) .. " ms"
            else
              msg = "timed out"
            end
          elseif signal and signal ~= 0 then
            msg = "killed by signal " .. tostring(signal)
          else
            msg = "command failed (exit " .. tostring(code) .. ")"
          end
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

        c.catalog:remember(prompt_id)
        active.variants = result
        active.index = 1
        M._show_current()
      end,
    }, { timeout_ms = c.config.timeout_ms })
  end)
  if not ok_start then
    c.view:show_error(tostring(start_err), nil, make_callbacks())
  end
end

---@param range laler.Range
---@param prompt_id? string
function M.run_with_range(range, prompt_id)
  local c = require_ctx()
  if reject_empty(range) then
    return
  end
  if reject_oversize(range) then
    return
  end
  if reject_unwritable(range) then
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
  if reject_empty(range) then
    return
  end
  if reject_oversize(range) then
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
      label = p.label or p.id,
      description = p.description,
    }
  end

  if pending_pick_range and pending_pick_range ~= range then
    c.capture:delete_marks(pending_pick_range)
  end
  pick_gen = pick_gen + 1
  local gen = pick_gen
  local job_gen_at_pick = request_gen
  pending_pick_range = range

  local function cancel_pick()
    if gen ~= pick_gen or request_gen ~= job_gen_at_pick then
      return
    end
    pick_gen = pick_gen + 1
    pending_pick_range = nil
    c.capture:delete_marks(range)
  end

  local ok_pick, pick_err = pcall(function()
    c.picker:pick(items, {
      prompt = "laler prompt",
      default_id = default_id,
    }, function(id)
      vim.schedule(function()
        if gen ~= pick_gen or request_gen ~= job_gen_at_pick then
          return
        end
        pending_pick_range = nil
        if not id then
          c.capture:delete_marks(range)
          return
        end
        if c.capture.refresh_from_marks then
          if not c.capture:refresh_from_marks(range) then
            notify("selection is gone", vim.log.levels.WARN)
            c.capture:delete_marks(range)
            return
          end
        end
        if reject_empty(range) or reject_oversize(range) then
          return
        end
        M._start_job(range, id)
      end)
    end, cancel_pick)
  end)
  if not ok_pick then
    cancel_pick()
    notify(tostring(pick_err), vim.log.levels.ERROR)
  end
end

function M.cancel()
  stop_session()
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

--- Prefix-filter prompt ids for command completion (`arglead`).
---@param ids string[]
---@param arglead? string
---@return string[]
function M.filter_prompt_ids(ids, arglead)
  arglead = arglead or ""
  if arglead == "" then
    return ids
  end
  local out = {}
  for _, id in ipairs(ids) do
    if id:sub(1, #arglead) == arglead then
      out[#out + 1] = id
    end
  end
  return out
end

---@param arglead? string
---@return string[]
function M.complete_prompt_ids(arglead)
  return M.filter_prompt_ids(M.prompt_ids(), arglead)
end

return M
