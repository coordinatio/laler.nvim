---@implements laler.RangeApplier
local M = {}

---@param range laler.Range
---@param text string
---@return boolean, string?
function M:apply(range, text)
  if not range or not vim.api.nvim_buf_is_valid(range.bufnr) then
    return false, "invalid buffer"
  end

  local lines = vim.split(text, "\n", { plain = true })

  local ok, err = pcall(function()
    if range.mode == "line" then
      vim.api.nvim_buf_set_lines(range.bufnr, range.start_row, range.end_row + 1, false, lines)
    else
      vim.api.nvim_buf_set_text(
        range.bufnr,
        range.start_row,
        range.start_col,
        range.end_row,
        range.end_col,
        lines
      )
    end
  end)

  if not ok then
    return false, tostring(err)
  end
  return true
end

return M
