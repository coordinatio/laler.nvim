local argv = require("laler.llm.argv")

---@implements laler.LlmClient
local M = {
  name = "opencode",
}

---@param opts? { model?: string, thinking?: boolean }
---@return laler.LlmClient
function M.new(opts)
  opts = opts or {}
  local model = opts.model
  local thinking = opts.thinking
  ---@type laler.LlmClient
  local client = { name = "opencode" }
  function client:request(composed)
    -- `--permissions` is not a `run` flag (it prints help). Deny tools via env.
    -- `run --thinking` only shows thinking blocks; `--variant none` disables reasoning.
    local args = { "run", "--format", "default", "--pure" }
    argv.with_thinking(args, thinking, "variant-none")
    argv.with_model(args, model)
    return {
      cmd = "opencode",
      args = args,
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
  return client
end

local default = M.new()

function M:request(composed)
  return default:request(composed)
end

return M
