---@implements laler.RangeApplier
local M = {}

local NS = vim.api.nvim_create_namespace("laler_range")

---@param text string
---@return string
local function strip_trailing_newline(text)
  if text:sub(-1) == "\n" then
    return text:sub(1, -2)
  end
  return text
end

---@param range laler.Range
local function delete_marks(range)
  if not range or not vim.api.nvim_buf_is_valid(range.bufnr) then
    return
  end
  if range.start_mark then
    pcall(vim.api.nvim_buf_del_extmark, range.bufnr, NS, range.start_mark)
    range.start_mark = nil
  end
  if range.end_mark then
    pcall(vim.api.nvim_buf_del_extmark, range.bufnr, NS, range.end_mark)
    range.end_mark = nil
  end
end

---@param range laler.Range
---@param text string
---@return boolean, string?
function M:apply(range, text)
  if not range or not vim.api.nvim_buf_is_valid(range.bufnr) then
    return false, "invalid buffer"
  end

  local start_row, start_col = range.start_row, range.start_col
  local end_row, end_col = range.end_row, range.end_col

  if range.start_mark ~= nil or range.end_mark ~= nil then
    if range.start_mark == nil or range.end_mark == nil then
      return false, "range is stale (extmarks gone)"
    end
    local s = vim.api.nvim_buf_get_extmark_by_id(range.bufnr, NS, range.start_mark, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(range.bufnr, NS, range.end_mark, {})
    if not s or #s < 2 or not e or #e < 2 then
      return false, "range is stale (extmarks gone)"
    end
    start_row, start_col = s[1], s[2]
    end_row, end_col = e[1], e[2]
  end

  if start_row > end_row or (range.mode ~= "line" and start_row == end_row and start_col > end_col) then
    return false, "range inverted after buffer edits"
  end

  local current
  local ok_read, read_err = pcall(function()
    if range.mode == "line" then
      current = table.concat(vim.api.nvim_buf_get_lines(range.bufnr, start_row, end_row + 1, false), "\n")
    else
      current = table.concat(vim.api.nvim_buf_get_text(range.bufnr, start_row, start_col, end_row, end_col, {}), "\n")
    end
  end)
  if not ok_read then
    return false, tostring(read_err)
  end
  if range.text ~= nil and current ~= range.text then
    return false, "buffer text changed; apply aborted"
  end

  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = vim.split(strip_trailing_newline(text), "\n", { plain = true })

  local ok, err = pcall(function()
    if range.mode == "line" then
      vim.api.nvim_buf_set_lines(range.bufnr, start_row, end_row + 1, false, lines)
    else
      vim.api.nvim_buf_set_text(range.bufnr, start_row, start_col, end_row, end_col, lines)
    end
  end)

  if not ok then
    return false, tostring(err)
  end
  delete_marks(range)
  return true
end

return M
