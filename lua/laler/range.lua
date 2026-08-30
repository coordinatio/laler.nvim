---@implements laler.RangeCapture
local M = {}

---@param bufnr integer
---@param mode "char"|"line"
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return laler.Range
local function make_range(bufnr, mode, start_row, start_col, end_row, end_col)
  local text
  if mode == "line" then
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    text = table.concat(lines, "\n")
  else
    local lines = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
    text = table.concat(lines, "\n")
  end
  return {
    bufnr = bufnr,
    mode = mode,
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    text = text,
  }
end

--- Capture while still in visual mode (uses 'v' and '.').
---@return laler.Range?, string?
function M:from_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local visual_mode

  local start_pos, end_pos
  if mode:find("[vV\22]") then
    visual_mode = mode
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getpos(".")
  else
    visual_mode = vim.fn.visualmode()
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
  end

  if visual_mode == "\22" then
    return nil, "blockwise visual is not supported"
  end

  local start_row = start_pos[2] - 1
  local start_col = start_pos[3] - 1
  local end_row = end_pos[2] - 1
  local end_col = end_pos[3] -- 1-indexed inclusive → 0-indexed exclusive boundary

  if start_row > end_row or (start_row == end_row and start_col > end_col - 1) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col - 1, start_col + 1
  end

  if visual_mode == "V" then
    return make_range(bufnr, "line", start_row, 0, end_row, 0)
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  if end_col > #line then
    end_col = #line
  end

  return make_range(bufnr, "char", start_row, start_col, end_row, end_col)
end

---@param mode string "char"|"line"|"block" from operatorfunc
---@return laler.Range?, string?
function M:from_operator(mode)
  local bufnr = vim.api.nvim_get_current_buf()
  if mode == "block" then
    return nil, "blockwise operator is not supported"
  end

  local start_pos = vim.fn.getpos("'[")
  local end_pos = vim.fn.getpos("']")
  local start_row = start_pos[2] - 1
  local start_col = start_pos[3] - 1
  local end_row = end_pos[2] - 1
  local end_col = end_pos[3] -- 1-indexed inclusive -> use as exclusive 0-indexed boundary

  if mode == "line" then
    return make_range(bufnr, "line", start_row, 0, end_row, 0)
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  -- operator '] is inclusive; exclusive end = end_pos[3] when interpreted as above
  -- For char operator, '] col is inclusive last char. Exclusive = inclusive_0based + 1 = end_pos[3]
  if end_col > #line then
    end_col = #line
  end
  -- Actually for operatorfunc char mode, end is inclusive. getpos(']')[3] is 1-indexed inclusive.
  -- Exclusive 0-indexed end = that value (same as visual).
  -- Wait - if inclusive last byte index is C-1, exclusive is C = getpos col. Yes.

  return make_range(bufnr, "char", start_row, start_col, end_row, end_col)
end

---@param line1 integer 1-indexed
---@param line2 integer 1-indexed
---@return laler.Range?, string?
function M:from_command_range(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  if line1 < 1 or line2 < line1 then
    return nil, "invalid range"
  end
  return make_range(bufnr, "line", line1 - 1, 0, line2 - 1, 0)
end

return M
