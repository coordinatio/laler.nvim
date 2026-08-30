-- Minimal test runner for laler.nvim port modules.
-- Usage: nvim --headless -u NONE -c "luafile tests/run.lua" -c "qa!"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

local failed = 0
local passed = 0

local function assert_eq(a, b, msg)
  if a ~= b then
    failed = failed + 1
    print("FAIL: " .. (msg or "") .. " expected " .. vim.inspect(b) .. " got " .. vim.inspect(a))
  else
    passed = passed + 1
  end
end

local function assert_true(cond, msg)
  if not cond then
    failed = failed + 1
    print("FAIL: " .. (msg or "assertion failed"))
  else
    passed = passed + 1
  end
end

-- parse/json
do
  local parser = require("laler.parse.json")
  local ok, variants = parser:parse([[
Here you go:
```json
{"variants":[{"label":"a","text":"Hello world","notes":["capital H"]}]}
```
]])
  assert_true(ok, "fenced json parses")
  assert_eq(#variants, 1, "one variant")
  assert_eq(variants[1].label, "a", "label")
  assert_eq(variants[1].text, "Hello world", "text")
  assert_eq(variants[1].notes[1], "capital H", "notes")

  local ok2, variants2 = parser:parse('noise {"variants":[{"text":"x","notes":"single"}]} trailing')
  assert_true(ok2, "raw json with noise")
  assert_eq(variants2[1].notes[1], "single", "string notes normalized")

  local ok3, err = parser:parse("no json here")
  assert_true(not ok3, "rejects non-json")
  assert_true(type(err) == "string", "error message")
end

-- prompt/composer
do
  local composer = require("laler.prompt.composer")
  local out = composer:compose({
    id = "t",
    label = "T",
    template = "Lang={{language}} FT={{filetype}} N={{n_variants}}\n{{text}}",
  }, {
    text = "hello",
    language = "en",
    filetype = "markdown",
    n_variants = 3,
  })
  assert_true(out:find("Lang=en", 1, true) ~= nil, "language filled")
  assert_true(out:find("FT=markdown", 1, true) ~= nil, "filetype filled")
  assert_true(out:find("N=3", 1, true) ~= nil, "n_variants filled")
  assert_true(out:find("<<<LALER_TEXT>>>", 1, true) ~= nil, "delimiter open")
  assert_true(out:find("<<<END_LALER_TEXT>>>", 1, true) ~= nil, "delimiter close")
  assert_true(out:find("\nhello\n", 1, true) ~= nil, "text inside delimiters")
  assert_true(out:find('"variants"', 1, true) ~= nil, "JSON schema present")
  local schema_pos = out:find('"variants"', 1, true)
  local text_pos = out:find("<<<LALER_TEXT>>>", 1, true)
  assert_true(schema_pos < text_pos, "instructions before passage")
end

-- parse scrub leakage
do
  local parser = require("laler.parse.json")
  local leaked = [[{
  "variants": [{
    "label": "native",
    "text": "Please ingest the path and show how it impacts the wiki.\nOUTPUT FORMAT (required):\nReply with ONLY a JSON object",
    "notes": ["article"]
  }]
}]]
  local ok, variants = parser:parse(leaked)
  assert_true(ok, "parses leaked text")
  assert_eq(
    variants[1].text,
    "Please ingest the path and show how it impacts the wiki.",
    "scrubs OUTPUT FORMAT leakage"
  )
end

-- prompt/catalog
do
  local catalog = require("laler.prompt.catalog").new({
    default_prompt = "correct",
    remember_last_prompt = true,
  })
  assert_eq(catalog:default_id(), "correct", "default id")
  catalog:remember("formal")
  assert_eq(catalog:default_id(), "formal", "remembers last")
  assert_true(catalog:get("concise") ~= nil, "get concise")
end

-- diff
do
  local diff = require("laler.diff.vim_diff")
  local doc = diff:diff("I am write a prompt", "I am writing a prompt")
  assert_true(#doc.lines > 0, "diff has lines")
  local kinds = {}
  for _, l in ipairs(doc.lines) do
    kinds[l.kind] = true
  end
  assert_true(kinds.delete or kinds.add or kinds.context, "has diff kinds")

  local same = diff:diff("same", "same")
  assert_true(same.lines[1].kind == "meta" or same.lines[1].kind == "context", "identical text")
end

-- apply (real buffer)
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz", "second" })
  local apply = require("laler.apply")
  local range = {
    bufnr = buf,
    mode = "char",
    start_row = 0,
    start_col = 4,
    end_row = 0,
    end_col = 7,
    text = "bar",
  }
  local ok, err = apply:apply(range, "qux")
  assert_true(ok, "apply ok " .. tostring(err))
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  assert_eq(line, "foo qux baz", "char apply")

  local range2 = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 1,
    end_col = 0,
    text = "a\nb",
  }
  ok = apply:apply(range2, "only")
  assert_true(ok, "line apply")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(#lines, 1, "replaced both lines")
  assert_eq(lines[1], "only", "line content")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- llm registry resolve
do
  local llm = require("laler.llm")
  local pi = llm.resolve("pi")
  assert_eq(pi.name, "pi", "pi name")
  local spec = pi:request("hello")
  assert_eq(spec.cmd, "pi", "pi cmd")
  assert_true(vim.tbl_contains(spec.args, "--no-tools"), "no-tools")
  assert_eq(spec.stdin, "hello", "stdin")

  local custom = llm.resolve({
    name = "echo",
    cmd = "echo",
    args = { "-n" },
  })
  assert_eq(custom.name, "echo", "generic name")
  local cspec = custom:request("x")
  assert_eq(cspec.cmd, "echo", "generic cmd")
end

-- config
do
  local config = require("laler.config")
  local cfg = config.merge({ language = "ru", n_variants = 2 })
  assert_eq(cfg.language, "ru", "merge language")
  assert_eq(cfg.adapter, "pi", "default adapter kept")
  local ok, err = config.validate({ n_variants = 0 })
  assert_true(not ok, "rejects bad n_variants")
  assert_true(type(err) == "string", "validate err")
end

print(string.format("laler tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
