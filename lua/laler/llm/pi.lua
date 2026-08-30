---@implements laler.LlmClient
local M = {
  name = "pi",
}

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = "pi",
    args = { "-p", "--no-tools", "--no-session" },
    stdin = composed,
  }
end

return M
