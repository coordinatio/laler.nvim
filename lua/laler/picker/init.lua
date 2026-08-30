local M = {}

---@type table<string, laler.Picker|fun(): laler.Picker>
local registry = {}

---@param name string
---@param picker laler.Picker|fun(): laler.Picker
function M.register(name, picker)
  registry[name] = picker
end

---@param name string
---@return laler.Picker?
function M.get(name)
  local p = registry[name]
  if type(p) == "function" then
    return p()
  end
  return p
end

---@return laler.Picker
function M.autodetect()
  if pcall(require, "fzf-lua") then
    return M.get("fzf-lua")
  end
  if pcall(require, "telescope") then
    return M.get("telescope")
  end
  return M.get("vim_ui")
end

--- Resolve picker: nil = auto, string name, or table implementing pick.
---@param picker string|laler.Picker|nil
---@return laler.Picker
function M.resolve(picker)
  if picker == nil then
    return M.autodetect()
  end
  if type(picker) == "table" and picker.pick then
    return picker
  end
  if type(picker) == "string" then
    local p = M.get(picker)
    if not p then
      error("laler: unknown picker '" .. picker .. "'")
    end
    return p
  end
  error("laler: picker must be nil, string, or table with pick()")
end

M.register("vim_ui", function()
  return require("laler.picker.vim_ui")
end)
M.register("telescope", function()
  return require("laler.picker.telescope")
end)
M.register("fzf-lua", function()
  return require("laler.picker.fzf_lua")
end)

return M
