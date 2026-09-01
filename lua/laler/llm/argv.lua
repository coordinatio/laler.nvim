local M = {}

---@param args string[]
---@param model? string
---@return string[]
function M.with_model(args, model)
  if type(model) == "string" and model ~= "" then
    args[#args + 1] = "--model"
    args[#args + 1] = model
  end
  return args
end

--- When `thinking` is `false`, disable model reasoning.
--- `"off"` → `--thinking off` (pi / generic). `"variant-none"` → `--variant none` (opencode).
---@param args string[]
---@param thinking? boolean
---@param how? "off"|"variant-none"
---@return string[]
function M.with_thinking(args, thinking, how)
  if thinking ~= false then
    return args
  end
  if how == "variant-none" then
    args[#args + 1] = "--variant"
    args[#args + 1] = "none"
    return args
  end
  args[#args + 1] = "--thinking"
  args[#args + 1] = "off"
  return args
end

return M
