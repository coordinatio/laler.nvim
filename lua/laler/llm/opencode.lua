---@implements laler.LlmClient
local M = {
  name = "opencode",
}

---@param composed string
---@return laler.JobSpec
function M:request(composed)
  return {
    cmd = "opencode",
    -- Empty --permissions allowlist: omitted tools are denied. --pure: no plugins.
    args = { "run", "--format", "default", "--pure", "--permissions", "" },
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
