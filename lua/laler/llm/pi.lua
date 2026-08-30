---@implements laler.LlmClient
local M = {
  name = "pi",
}

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = "pi",
    args = { "-p", "--no-tools", "--no-session", "--no-context-files", "--no-extensions", "--no-skills" },
    stdin = composed,
  }
end

return M
