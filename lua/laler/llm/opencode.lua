---@implements laler.LlmClient
local M = {
  name = "opencode",
}

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = "opencode",
    args = { "run", "--format", "default", composed },
    stdin = composed,
    env = {
      OPENCODE_PERMISSION = vim.json.encode({
        edit = "deny",
        write = "deny",
        bash = "deny",
      }),
    },
  }
end

return M
