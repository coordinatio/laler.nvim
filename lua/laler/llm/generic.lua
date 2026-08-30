local M = {}

---@param opts { name?: string, cmd: string|string[], args?: string[], env?: table<string,string>, cwd?: string, build?: fun(composed: string): laler.JobSpec }
---@return laler.LlmClient
function M.new(opts)
  if not opts or not (opts.cmd or opts.build) then
    error("laler: generic adapter requires cmd or build")
  end

  local name = opts.name or "custom"

  ---@type laler.LlmClient
  local client = { name = name }

  function client:request(composed)
    if opts.build then
      local spec = opts.build(composed)
      spec.cmd = spec.cmd or name
      return spec
    end

    local cmd = opts.cmd
    local args = vim.list_extend({}, opts.args or {})
    if type(cmd) == "table" then
      if #cmd == 0 then
        error("laler: generic adapter cmd is empty")
      end
      local list = vim.list_slice(cmd, 1, #cmd)
      cmd = table.remove(list, 1)
      args = vim.list_extend(list, args)
    end
    if type(cmd) ~= "string" or cmd == "" then
      error("laler: generic adapter requires a non-empty cmd")
    end

    return {
      cmd = cmd,
      args = args,
      stdin = composed,
      env = opts.env,
      cwd = opts.cwd,
    }
  end

  return client
end

return M
