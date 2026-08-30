---@implements laler.LlmClient
local M = {
  name = "opencode",
}

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = "opencode",
    args = { "run", "--format", "default" },
    stdin = composed,
    env = {
      OPENCODE_PERMISSION = vim.json.encode({
        ["*"] = "deny",
      }),
    },
  }
end

return M
