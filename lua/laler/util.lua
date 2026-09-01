local M = {}

--- List-like table? Prefer Neovim's checker (`vim.islist` on 0.11+, `vim.tbl_islist` on 0.10).
---@param t any
---@return boolean
function M.is_list(t)
  if type(t) ~= "table" then
    return false
  end
  local fn = vim.islist or vim.tbl_islist
  if fn then
    return fn(t)
  end
  -- Consecutive integer keys 1..n, no holes, no non-integer keys. `{}` is a list.
  local max = 0
  local count = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    count = count + 1
    if k > max then
      max = k
    end
  end
  return count == max
end

return M
