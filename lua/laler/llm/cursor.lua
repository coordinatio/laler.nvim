local argv = require("laler.llm.argv")

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

---@param opts? { model?: string, thinking?: boolean }
---@return laler.LlmClient
function M.new(opts)
  opts = opts or {}
  local model = opts.model
  ---@type laler.LlmClient
  local client = { name = "cursor" }
  function client:request(composed)
    if type(composed) == "string" and #composed > 24000 then
      error("laler: prompt too large for cursor adapter (use a smaller range)")
    end
    -- `agent -p` takes the prompt as a positional argument; stdin is ignored.
    -- `--model` must come before that positional prompt.
    -- Cursor has no `--thinking` flag; disable thinking by choosing a non-thinking model.
    local args = argv.with_model({
      "-p",
      "--mode",
      "ask",
      "--output-format",
      "text",
      "--trust",
      "--sandbox",
      "enabled",
    }, model)
    args[#args + 1] = composed
    return {
      cmd = resolve_bin(),
      args = args,
      stdin = "",
    }
  end
  return client
end

local default = M.new()

function M:request(composed)
  return default:request(composed)
end

return M
