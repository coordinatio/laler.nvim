---@implements laler.RangeCapture
local M = {}

local NS = vim.api.nvim_create_namespace("laler_range")

--- Inclusive 1-indexed byte of a character → 0-indexed exclusive end.
--- `vim.str_utf_end` returns the distance to the last byte of that character.
---@param line string
---@param col integer 1-indexed first byte of the last included character
---@return integer
function M.utf_exclusive_end(line, col)
  local len = #line
  if len == 0 or col < 1 then
    return 0
  end
  if col > len then
    return len
  end
  return col + vim.str_utf_end(line, col)
end

---@param bufnr integer
---@param row integer 0-indexed
---@return string
local function line_at(bufnr, row)
  if row < 0 then
    return ""
  end
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

---@param pos1 table getpos()
---@param pos2 table getpos()
---@return boolean
local function pos_after(pos1, pos2)
  return pos1[2] > pos2[2] or (pos1[2] == pos2[2] and pos1[3] > pos2[3])
end

--- 0-indexed start column: first byte of the character, or after it if excluded.
---@param line string
---@param col1 integer 1-indexed byte
---@param excluded boolean
---@return integer
local function start_col_from_pos(line, col1, excluded)
  local len = #line
  if col1 < 1 then
    return 0
  end
  if excluded then
    if col1 > len then
      return len
    end
    return col1 + vim.str_utf_end(line, col1)
  end
  local col = col1 - 1
  if col < 0 then
    return 0
  end
  if col > len then
    return len
  end
  return col
end

--- 0-indexed exclusive end column from a 1-indexed getpos column.
---@param line string
---@param col1 integer 1-indexed byte
---@param excluded boolean if true, this character is not included (selection=exclusive)
---@return integer
local function end_col_from_pos(line, col1, excluded)
  local len = #line
  if excluded then
    if col1 < 1 then
      return 0
    end
    local col = col1 - 1
    if col > len then
      return len
    end
    if col < 0 then
      return 0
    end
    return col
  end
  return M.utf_exclusive_end(line, col1)
end

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

  local range = {
    bufnr = bufnr,
    mode = mode,
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    text = text,
  }

  local ok_s, start_mark = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, start_row, start_col, {
    right_gravity = false,
  })
  local ok_e, end_mark = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, end_row, end_col, {
    right_gravity = true,
  })
  if ok_s and ok_e then
    range.start_mark = start_mark
    range.end_mark = end_mark
  end

  return range
end

--- Capture while still in visual mode (uses 'v' and '.').
---@return laler.Range?, string?
function M:from_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local visual_mode

  local start_pos, end_pos
  local in_visual = mode:find("[vV\22]") ~= nil
  if in_visual then
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

  local exclusive = vim.o.selection == "exclusive"
  -- Anchor is inclusive; the cursor ('.') is excluded when selection=exclusive.
  local start_excl, end_excl = false, exclusive
  if pos_after(start_pos, end_pos) then
    start_pos, end_pos = end_pos, start_pos
    start_excl, end_excl = end_excl, start_excl
  end

  local start_row = start_pos[2] - 1
  local end_row = end_pos[2] - 1

  if visual_mode == "V" then
    return make_range(bufnr, "line", start_row, 0, end_row, 0)
  end

  local start_line = line_at(bufnr, start_row)
  local end_line = line_at(bufnr, end_row)
  local start_col = start_col_from_pos(start_line, start_pos[3], start_excl)
  local end_col = end_col_from_pos(end_line, end_pos[3], end_excl)

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
  if pos_after(start_pos, end_pos) then
    start_pos, end_pos = end_pos, start_pos
  end

  local start_row = start_pos[2] - 1
  local end_row = end_pos[2] - 1

  if mode == "line" then
    return make_range(bufnr, "line", start_row, 0, end_row, 0)
  end

  -- Operator marks are inclusive of the last character regardless of 'selection'.
  local start_line = line_at(bufnr, start_row)
  local end_line = line_at(bufnr, end_row)
  local start_col = start_col_from_pos(start_line, start_pos[3], false)
  local end_col = end_col_from_pos(end_line, end_pos[3], false)

  return make_range(bufnr, "char", start_row, start_col, end_row, end_col)
end

---@param line1 integer 1-indexed
---@param line2 integer 1-indexed
---@return laler.Range?, string?
function M:from_command_range(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local n = vim.api.nvim_buf_line_count(bufnr)
  if n < 1 then
    return nil, "invalid range"
  end
  line1 = math.min(line1, n)
  line2 = math.min(line2, n)
  if line1 < 1 or line2 < line1 then
    return nil, "invalid range"
  end
  return make_range(bufnr, "line", line1 - 1, 0, line2 - 1, 0)
end

return M
