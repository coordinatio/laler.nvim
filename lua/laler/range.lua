---@implements laler.RangeCapture
local M = {}

local NS = vim.api.nvim_create_namespace("laler_range")

---@param ch string
---@return boolean extend
---@return boolean is_zwj
local function is_extend_char(ch)
  local cp = vim.fn.char2nr(ch)
  if cp == 0x200D then
    return true, true
  end
  if cp == 0x200C then
    return true, false
  end
  -- Variation selectors, skin-tone modifiers, combining keycap.
  if (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF) then
    return true, false
  end
  if cp >= 0x1F3FB and cp <= 0x1F3FF then
    return true, false
  end
  if cp == 0x20E3 then
    return true, false
  end
  local ok1, skip = pcall(vim.fn.strchars, "a" .. ch, true)
  local ok2, noskip = pcall(vim.fn.strchars, "a" .. ch, false)
  if ok1 and ok2 and skip == 1 and noskip > 1 then
    return true, false
  end
  return false, false
end

--- After the exclusive end of a codepoint, absorb combining/extend chars
--- and ZWJ-joined emoji (👨‍👩‍👧).
---@param line string
---@param exclusive integer 0-indexed exclusive byte end
---@return integer
local function extend_composing(line, exclusive)
  local i = exclusive + 1
  while i <= #line do
    local last = i + vim.str_utf_end(line, i)
    local ch = line:sub(i, last)
    local extend, is_zwj = is_extend_char(ch)
    if not extend then
      break
    end
    exclusive = last
    i = last + 1
    if is_zwj and i <= #line then
      local nlast = i + vim.str_utf_end(line, i)
      exclusive = nlast
      i = nlast + 1
    end
  end
  return exclusive
end

--- Inclusive 1-indexed byte of a character → 0-indexed exclusive end.
--- Extends through combining marks and ZWJ grapheme clusters (Neovim 0.10+).
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
  local char_i = vim.fn.charidx(line, col - 1)
  if type(char_i) == "number" and char_i >= 0 then
    local next_start = vim.fn.byteidx(line, char_i + 1)
    if type(next_start) == "number" and next_start >= 0 then
      return extend_composing(line, next_start)
    end
    return extend_composing(line, len)
  end
  local exclusive = col + vim.str_utf_end(line, col)
  return extend_composing(line, exclusive)
end

---@param bufnr integer
---@param row integer 0-indexed
---@return string
local function line_at(bufnr, row)
  if row < 0 then
    return ""
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return lines[1] or ""
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
    return M.utf_exclusive_end(line, col1)
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
---@return laler.Range?, string?
local function make_range(bufnr, mode, start_row, start_col, end_row, end_col)
  start_row = math.max(0, start_row)
  end_row = math.max(0, end_row)

  local ok, text = pcall(function()
    if mode == "line" then
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
      return table.concat(lines, "\n")
    end
    local lines = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
    return table.concat(lines, "\n")
  end)
  if not ok then
    return nil, "invalid range"
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
  else
    if ok_s then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, start_mark)
    end
    if ok_e then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, end_mark)
    end
  end

  return range
end

---@param range laler.Range?
function M:delete_marks(range)
  if not range then
    return
  end
  if type(range.bufnr) == "number" and vim.api.nvim_buf_is_valid(range.bufnr) then
    if range.start_mark then
      pcall(vim.api.nvim_buf_del_extmark, range.bufnr, NS, range.start_mark)
    end
    if range.end_mark then
      pcall(vim.api.nvim_buf_del_extmark, range.bufnr, NS, range.end_mark)
    end
  end
  range.start_mark = nil
  range.end_mark = nil
end

--- Re-read buffer text between extmarks into `range` (positions + text).
---@param range laler.Range
---@return boolean
function M:refresh_from_marks(range)
  if not range or range.start_mark == nil or range.end_mark == nil then
    return false
  end
  if not vim.api.nvim_buf_is_valid(range.bufnr) then
    return false
  end
  local s = vim.api.nvim_buf_get_extmark_by_id(range.bufnr, NS, range.start_mark, {})
  local e = vim.api.nvim_buf_get_extmark_by_id(range.bufnr, NS, range.end_mark, {})
  if not s or #s < 2 or not e or #e < 2 then
    return false
  end
  if s[1] > e[1] or (s[1] == e[1] and range.mode ~= "line" and s[2] > e[2]) then
    return false
  end
  range.start_row, range.start_col = s[1], s[2]
  range.end_row, range.end_col = e[1], e[2]
  local ok, text = pcall(function()
    if range.mode == "line" then
      return table.concat(vim.api.nvim_buf_get_lines(range.bufnr, range.start_row, range.end_row + 1, false), "\n")
    end
    return table.concat(
      vim.api.nvim_buf_get_text(range.bufnr, range.start_row, range.start_col, range.end_row, range.end_col, {}),
      "\n"
    )
  end)
  if not ok then
    return false
  end
  range.text = text
  return true
end

--- Capture while still in visual mode (uses 'v' and '.').
---@return laler.Range?, string?
function M:from_visual()
  local ok, range, err = pcall(function()
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

    local exclusive = in_visual and vim.o.selection == "exclusive"
    -- Anchor is inclusive; the cursor ('.') is excluded when selection=exclusive
    -- and we are still in visual mode. After Esc, `'<`/`'>` are inclusive.
    local start_excl, end_excl = false, exclusive
    if pos_after(start_pos, end_pos) then
      start_pos, end_pos = end_pos, start_pos
      start_excl, end_excl = end_excl, start_excl
    end

    local start_row = math.max(0, start_pos[2] - 1)
    local end_row = math.max(0, end_pos[2] - 1)

    if visual_mode == "V" then
      return make_range(bufnr, "line", start_row, 0, end_row, 0)
    end

    local start_line = line_at(bufnr, start_row)
    local end_line = line_at(bufnr, end_row)
    local start_col = start_col_from_pos(start_line, start_pos[3], start_excl)
    local end_col = end_col_from_pos(end_line, end_pos[3], end_excl)

    return make_range(bufnr, "char", start_row, start_col, end_row, end_col)
  end)
  if not ok then
    return nil, tostring(range)
  end
  return range, err
end

---@param mode string "char"|"line"|"block" from operatorfunc
---@return laler.Range?, string?
function M:from_operator(mode)
  local ok, range, err = pcall(function()
    local bufnr = vim.api.nvim_get_current_buf()
    if mode == "block" then
      return nil, "blockwise operator is not supported"
    end

    local start_pos = vim.fn.getpos("'[")
    local end_pos = vim.fn.getpos("']")
    if pos_after(start_pos, end_pos) then
      start_pos, end_pos = end_pos, start_pos
    end

    local start_row = math.max(0, start_pos[2] - 1)
    local end_row = math.max(0, end_pos[2] - 1)

    if mode == "line" then
      return make_range(bufnr, "line", start_row, 0, end_row, 0)
    end

    -- Operator marks are inclusive of the last character regardless of 'selection'.
    local start_line = line_at(bufnr, start_row)
    local end_line = line_at(bufnr, end_row)
    local start_col = start_col_from_pos(start_line, start_pos[3], false)
    local end_col = end_col_from_pos(end_line, end_pos[3], false)

    return make_range(bufnr, "char", start_row, start_col, end_row, end_col)
  end)
  if not ok then
    return nil, tostring(range)
  end
  return range, err
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
