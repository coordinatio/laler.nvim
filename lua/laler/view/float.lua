---@implements laler.ReviewView
local M = {}

local NS = vim.api.nvim_create_namespace("laler_diff")
local AUGROUP = vim.api.nvim_create_augroup("laler_float", { clear = true })

local REVIEW_KEYS = {
  "q",
  "<Esc>",
  "<CR>",
  "Tab",
  "<Tab>",
  "<S-Tab>",
  "n",
  "]",
  "p",
  "[",
  "y",
  "r",
}
for i = 1, 9 do
  REVIEW_KEYS[#REVIEW_KEYS + 1] = tostring(i)
end

local state = {
  win = nil ---@type integer?
  ,
  buf = nil ---@type integer?
  ,
  callbacks = nil ---@type laler.ReviewCallbacks?
  ,
  closing = false,
}

local HL_GROUP = vim.api.nvim_create_augroup("laler_colors", { clear = true })

local function define_highlights()
  local dark = vim.o.background ~= "light"
  vim.api.nvim_set_hl(0, "LalerDiffDeleteLine", { link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "LalerDiffAddLine", { link = "DiffAdd" })
  if dark then
    vim.api.nvim_set_hl(0, "LalerDiffDeleteWord", { bg = "#901011" })
    vim.api.nvim_set_hl(0, "LalerDiffAddWord", { bg = "#006000" })
    vim.api.nvim_set_hl(0, "LalerHeader", { fg = "#24acd4", bold = true })
    vim.api.nvim_set_hl(0, "LalerMeta", { fg = "#888888", italic = true })
    vim.api.nvim_set_hl(0, "LalerNotes", { fg = "#c0c0a0" })
    vim.api.nvim_set_hl(0, "LalerHint", { fg = "#666666" })
  else
    vim.api.nvim_set_hl(0, "LalerDiffDeleteWord", { bg = "#ffc1bf" })
    vim.api.nvim_set_hl(0, "LalerDiffAddWord", { bg = "#9df0a2" })
    vim.api.nvim_set_hl(0, "LalerHeader", { fg = "#0088aa", bold = true })
    vim.api.nvim_set_hl(0, "LalerMeta", { fg = "#666666", italic = true })
    vim.api.nvim_set_hl(0, "LalerNotes", { fg = "#555533" })
    vim.api.nvim_set_hl(0, "LalerHint", { fg = "#888888" })
  end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = HL_GROUP,
  callback = define_highlights,
})
vim.api.nvim_create_autocmd("OptionSet", {
  group = HL_GROUP,
  pattern = "background",
  callback = define_highlights,
})

local function notify_closed()
  if state.closing then
    return
  end
  local cb = state.callbacks
  state.callbacks = nil
  if cb and cb.on_close then
    cb.on_close()
  end
end

---@return table
local function win_config()
  local width = math.max(1, math.min(100, math.floor(vim.o.columns * 0.8)))
  local height = math.max(1, math.min(28, math.floor(vim.o.lines * 0.7)))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  return {
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
  }
end

local function attach_lifecycle(buf, win)
  vim.api.nvim_clear_autocmds({ group = AUGROUP })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    callback = function(ev)
      if tostring(win) == ev.match then
        notify_closed()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = AUGROUP,
    buffer = buf,
    callback = function()
      notify_closed()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = AUGROUP,
    callback = function()
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_set_config, state.win, win_config())
      end
    end,
  })
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
  local win = vim.api.nvim_open_win(buf, true, win_config())
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = true
  state.win = win
  attach_lifecycle(buf, win)
  return win
end

---@param s string
---@return string
local function flatten_oneline(s)
  return tostring(s):gsub("[\r\n]+", " ")
end

--- Split a note into a bullet plus continuation lines (no embedded newlines).
---@param note string
---@return string[]
local function note_lines(note)
  local text = tostring(note):gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts = vim.split(text, "\n", { plain = true })
  local out = {}
  for i, part in ipairs(parts) do
    if i == 1 then
      out[#out + 1] = "  • " .. part
    else
      out[#out + 1] = "    " .. part
    end
  end
  if #out == 0 then
    out[1] = "  • "
  end
  return out
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  for i, l in ipairs(lines) do
    if type(l) ~= "string" then
      lines[i] = flatten_oneline(l)
    elseif l:find("[\r\n]") then
      lines[i] = flatten_oneline(l)
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param buf integer
local function clear_maps(buf)
  for _, lhs in ipairs(REVIEW_KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
end

---@param buf integer
---@param callbacks laler.ReviewCallbacks
---@param mode "loading"|"review"|"error"
local function map_keys(buf, callbacks, mode)
  clear_maps(buf)
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
    map("<Tab>", function()
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
    flatten_oneline(v and v.label or "?"),
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
      for _, line in ipairs(note_lines(n)) do
        out[#out + 1] = line
      end
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

local MAX_RAW_LINES = 200
local MAX_RAW_BYTES = 50 * 1024

---@param raw string
---@return string[] lines
---@return boolean truncated
local function cap_raw_lines(raw)
  local truncated = false
  if #raw > MAX_RAW_BYTES then
    raw = raw:sub(1, MAX_RAW_BYTES)
    truncated = true
  end
  local raw_lines = vim.split(raw, "\n", { plain = true })
  if #raw_lines > MAX_RAW_LINES then
    local kept = {}
    for i = 1, MAX_RAW_LINES do
      kept[i] = raw_lines[i]
    end
    raw_lines = kept
    truncated = true
  end
  return raw_lines, truncated
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
    "  " .. flatten_oneline(err),
    "",
  }
  if raw and raw ~= "" then
    out[#out + 1] = "  --- raw output ---"
    local raw_lines, truncated = cap_raw_lines(raw)
    for _, line in ipairs(raw_lines) do
      out[#out + 1] = "  " .. line
    end
    if truncated then
      out[#out + 1] = "  ... [truncated]"
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
  if state.closing then
    return
  end
  state.closing = true
  state.callbacks = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.closing = false
end

return M
