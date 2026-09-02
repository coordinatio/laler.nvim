---@implements laler.LlmClient
local M = {
  name = "openai",
}

local DEFAULT_BASE_URL = "https://api.openai.com/v1"
local DEFAULT_KEY_ENV = "OPENAI_API_KEY"

-- No `-f`: HTTP 4xx/5xx still exit 0 so error JSON reaches unwrap_stdout.
-- `-q` first so `~/.curlrc` cannot inject `--fail` / `--include`.
-- `-g` / `--globoff` so `[]` / `{}` in URLs are not globbed.
-- `exec` so cancel/timeout kills curl, not a leftover sh.
local CURL_AUTH = 'exec curl -q -sS -g --data-binary @- -H "Content-Type: application/json" -H "Authorization: Bearer $LALER_OPENAI_KEY" --url "$LALER_OPENAI_URL"'
local CURL_NOAUTH = 'exec curl -q -sS -g --data-binary @- -H "Content-Type: application/json" --url "$LALER_OPENAI_URL"'

---@param s any
---@return string?
local function nonempty(s)
  if type(s) ~= "string" then
    return nil
  end
  s = vim.trim(s)
  if s == "" then
    return nil
  end
  return s
end

---@param base? string
---@return string
local function chat_completions_url(base)
  local root = nonempty(base) or DEFAULT_BASE_URL
  local suffix = "/chat/completions"
  local path, extra = root:match("^(.-)([?#].*)$")
  if not path then
    path, extra = root, ""
  end
  path = path:gsub("/+$", "")
  if path:sub(-#suffix) == suffix then
    return path .. extra
  end
  return path .. suffix .. extra
end

---@param base? string
---@return string
local function url_host(base)
  local url = nonempty(base) or DEFAULT_BASE_URL
  -- RFC 3986: scheme is case-insensitive (`HTTPS://`, `Http://`).
  local scheme, rest = url:match("^(%a+)://(.*)$")
  if type(scheme) ~= "string" or not scheme:lower():match("^https?$") then
    rest = ""
  end
  rest = rest or ""
  -- Drop `user:pass@` / `user@` so the host is not parsed as userinfo.
  rest = rest:gsub("^[^@/?#]*@", "", 1)
  local host
  if rest:sub(1, 1) == "[" then
    -- IPv6: `http://[::1]:11434/v1`
    host = rest:match("^(%[[^%]]*%])") or ""
  else
    host = rest:match("^([^/?#:]+)") or ""
    -- Trailing-dot FQDN (`api.openai.com.`) still matches the apex host.
    host = host:gsub("%.+$", "")
  end
  return host:lower()
end

--- Official OpenAI; nil base_url uses this host. Default OPENAI_API_KEY only here.
---@param base? string
---@return boolean
local function official_openai_host(base)
  return url_host(base) == "api.openai.com"
end

--- DashScope/Qwen compatible-mode (`enable_thinking` is only valid here).
--- DNS label `dashscope` or `dashscope-…` (e.g. `dashscope-intl.aliyuncs.com`);
--- not a raw substring (`notdashscope.example`).
---@param base? string
---@return boolean
local function dashscope_host(base)
  local host = url_host(base)
  if host:sub(1, 1) == "[" then
    return false
  end
  for label in host:gmatch("[^.]+") do
    if label == "dashscope" or label:sub(1, 10) == "dashscope-" then
      return true
    end
  end
  return false
end

---@param name string
---@return string?
local function env_value(name)
  local v = vim.env[name]
  if type(v) ~= "string" then
    v = os.getenv(name)
  end
  if type(v) ~= "string" then
    return nil
  end
  v = vim.trim(v)
  if v == "" then
    return nil
  end
  return v
end

---@param path string
---@return string
local function read_key_file(path)
  -- `:p` expands `~`; not expand() (globs, `%`, backticks).
  local expanded = vim.fn.fnamemodify(path, ":p")
  local f, err = io.open(expanded, "r")
  if not f then
    error("laler: cannot read api_key_file '" .. tostring(expanded) .. "': " .. tostring(err), 0)
  end
  local content = f:read("*a") or ""
  f:close()
  local key
  for line in content:gmatch("[^\r\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      key = trimmed
      break
    end
  end
  if not key then
    error("laler: api_key_file '" .. tostring(expanded) .. "' is empty", 0)
  end
  return key
end

---@param opts { api_key_env?: string, api_key_file?: string, base_url?: string }
---@return string?
local function resolve_key(opts)
  -- Explicit api_key_env (non-empty value wins; empty falls back to file),
  -- else api_key_file, else OPENAI_API_KEY on api.openai.com only, else none.
  local env_name = nonempty(opts.api_key_env)
  if env_name then
    local from_env = env_value(env_name)
    if from_env then
      return from_env
    end
    local file = nonempty(opts.api_key_file)
    if file then
      return read_key_file(file)
    end
    return nil
  end
  local file = nonempty(opts.api_key_file)
  if file then
    return read_key_file(file)
  end
  if official_openai_host(opts.base_url) then
    return env_value(DEFAULT_KEY_ENV)
  end
  return nil
end

---@param stdout string
---@return string
function M.unwrap_stdout(stdout)
  local raw = stdout or ""
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    error("laler: openai response is not JSON", 0)
  end
  local api_err = data.error
  if api_err == vim.NIL then
    api_err = nil
  end
  if api_err ~= nil then
    local msg
    if type(api_err) == "table" then
      msg = api_err.message
    elseif type(api_err) == "string" then
      msg = api_err
    end
    error(type(msg) == "string" and msg ~= "" and msg or "openai error", 0)
  end
  local choices = data.choices
  if type(choices) ~= "table" or type(choices[1]) ~= "table" then
    error("laler: openai response missing choices", 0)
  end
  local message = choices[1].message
  if type(message) ~= "table" then
    error("laler: openai response missing message", 0)
  end
  local content = message.content
  if content == vim.NIL then
    content = nil
  end
  if type(content) == "table" then
    local parts = {}
    for _, part in ipairs(content) do
      if type(part) == "string" then
        parts[#parts + 1] = part
      elseif type(part) == "table" and type(part.text) == "string" then
        parts[#parts + 1] = part.text
      end
    end
    if #parts > 0 then
      content = table.concat(parts)
    elseif type(content.text) == "string" then
      -- Single part object `{ type = "text", text = "..." }` (not a list).
      content = content.text
    else
      content = nil
    end
  end
  if type(content) == "string" and content ~= "" then
    return content
  end
  local refusal = message.refusal
  if type(refusal) == "string" and refusal ~= "" then
    error(refusal, 0)
  end
  error("laler: openai response missing content", 0)
end

---@param opts? { model?: string, thinking?: boolean, base_url?: string, api_key_env?: string, api_key_file?: string }
---@return laler.LlmClient
function M.new(opts)
  opts = opts or {}
  local model = nonempty(opts.model)
  if not model then
    error("laler: openai adapter requires model", 0)
  end
  local thinking = opts.thinking
  local base_url = nonempty(opts.base_url)
  local api_key_env = nonempty(opts.api_key_env)
  local api_key_file = nonempty(opts.api_key_file)
  -- Non-streaming; Qwen3 400s unless enable_thinking is explicitly false.
  if thinking == true and dashscope_host(base_url) then
    error("laler: openai adapter cannot enable thinking on DashScope (non-streaming)", 0)
  end
  ---@type laler.LlmClient
  local client = { name = "openai" }
  function client:unwrap_stdout(stdout)
    return M.unwrap_stdout(stdout)
  end
  function client:request(composed)
    if vim.fn.executable("curl") ~= 1 then
      error("laler: curl not found in PATH", 0)
    end
    if vim.fn.executable("sh") ~= 1 then
      error("laler: sh not found in PATH", 0)
    end
    local payload = {
      model = model,
      stream = false,
      messages = {
        { role = "user", content = composed },
      },
    }
    -- DashScope/Qwen compatible-mode only; other hosts 400 on unknown fields.
    -- Omit and false both disable thinking (required for stream:false).
    if dashscope_host(base_url) then
      payload.enable_thinking = false
    end
    local key = resolve_key({
      api_key_env = api_key_env,
      api_key_file = api_key_file,
      base_url = base_url,
    })
    local env = {
      LALER_OPENAI_URL = chat_completions_url(base_url),
    }
    local script = CURL_NOAUTH
    if key then
      env.LALER_OPENAI_KEY = key
      script = CURL_AUTH
    end
    return {
      cmd = "sh",
      args = { "-c", script },
      stdin = vim.json.encode(payload),
      env = env,
    }
  end
  return client
end

return M
