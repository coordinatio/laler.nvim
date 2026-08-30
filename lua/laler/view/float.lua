---@implements laler.ReviewView
local M = {}

local NS = vim.api.nvim_create_namespace("laler_diff")

local state = {
  win = nil ---@type integer?
  ,
  buf = nil ---@type integer?
  ,
  callbacks = nil ---@type laler.ReviewCallbacks?
  ,
}

local function define_highlights()
  local dark = vim.o.background ~= "light"
  local function hi(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  if dark then
    hi("LalerDiffDeleteLine", { bg = "#3f0001" })
    hi("LalerDiffAddLine", { bg = "#002800" })
    hi("LalerDiffDeleteWord", { bg = "#901011" })
    hi("LalerDiffAddWord", { bg = "#006000" })
    hi("LalerHeader", { fg = "#24acd4", bold = true })
    hi("LalerMeta", { fg = "#888888", italic = true })
    hi("LalerNotes", { fg = "#c0c0a0" })
    hi("LalerHint", { fg = "#666666" })
  else
    hi("LalerDiffDeleteLine", { bg = "#ffdee2" })
    hi("LalerDiffAddLine", { bg = "#cfffd0" })
    hi("LalerDiffDeleteWord", { bg = "#ffc1bf" })
    hi("LalerDiffAddWord", { bg = "#9df0a2" })
    hi("LalerHeader", { fg = "#0088aa", bold = true })
    hi("LalerMeta", { fg = "#666666", italic = true })
    hi("LalerNotes", { fg = "#555533" })
    hi("LalerHint", { fg = "#888888" })
  end
end

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "laler"
  state.buf = buf
  return buf
end

local function open_win(buf)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(28, math.floor(vim.o.lines * 0.7))
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " laler ",
    title_pos = "center",
    zindex = 50,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  state.win = win
  return win
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param buf integer
---@param callbacks laler.ReviewCallbacks
---@param mode "loading"|"review"|"error"
local function map_keys(buf, callbacks, mode)
  local opts = { buffer = buf, nowait = true, silent = true, noremap = true }
  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, opts)
  end

  map("q", function()
    callbacks.on_close()
  end)
  map("<Esc>", function()
    if mode == "loading" then
      callbacks.on_cancel()
    else
      callbacks.on_close()
    end
  end)

  if mode == "review" then
    map("<CR>", function()
      callbacks.on_apply()
    end)
    map("Tab", function()
      callbacks.on_next()
    end)
    map("n", function()
      callbacks.on_next()
    end)
    map("]", function()
      callbacks.on_next()
    end)
    map("<S-Tab>", function()
      callbacks.on_prev()
    end)
    map("p", function()
      callbacks.on_prev()
    end)
    map("[", function()
      callbacks.on_prev()
    end)
    map("y", function()
      callbacks.on_yank()
    end)
    for i = 1, 9 do
      map(tostring(i), function()
        callbacks.on_jump(i)
      end)
    end
  end

  if mode == "error" or mode == "review" then
    map("r", function()
      callbacks.on_retry()
    end)
  end
end

---@param info { prompt_id: string, adapter_name: string }
---@param callbacks laler.ReviewCallbacks
function M:open_loading(info, callbacks)
  define_highlights()
  state.callbacks = callbacks
  local buf = ensure_buf()
  open_win(buf)
  set_lines(buf, {
    string.format("  %s  ·  %s", info.prompt_id, info.adapter_name),
    "",
    "  Thinking…",
    "",
    "  <Esc> cancel   q close",
  })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerHeader", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerMeta", 2, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerHint", 4, 0, -1)
  map_keys(buf, callbacks, "loading")
end

---@param review laler.ReviewState
---@param callbacks laler.ReviewCallbacks
function M:show_review(review, callbacks)
  define_highlights()
  state.callbacks = callbacks
  local buf = ensure_buf()
  open_win(buf)

  local v = review.variants[review.index]
  local header = string.format(
    "  %s  %d/%d  ·  %s  ·  %s",
    review.prompt_id,
    review.index,
    #review.variants,
    v and v.label or "?",
    review.adapter_name
  )

  local out = { header, "" }
  local diff_start = #out + 1 -- 1-indexed line where diff lines begin

  for _, dl in ipairs(review.diff_doc.lines) do
    out[#out + 1] = dl.text
  end

  out[#out + 1] = ""
  out[#out + 1] = "  Notes"
  local notes_header = #out
  if v and v.notes and #v.notes > 0 then
    for _, n in ipairs(v.notes) do
      out[#out + 1] = "  • " .. n
    end
  else
    out[#out + 1] = "  (none)"
  end

  out[#out + 1] = ""
  out[#out + 1] = "  <CR> apply  Tab/n next  S-Tab/p prev  1-9 jump  y yank  r retry  q close"
  local hint_line = #out

  set_lines(buf, out)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerHeader", 0, 0, -1)

  for i, dl in ipairs(review.diff_doc.lines) do
    local lnum = (diff_start - 1) + (i - 1)
    if dl.kind == "delete" then
      vim.api.nvim_buf_add_highlight(buf, NS, "LalerDiffDeleteLine", lnum, 0, -1)
    elseif dl.kind == "add" then
      vim.api.nvim_buf_add_highlight(buf, NS, "LalerDiffAddLine", lnum, 0, -1)
    elseif dl.kind == "meta" then
      vim.api.nvim_buf_add_highlight(buf, NS, "LalerMeta", lnum, 0, -1)
    end
  end

  for _, sp in ipairs(review.diff_doc.word_spans) do
    local lnum = (diff_start - 1) + (sp.line - 1)
    local group = sp.kind == "delete" and "LalerDiffDeleteWord" or "LalerDiffAddWord"
    vim.api.nvim_buf_add_highlight(buf, NS, group, lnum, sp.col_start, sp.col_end)
  end

  vim.api.nvim_buf_add_highlight(buf, NS, "LalerNotes", notes_header - 1, 0, -1)
  for i = notes_header, hint_line - 2 do
    vim.api.nvim_buf_add_highlight(buf, NS, "LalerNotes", i, 0, -1)
  end
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerHint", hint_line - 1, 0, -1)

  -- Wrap callbacks so on_apply/on_yank get current variant from review via session
  map_keys(buf, callbacks, "review")
end

---@param err string
---@param raw? string
---@param callbacks laler.ReviewCallbacks
function M:show_error(err, raw, callbacks)
  define_highlights()
  state.callbacks = callbacks
  local buf = ensure_buf()
  open_win(buf)

  local out = {
    "  Error",
    "",
    "  " .. err,
    "",
  }
  if raw and raw ~= "" then
    out[#out + 1] = "  --- raw output ---"
    for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
      out[#out + 1] = "  " .. line
    end
    out[#out + 1] = ""
  end
  out[#out + 1] = "  r retry   q/<Esc> close"

  set_lines(buf, out)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerHeader", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, NS, "LalerHint", #out - 1, 0, -1)
  map_keys(buf, callbacks, "error")
end

function M:close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.callbacks = nil
end

return M
