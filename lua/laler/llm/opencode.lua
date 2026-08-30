---@implements laler.LlmClient
local M = {
  name = "opencode",
}

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = "opencode",
    -- `--permissions` is not a `run` flag (it prints help). Deny tools via env.
    args = { "run", "--format", "default", "--pure" },
    stdin = composed,
    env = {
      OPENCODE_PERMISSION = vim.json.encode({
        ["*"] = "deny",
        edit = "deny",
        write = "deny",
        bash = "deny",
        read = "deny",
        webfetch = "deny",
        glob = "deny",
        grep = "deny",
        task = "deny",
      }),
    },
  }
end

return M
