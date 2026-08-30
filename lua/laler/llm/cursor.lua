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
  if type(composed) == "string" and #composed > 24000 then
    error("laler: prompt too large for cursor adapter (use a smaller range)")
  end
  -- `agent -p` takes the prompt as a positional argument; stdin is ignored.
  return {
    cmd = resolve_bin(),
    args = { "-p", "--mode", "ask", "--output-format", "text", "--trust", composed },
    stdin = "",
  }
end

return M
