local argv = require("laler.llm.argv")

---@implements laler.LlmClient
local M = {
  name = "pi",
}

---@param opts? { model?: string, thinking?: boolean }
---@return laler.LlmClient
function M.new(opts)
  opts = opts or {}
  local model = opts.model
  local thinking = opts.thinking
  ---@type laler.LlmClient
  local client = { name = "pi" }
  function client:request(composed)
    local args = {
      "-p",
      "--no-tools",
      "--no-session",
      "--no-context-files",
      "--no-skills",
    }
    -- pi cannot resolve provider/model IDs with --no-extensions (catalog lives in extensions).
    if not (type(model) == "string" and model ~= "") then
      args[#args + 1] = "--no-extensions"
    end
    argv.with_thinking(args, thinking)
    argv.with_model(args, model)
    return {
      cmd = "pi",
      args = args,
      stdin = composed,
    }
  end
  return client
end

local default = M.new()

function M:request(composed)
  return default:request(composed)
end

return M
