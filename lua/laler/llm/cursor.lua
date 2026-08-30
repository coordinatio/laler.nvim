---@implements laler.LlmClient
local M = {
  name = "cursor",
}

---@return string
local function resolve_bin()
  if vim.fn.executable("agent") == 1 then
    return "agent"
  end
  if vim.fn.executable("cursor-agent") == 1 then
    return "cursor-agent"
  end
  return "agent"
end

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = resolve_bin(),
    args = { "-p", "--mode", "ask", "--output-format", "text", "--trust" },
    stdin = composed,
  }
end

return M
