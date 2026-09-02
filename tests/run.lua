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
  assert_true(out:find("exactly 3 variants when possible", 1, true) ~= nil, "preamble plural variants")
  assert_true(out:find(",\n    ...", 1, true) ~= nil, "n>1 JSON sketch has extra-item ellipsis")
  assert_true(out:find("<<<LALER_TEXT>>>", 1, true) ~= nil, "delimiter open")
  assert_true(out:find("<<<END_LALER_TEXT>>>", 1, true) ~= nil, "delimiter close")
  assert_true(out:find("\nhello\n", 1, true) ~= nil, "text inside delimiters")
  assert_true(out:find('"variants"', 1, true) ~= nil, "JSON schema present")
  local schema_pos = out:find('"variants"', 1, true)
  local text_pos = out:find("<<<LALER_TEXT>>>", 1, true)
  assert_true(schema_pos < text_pos, "instructions before passage")
end

-- parse: unwrap full delimiter wrap; do not crop mid-text tokens
do
  local parser = require("laler.parse.json")
  local kept_token = [[{
  "variants": [{
    "text": "keep <<<END_LALER_TEXT>>> this"
  }]
}]]
  local ok, variants = parser:parse(kept_token)
  assert_true(ok, "parses delimiter substring")
  assert_eq(variants[1].text, "keep <<<END_LALER_TEXT>>> this", "preserves delimiter text")

  local wrapped = [[{
  "variants": [{
    "text": "<<<LALER_TEXT>>>\nsecret\n<<<END_LALER_TEXT>>>"
  }]
}]]
  ok, variants = parser:parse(wrapped)
  assert_true(ok, "parses wrapped default markers")
  assert_eq(variants[1].text, "secret", "unwraps default wrap")

  local wrapped_suf = [[{
  "variants": [{
    "text": "<<<LALER_TEXT_1>>>\ninner\n<<<END_LALER_TEXT_1>>>"
  }]
}]]
  ok, variants = parser:parse(wrapped_suf)
  assert_true(ok, "parses wrapped unique markers")
  assert_eq(variants[1].text, "inner", "unwraps unique wrap")

  local leaked = [[{
  "variants": [{
    "label": "native",
    "text": "Please ingest the path and show how it impacts the wiki.\n<<<LALER_TEXT>>>\nsecret\n<<<END_LALER_TEXT>>>",
    "notes": ["article"]
  }]
}]]
  ok, variants = parser:parse(leaked)
  assert_true(ok, "parses leaked text")
  assert_eq(
    variants[1].text,
    "Please ingest the path and show how it impacts the wiki.\n<<<LALER_TEXT>>>\nsecret\n<<<END_LALER_TEXT>>>",
    "does not crop mid-text delimiters"
  )

  local kept = [[{
  "variants": [{
    "text": "See the section below.\nHard rules: always be kind."
  }]
}]]
  ok, variants = parser:parse(kept)
  assert_true(ok, "parses hard-rules learner text")
  assert_eq(
    variants[1].text,
    "See the section below.\nHard rules: always be kind.",
    "keeps Hard rules in learner text"
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
  local listed = catalog:list()
  local nlist = #listed
  listed[#listed + 1] = { id = "hacked" }
  assert_eq(#catalog:list(), nlist, "list() returns a shallow copy")
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
    text = "foo qux baz\nsecond",
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
  assert_true(vim.tbl_contains(spec.args, "--no-context-files"), "no-context-files")
  assert_true(vim.tbl_contains(spec.args, "--no-extensions"), "no-extensions")
  assert_true(vim.tbl_contains(spec.args, "--no-skills"), "no-skills")
  assert_true(not vim.tbl_contains(spec.args, "--model"), "pi default has no --model")
  assert_true(not vim.tbl_contains(spec.args, "--thinking"), "pi default has no --thinking")
  assert_eq(spec.stdin, "hello", "stdin")

  local named = llm.resolve({ name = "pi" })
  assert_eq(named.name, "pi", "named builtin without cmd")
  local nspec = named:request("hello")
  assert_true(vim.tbl_contains(nspec.args, "--no-skills"), "named builtin keeps pi flags")
  assert_true(not vim.tbl_contains(nspec.args, "--model"), "named builtin default has no --model")

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
  local cfg_model = config.merge({ model = "alibaba-cloud/qwen3.8-flash" })
  assert_eq(cfg_model.model, "alibaba-cloud/qwen3.8-flash", "merge model")
  assert_eq(cfg_model.adapter, "pi", "model merge keeps adapter")
  local cfg_think = config.merge({ thinking = false })
  assert_eq(cfg_think.thinking, false, "merge thinking false")
  local cfg_url = config.merge({ base_url = "http://127.0.0.1:11434/v1" })
  assert_eq(cfg_url.base_url, "http://127.0.0.1:11434/v1", "merge base_url")
  local cfg_key = config.merge({ api_key_env = "MY_KEY", api_key_file = "/tmp/k" })
  assert_eq(cfg_key.api_key_env, "MY_KEY", "merge api_key_env")
  assert_eq(cfg_key.api_key_file, "/tmp/k", "merge api_key_file")
  local user_adapter = { name = "openai", model = "  gpt-4o-mini  " }
  local cfg_copy = config.merge({ adapter = user_adapter })
  assert_true(cfg_copy.adapter ~= user_adapter, "merge copies adapter table")
  assert_eq(user_adapter.model, "  gpt-4o-mini  ", "merge does not mutate caller adapter")
  assert_eq(cfg_copy.adapter.model, "  gpt-4o-mini  ", "merge copy keeps adapter.model")
  local ok, err = config.validate({ n_variants = 0 })
  assert_true(not ok, "rejects bad n_variants")
  assert_true(type(err) == "string", "validate err")
end

-- UTF-8 exclusive end / range capture
do
  local capture = require("laler.range")
  assert_eq(capture.utf_exclusive_end("привет", 1), 2, "cyrillic first char exclusive")
  assert_eq(capture.utf_exclusive_end("привет", 11), 12, "cyrillic last char exclusive")
  assert_eq(capture.utf_exclusive_end("€", 1), 3, "3-byte exclusive")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "привет" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)

  local got = vim.api.nvim_buf_get_text(buf, 0, 0, 0, capture.utf_exclusive_end("привет", 1), {})
  assert_eq(got[1], "п", "get_text first cyrillic")
  got = vim.api.nvim_buf_get_text(buf, 0, 0, 0, capture.utf_exclusive_end("привет", 11), {})
  assert_eq(got[1], "привет", "get_text whole cyrillic word")

  vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 0, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "from_operator first char " .. tostring(err))
  assert_eq(range.text, "п", "operator first cyrillic")
  assert_eq(range.end_col, 2, "operator first char end_col")
  got = vim.api.nvim_buf_get_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, {})
  assert_eq(got[1], "п", "operator get_text first char")

  vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 10, {})
  range, err = capture:from_operator("char")
  assert_true(range ~= nil, "from_operator word " .. tostring(err))
  assert_eq(range.text, "привет", "operator whole word")
  got = vim.api.nvim_buf_get_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, {})
  assert_eq(got[1], "привет", "operator get_text whole word")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a€b" })
  vim.api.nvim_buf_set_mark(buf, "[", 1, 1, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 1, {})
  range, err = capture:from_operator("char")
  assert_true(range ~= nil, "from_operator euro " .. tostring(err))
  assert_eq(range.text, "€", "operator 3-byte char")
  got = vim.api.nvim_buf_get_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, {})
  assert_eq(got[1], "€", "operator get_text 3-byte")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- apply trailing newline (char and line)
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  local apply = require("laler.apply")
  local ok, err = apply:apply({
    bufnr = buf,
    mode = "char",
    start_row = 0,
    start_col = 4,
    end_row = 0,
    end_col = 7,
    text = "bar",
  }, "qux\n")
  assert_true(ok, "char apply trailing nl " .. tostring(err))
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "foo qux baz", "char apply strips one trailing nl")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aaa", "bbb" })
  ok, err = apply:apply({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "aaa",
  }, "zzz\n")
  assert_true(ok, "line apply trailing nl " .. tostring(err))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(#lines, 2, "line apply keeps two lines")
  assert_eq(lines[1], "zzz", "line apply first")
  assert_eq(lines[2], "bbb", "line apply second")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- apply follows extmarks after insert above
do
  local capture = require("laler.range")
  local apply = require("laler.apply")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz", "second" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture bar " .. tostring(err))
  assert_eq(range.text, "bar", "captured bar")
  assert_true(range.start_mark ~= nil, "start mark set")
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "INSERTED" })
  local ok, aerr = apply:apply(range, "qux")
  assert_true(ok, "apply after insert " .. tostring(aerr))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[1], "INSERTED", "inserted line kept")
  assert_eq(lines[2], "foo qux baz", "replacement followed text")
  vim.api.nvim_buf_delete(buf, { force = true })

  local ok_bad = apply:apply({
    bufnr = 999999,
    mode = "char",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 1,
    text = "x",
  }, "y")
  assert_true(not ok_bad, "invalid buf apply fails")
end

-- command range clamp
do
  local capture = require("laler.range")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
  vim.api.nvim_set_current_buf(buf)
  local range, err = capture:from_command_range(2, 99)
  assert_true(range ~= nil, "clamped range " .. tostring(err))
  assert_eq(range.end_row, 2, "line2 clamped to last line")
  assert_eq(range.text, "b\nc", "clamped text")
  local bad, berr = capture:from_command_range(0, 2)
  assert_true(bad == nil, "line1 < 1 invalid")
  assert_true(type(berr) == "string", "invalid range err")
  assert_true(type(range.cwd) == "string" and range.cwd ~= "", "range.cwd is a non-empty string")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- diff insert/delete hunks
do
  local diff = require("laler.diff.vim_diff")
  local after = diff:diff("hello", "hello\nworld")
  assert_eq(after.lines[1].kind, "context", "insert-after context kind")
  assert_eq(after.lines[1].text, " hello", "insert-after context text")
  assert_eq(after.lines[2].kind, "add", "insert-after add kind")
  assert_eq(after.lines[2].text, "+world", "insert-after add text")

  local del = diff:diff("hello\nworld", "hello")
  assert_eq(del.lines[1].kind, "context", "delete-last context kind")
  assert_eq(del.lines[1].text, " hello", "delete-last context text")
  assert_eq(del.lines[2].kind, "delete", "delete-last delete kind")
  assert_eq(del.lines[2].text, "-world", "delete-last delete text")

  local before = diff:diff("world", "hello\nworld")
  assert_eq(before.lines[1].kind, "add", "insert-before add kind")
  assert_eq(before.lines[1].text, "+hello", "insert-before add text")
  assert_eq(before.lines[2].kind, "context", "insert-before context kind")
  assert_eq(before.lines[2].text, " world", "insert-before context text")

  local repl = diff:diff("foo", "bar")
  assert_eq(repl.lines[1].kind, "delete", "same-line delete")
  assert_eq(repl.lines[2].kind, "add", "same-line add")
end

-- unicode word tokenize
do
  local diff = require("laler.diff.vim_diff")
  local tokens = diff._tokenize("Я пишу текст")
  assert_true(#tokens > 1, "cyrillic splits into multiple tokens")
  local doc = diff:diff("Я пишу текст", "Я написал текст")
  assert_true(#doc.word_spans > 0, "unicode word spans exist")
  local whole_line = false
  local partial = false
  for _, sp in ipairs(doc.word_spans) do
    local line = doc.lines[sp.line].text
    if sp.col_start <= 1 and sp.col_end >= #line then
      whole_line = true
    end
    if (sp.col_end - sp.col_start) < (#line - 1) then
      partial = true
    end
  end
  assert_true(partial, "word span is a subset of the line")
  assert_true(not whole_line, "word span is not the whole line")
end

-- JSON prose {code} then real object
do
  local parser = require("laler.parse.json")
  local ok, variants = parser:parse('Sure, {code} looks off. {"variants":[{"text":"ok"}]}')
  assert_true(ok, "parses after prose brace")
  assert_eq(variants[1].text, "ok", "prose then object text")

  local dummy = string.rep("{x}", 50)
  ok, variants = parser:parse(dummy .. '{"variants":[{"text":"real"}]}')
  assert_true(ok, "parses after many dummy braces")
  assert_eq(variants[1].text, "real", "finds variants after many braces")

  local braces_in_text = string.rep("{", 300)
  ok, variants = parser:parse('{"variants":[{"text":"' .. braces_in_text .. '"}]}')
  assert_true(ok, "parses variant text with 300 braces")
  assert_eq(variants[1].text, braces_in_text, "keeps 300 braces in text")

  local trailing = string.rep("{x}", 300)
  ok, variants = parser:parse('{"variants":[{"text":"keep"}]}' .. trailing)
  assert_true(ok, "parses variants before 300 dummy braces")
  assert_eq(variants[1].text, "keep", "ignores trailing dummy braces")
end

-- composer delimiter collision
do
  local composer = require("laler.prompt.composer")
  local passage = "keep <<<END_LALER_TEXT>>> this"
  local out = composer:compose({
    id = "t",
    label = "T",
    template = "BODY\n{{text}}",
  }, {
    text = passage,
    language = "en",
    filetype = "",
    n_variants = 3,
  })
  local block = "<<<LALER_TEXT_1>>>\n" .. passage .. "\n<<<END_LALER_TEXT_1>>>"
  assert_true(out:find(block, 1, true) ~= nil, "full passage wrapped uniquely")
  assert_true(out:find("<<<LALER_TEXT_1>>>", 1, true) ~= nil, "unique open marker")
  assert_true(out:find("<<<END_LALER_TEXT_1>>>", 1, true) ~= nil, "unique close marker")
end

-- n_variants list for correct template
do
  local composer = require("laler.prompt.composer")
  local catalog = require("laler.prompt.catalog").new({})
  local out = composer:compose(catalog:get("correct"), {
    text = "hi",
    language = "en",
    filetype = "",
    n_variants = 2,
  })
  assert_true(out:find("1. conservative", 1, true) ~= nil, "n=2 has conservative")
  assert_true(out:find("2. native", 1, true) ~= nil, "n=2 has native")
  assert_true(out:find("3. alternative", 1, true) == nil, "n=2 has no third variant")
  assert_true(out:find("Provide 2 corrected variants:", 1, true) ~= nil, "correct body plural n=2")
  assert_true(out:find("Provide 2 corrected variant:", 1, true) == nil, "correct body not singular for n=2")
end

-- config integer validation
do
  local config = require("laler.config")
  local ok, err = config.validate({ n_variants = 1.5 })
  assert_true(not ok, "rejects n_variants 1.5")
  assert_true(type(err) == "string", "n_variants 1.5 err")
  ok, err = config.validate({ timeout_ms = 0 })
  assert_true(not ok, "rejects timeout_ms 0")
  assert_true(type(err) == "string", "timeout_ms 0 err")
  ok, err = config.validate({ n_variants = 10 })
  assert_true(not ok, "rejects n_variants 10")
  assert_true(type(err) == "string", "n_variants 10 err")
  ok, err = config.validate({ model = "" })
  assert_true(not ok, "rejects empty model")
  assert_true(type(err) == "string" and err:find("model", 1, true) ~= nil, "empty model err")
  ok, err = config.validate({ model = "   " })
  assert_true(not ok, "rejects whitespace-only model")
  ok, err = config.validate({ model = 1 })
  assert_true(not ok, "rejects numeric model")
  ok, err = config.validate({ model = "alibaba-cloud/qwen3.8-flash" })
  assert_true(ok, "accepts string model")
  local padded_model = { model = "  alibaba-cloud/qwen3.8-flash  " }
  ok, err = config.validate(padded_model)
  assert_true(ok, "accepts padded model")
  assert_eq(padded_model.model, "alibaba-cloud/qwen3.8-flash", "validate trims model")
  ok, err = config.validate({ adapter = { name = "pi", model = "" } })
  assert_true(not ok, "rejects empty adapter.model")
  ok, err = config.validate({ adapter = { name = "pi", model = "  \t  " } })
  assert_true(not ok, "rejects whitespace-only adapter.model")
  ok, err = config.validate({ adapter = { name = "pi", model = "alibaba-cloud/qwen3.8-flash" } })
  assert_true(ok, "accepts adapter.model")
  ok, err = config.validate({ thinking = "off" })
  assert_true(not ok, "rejects string thinking")
  assert_true(type(err) == "string" and err:find("thinking", 1, true) ~= nil, "string thinking err")
  ok, err = config.validate({ thinking = false })
  assert_true(ok, "accepts thinking false")
  ok, err = config.validate({ thinking = true })
  assert_true(ok, "accepts thinking true")
  ok, err = config.validate({ adapter = { name = "pi", thinking = "off" } })
  assert_true(not ok, "rejects string adapter.thinking")
  ok, err = config.validate({ adapter = { name = "pi", thinking = false } })
  assert_true(ok, "accepts adapter.thinking false")
  ok, err = config.validate({ base_url = "" })
  assert_true(not ok, "rejects empty top-level base_url")
  assert_true(type(err) == "string" and err:find("base_url", 1, true) ~= nil, "empty base_url err")
  ok, err = config.validate({ base_url = "  \n  " })
  assert_true(not ok, "rejects whitespace-only top-level base_url")
  ok, err = config.validate({ api_key_env = "" })
  assert_true(not ok, "rejects empty top-level api_key_env")
  ok, err = config.validate({ api_key_env = "   " })
  assert_true(not ok, "rejects whitespace-only top-level api_key_env")
  ok, err = config.validate({ api_key_file = 1 })
  assert_true(not ok, "rejects numeric top-level api_key_file")
  local padded_extras = {
    adapter = "openai",
    model = "  gpt-4o-mini  ",
    base_url = "  https://api.openai.com/v1  ",
    api_key_env = "  MY_KEY  ",
    api_key_file = "  ~/.config/laler/key  ",
  }
  ok, err = config.validate(padded_extras)
  assert_true(ok, "accepts padded openai extras")
  assert_eq(padded_extras.model, "gpt-4o-mini", "validate trims openai model")
  assert_eq(padded_extras.base_url, "https://api.openai.com/v1", "validate trims base_url")
  assert_eq(padded_extras.api_key_env, "MY_KEY", "validate trims api_key_env")
  assert_eq(padded_extras.api_key_file, "~/.config/laler/key", "validate trims api_key_file")
  ok, err = config.validate({
    adapter = "openai",
    model = "gpt-4o-mini",
    base_url = "http://127.0.0.1:11434/v1",
    api_key_env = "MY_KEY",
    api_key_file = "~/.config/laler/key",
  })
  assert_true(ok, "accepts top-level openai extras")
  ok, err = config.validate({ adapter = { name = "openai", base_url = "" } })
  assert_true(not ok, "rejects empty adapter.base_url")
  ok, err = config.validate({ adapter = { name = "openai", base_url = "   " } })
  assert_true(not ok, "rejects whitespace-only adapter.base_url")
  ok, err = config.validate({ adapter = { name = "openai", api_key_env = "" } })
  assert_true(not ok, "rejects empty adapter.api_key_env")
  local user_adapter_pad = {
    name = "openai",
    model = "  gpt-4o-mini  ",
    base_url = "  http://127.0.0.1:11434/v1  ",
  }
  local padded_adapter = config.merge({ adapter = user_adapter_pad })
  ok, err = config.validate(padded_adapter)
  assert_true(ok, "accepts padded adapter extras")
  assert_true(padded_adapter.adapter ~= user_adapter_pad, "validate trims merge copy not caller adapter")
  assert_eq(padded_adapter.adapter.model, "gpt-4o-mini", "validate trims adapter.model")
  assert_eq(padded_adapter.adapter.base_url, "http://127.0.0.1:11434/v1", "validate trims adapter.base_url")
  assert_eq(user_adapter_pad.model, "  gpt-4o-mini  ", "validate does not mutate caller adapter.model")
  assert_eq(user_adapter_pad.base_url, "  http://127.0.0.1:11434/v1  ", "validate does not mutate caller adapter.base_url")
  ok, err = config.validate({ adapter = { name = "openai", api_key_file = 1 } })
  assert_true(not ok, "rejects numeric adapter.api_key_file")
  ok, err = config.validate({ adapter = "openai" })
  assert_true(not ok, "rejects openai without model")
  assert_true(type(err) == "string" and err:find("model", 1, true) ~= nil, "openai missing model err")
  ok, err = config.validate({ adapter = { name = "openai" } })
  assert_true(not ok, "rejects openai table without model")
  ok, err = config.validate({ adapter = "openai", model = "gpt-4o-mini" })
  assert_true(ok, "accepts openai string with top-level model")
  ok, err = config.validate({ adapter = { name = "openai" }, model = "gpt-4o-mini" })
  assert_true(ok, "accepts openai table with top-level model")
  ok, err = config.validate({
    adapter = {
      name = "openai",
      cmd = "my-llm",
      args = { "--print" },
    },
  })
  assert_true(ok, "generic named openai does not require model")
  ok, err = config.validate({
    adapter = {
      name = "openai",
      model = "qwen3.8-flash",
      base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      api_key_env = "DASHSCOPE_API_KEY",
      api_key_file = "~/.config/laler/dashscope.key",
    },
  })
  assert_true(ok, "accepts openai adapter extras")
end

-- cursor: prompt as last argv, empty stdin; opencode/pi stay stdin-only
do
  local cursor = require("laler.llm.cursor")
  local spec = cursor:request("SECRET_PROMPT")
  assert_eq(spec.stdin, "", "cursor stdin empty")
  assert_eq(spec.args[#spec.args], "SECRET_PROMPT", "cursor prompt last argv")
  assert_true(vim.tbl_contains(spec.args, "SECRET_PROMPT"), "cursor args have prompt")
  assert_true(vim.tbl_contains(spec.args, "-p"), "cursor -p")
  assert_true(vim.tbl_contains(spec.args, "--mode"), "cursor --mode")
  assert_true(vim.tbl_contains(spec.args, "ask"), "cursor --mode ask")
  assert_true(vim.tbl_contains(spec.args, "--output-format"), "cursor --output-format")
  assert_true(vim.tbl_contains(spec.args, "text"), "cursor output-format text")
  assert_true(vim.tbl_contains(spec.args, "--trust"), "cursor --trust")
  assert_true(vim.tbl_contains(spec.args, "--sandbox"), "cursor --sandbox")
  local sandbox_i
  for i, a in ipairs(spec.args) do
    if a == "--sandbox" then
      sandbox_i = i
      break
    end
  end
  assert_true(sandbox_i ~= nil, "cursor --sandbox index")
  assert_eq(spec.args[sandbox_i + 1], "enabled", "cursor sandbox enabled")
  assert_true(not vim.tbl_contains(spec.args, "--force"), "cursor no --force")
  assert_true(not vim.tbl_contains(spec.args, "--yolo"), "cursor no --yolo")
  assert_true(not vim.tbl_contains(spec.args, "--model"), "cursor default has no --model")
  assert_true(not vim.tbl_contains(spec.args, "--thinking"), "cursor default has no --thinking")

  local oc = require("laler.llm.opencode")
  local ospec = oc:request("SECRET_PROMPT")
  assert_eq(ospec.stdin, "SECRET_PROMPT", "opencode stdin")
  assert_true(not table.concat(ospec.args, "\0"):find("SECRET_PROMPT", 1, true), "opencode args have no prompt")
  assert_eq(ospec.args[1], "run", "opencode run")
  assert_true(vim.tbl_contains(ospec.args, "--format"), "opencode --format")
  assert_true(vim.tbl_contains(ospec.args, "--pure"), "opencode --pure")
  assert_true(not vim.tbl_contains(ospec.args, "--permissions"), "opencode has no --permissions")
  assert_true(ospec.env and ospec.env.OPENCODE_PERMISSION ~= nil, "opencode permission env")
  assert_true(ospec.env.OPENCODE_PERMISSION:find("deny", 1, true) ~= nil, "opencode deny")
  assert_true(not vim.tbl_contains(ospec.args, "--model"), "opencode default has no --model")
  assert_true(not vim.tbl_contains(ospec.args, "--variant"), "opencode default has no --variant")
  assert_true(not vim.tbl_contains(ospec.args, "--thinking"), "opencode default has no --thinking")
end

-- openai adapter: curl JobSpec, env/file key, unwrap
do
  local openai = require("laler.llm.openai")
  local llm = require("laler.llm")
  local test_env = "LALER_TEST_OPENAI_KEY"
  vim.env[test_env] = nil

  local function decode_body(spec)
    local ok, data = pcall(vim.json.decode, spec.stdin)
    assert_true(ok and type(data) == "table", "openai stdin is JSON")
    return data
  end

  local function argv_blob(spec)
    return spec.cmd .. "\0" .. table.concat(spec.args or {}, "\0")
  end

  local missing_ok, missing_err = pcall(openai.new, {})
  assert_true(not missing_ok, "openai new requires model")
  assert_true(tostring(missing_err):find("model", 1, true) ~= nil, "openai missing model err")
  local ws_ok, ws_err = pcall(openai.new, { model = "   " })
  assert_true(not ws_ok, "openai new rejects whitespace-only model")
  assert_true(tostring(ws_err):find("model", 1, true) ~= nil, "openai whitespace model err")

  vim.env[test_env] = "env-secret-key"
  local client = openai.new({
    model = "qwen3.8-flash",
    base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/",
    api_key_env = test_env,
    thinking = false,
  })
  local spec = client:request("hi")
  assert_eq(spec.cmd, "sh", "openai cmd sh")
  assert_eq(spec.args[1], "-c", "openai sh -c")
  assert_true(type(spec.args[2]) == "string" and spec.args[2]:find("^exec curl ", 1) ~= nil, "openai exec curl")
  assert_true(spec.args[2]:find("^exec curl %-q %-sS %-g ", 1) ~= nil, "openai curl -q first then -sS -g")
  assert_true(spec.args[2]:find("--data-binary @-", 1, true) ~= nil, "openai stdin body")
  assert_true(spec.args[2]:find("%s%-g%s") ~= nil, "openai curl has -g globoff")
  assert_true(spec.args[2]:find("%s%-f%s") == nil, "openai curl has no -f")
  assert_eq(spec.env.LALER_OPENAI_URL, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions", "openai strips slash and appends chat/completions")
  assert_eq(spec.env.LALER_OPENAI_KEY, "env-secret-key", "openai key from env")
  assert_true(not argv_blob(spec):find("env-secret-key", 1, true), "openai key not in argv")
  assert_true(not argv_blob(spec):find("dashscope-intl", 1, true), "openai url not in argv")
  assert_true(not spec.stdin:find("env-secret-key", 1, true), "openai key not in stdin")
  local body = decode_body(spec)
  assert_eq(body.model, "qwen3.8-flash", "openai JSON model is API id")
  assert_eq(body.stream, false, "openai stream false")
  assert_eq(body.messages[1].role, "user", "openai user role")
  assert_eq(body.messages[1].content, "hi", "openai composed in JSON messages")
  assert_eq(body.enable_thinking, false, "openai enable_thinking when thinking false and dashscope host")

  local ds_omit = openai.new({
    model = "qwen3.8-flash",
    base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    api_key_env = test_env,
  })
  assert_eq(
    decode_body(ds_omit:request("x")).enable_thinking,
    false,
    "openai enable_thinking when thinking omitted on dashscope"
  )
  local ds_true_ok, ds_true_err = pcall(openai.new, {
    model = "qwen3.8-flash",
    base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    thinking = true,
  })
  assert_true(not ds_true_ok, "openai rejects thinking true on dashscope")
  assert_true(tostring(ds_true_err):find("thinking", 1, true) ~= nil, "openai dashscope thinking true err")
  assert_true(tostring(ds_true_err):find("non-streaming", 1, true) ~= nil, "openai dashscope thinking true mentions non-streaming")

  local not_ds = openai.new({
    model = "local-model",
    base_url = "https://notdashscope.example/v1",
    api_key_env = test_env,
  })
  assert_true(
    decode_body(not_ds:request("x")).enable_thinking == nil,
    "openai omits enable_thinking for notdashscope substring host"
  )
  local ds_suffix = openai.new({
    model = "local-model",
    base_url = "https://dashscoped.example/v1",
    api_key_env = test_env,
  })
  assert_true(
    decode_body(ds_suffix:request("x")).enable_thinking == nil,
    "openai omits enable_thinking for dashscoped label"
  )
  local nested_ds = openai.new({
    model = "qwen3.8-flash",
    base_url = "https://foo.dashscope.aliyuncs.com/v1",
    api_key_env = test_env,
  })
  assert_eq(
    decode_body(nested_ds:request("x")).enable_thinking,
    false,
    "openai enable_thinking when dashscope is a DNS label"
  )
  local maas = openai.new({
    model = "qwen3.8-flash",
    base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
    api_key_env = test_env,
    thinking = false,
  })
  assert_eq(
    decode_body(maas:request("x")).enable_thinking,
    false,
    "openai enable_thinking on Alibaba MaaS token-plan host"
  )
  local maas_true_ok, maas_true_err = pcall(openai.new, {
    model = "qwen3.8-flash",
    base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
    thinking = true,
  })
  assert_true(not maas_true_ok, "openai rejects thinking true on Alibaba MaaS")
  assert_true(tostring(maas_true_err):find("thinking", 1, true) ~= nil, "openai MaaS thinking true err")
  local not_maas = openai.new({
    model = "local-model",
    base_url = "https://notmaas.aliyuncs.com/v1",
    api_key_env = test_env,
    thinking = false,
  })
  assert_true(
    decode_body(not_maas:request("x")).enable_thinking == nil,
    "openai omits enable_thinking for notmaas.aliyuncs.com"
  )

  local ollama_off = openai.new({
    model = "local-model",
    base_url = "http://127.0.0.1:11434/v1",
    api_key_env = test_env,
    thinking = false,
  })
  assert_true(
    decode_body(ollama_off:request("x")).enable_thinking == nil,
    "openai omits enable_thinking for non-dashscope custom host"
  )
  local groq_off = openai.new({
    model = "llama-3.1-8b-instant",
    base_url = "https://api.groq.com/openai/v1",
    api_key_env = test_env,
    thinking = false,
  })
  assert_true(
    decode_body(groq_off:request("x")).enable_thinking == nil,
    "openai omits enable_thinking for groq"
  )
  local ds_case = openai.new({
    model = "qwen3.8-flash",
    base_url = "https://DASHSCOPE.aliyuncs.com/compatible-mode/v1",
    api_key_env = test_env,
    thinking = false,
  })
  assert_eq(
    decode_body(ds_case:request("x")).enable_thinking,
    false,
    "openai enable_thinking is case-insensitive on dashscope host"
  )
  local ds_scheme_case = openai.new({
    model = "qwen3.8-flash",
    base_url = "HTTPS://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    api_key_env = test_env,
    thinking = false,
  })
  assert_eq(
    decode_body(ds_scheme_case:request("x")).enable_thinking,
    false,
    "openai enable_thinking with uppercase HTTPS scheme on dashscope"
  )

  local official_off = openai.new({
    model = "gpt-4o-mini",
    api_key_env = test_env,
    thinking = false,
  })
  local offbody = decode_body(official_off:request("x"))
  assert_true(offbody.enable_thinking == nil, "openai omits enable_thinking on default host")
  assert_eq(offbody.stream, false, "openai stream false on default host")
  local official_url = openai.new({
    model = "gpt-4o-mini",
    api_key_env = test_env,
    base_url = "https://api.openai.com/v1",
    thinking = false,
  })
  assert_true(
    decode_body(official_url:request("x")).enable_thinking == nil,
    "openai omits enable_thinking for api.openai.com"
  )

  local no_think = openai.new({
    model = "qwen3.8-flash",
    api_key_env = test_env,
    thinking = true,
  })
  local ntbody = decode_body(no_think:request("x"))
  assert_true(ntbody.enable_thinking == nil, "openai omits enable_thinking when thinking true")
  local default_think = openai.new({
    model = "gpt-4o-mini",
    api_key_env = test_env,
  })
  local dtbody = decode_body(default_think:request("x"))
  assert_true(dtbody.enable_thinking == nil, "openai omits enable_thinking by default")
  assert_eq(default_think:request("x").env.LALER_OPENAI_URL, "https://api.openai.com/v1/chat/completions", "openai default base_url")
  local full_url = openai.new({
    model = "gpt-4o-mini",
    api_key_env = test_env,
    base_url = "https://api.openai.com/v1/chat/completions/",
  })
  assert_eq(full_url:request("x").env.LALER_OPENAI_URL, "https://api.openai.com/v1/chat/completions", "openai does not double chat/completions")
  local query_url = openai.new({
    model = "gpt-4o-mini",
    api_key_env = test_env,
    base_url = "https://example.com/v1/chat/completions?api-version=2024-10-01",
  })
  assert_eq(
    query_url:request("x").env.LALER_OPENAI_URL,
    "https://example.com/v1/chat/completions?api-version=2024-10-01",
    "openai keeps query and does not double chat/completions"
  )
  local query_slash = openai.new({
    model = "gpt-4o-mini",
    api_key_env = test_env,
    base_url = "https://example.com/v1/chat/completions/?api-version=1",
  })
  assert_eq(
    query_slash:request("x").env.LALER_OPENAI_URL,
    "https://example.com/v1/chat/completions?api-version=1",
    "openai strips slash before query without doubling"
  )
  local ipv6 = openai.new({
    model = "local-model",
    base_url = "http://[::1]:11434/v1",
  })
  local ipv6spec = ipv6:request("x")
  assert_eq(ipv6spec.env.LALER_OPENAI_URL, "http://[::1]:11434/v1/chat/completions", "openai keeps IPv6 host")
  assert_true(decode_body(ipv6spec).enable_thinking == nil, "ipv6 is not dashscope")
  assert_true(ipv6spec.env.LALER_OPENAI_KEY == nil, "ipv6 is not official openai")
  local padded_url = openai.new({
    model = "  gpt-4o-mini  ",
    api_key_env = test_env,
    base_url = "  https://api.openai.com/v1  ",
  })
  assert_eq(
    padded_url:request("x").env.LALER_OPENAI_URL,
    "https://api.openai.com/v1/chat/completions",
    "padded base_url is trimmed"
  )
  assert_eq(decode_body(padded_url:request("x")).model, "gpt-4o-mini", "padded model is trimmed")

  local path = vim.fn.tempname()
  local f = assert(io.open(path, "w"))
  f:write("\n  file-secret-key  \nsecond-line-ignored\n")
  f:close()
  vim.env[test_env] = nil
  local from_file = openai.new({
    model = "qwen3.8-flash",
    api_key_env = test_env,
    api_key_file = path,
  })
  local fspec = from_file:request("hi")
  assert_eq(fspec.env.LALER_OPENAI_KEY, "file-secret-key", "openai key from first non-empty line")
  assert_true(not argv_blob(fspec):find("file-secret-key", 1, true), "file key not in argv")
  assert_true(fspec.args[2]:find("Authorization", 1, true) ~= nil, "file key uses auth script")

  vim.env[test_env] = "env-wins-key"
  local both = openai.new({
    model = "qwen3.8-flash",
    api_key_env = test_env,
    api_key_file = path,
  })
  assert_eq(both:request("hi").env.LALER_OPENAI_KEY, "env-wins-key", "openai env wins over file")

  local saved_openai_key = vim.env.OPENAI_API_KEY
  vim.env.OPENAI_API_KEY = "default-openai-key"
  local file_only = openai.new({
    model = "qwen3.8-flash",
    api_key_file = path,
  })
  assert_eq(file_only:request("hi").env.LALER_OPENAI_KEY, "file-secret-key", "openai file wins over default OPENAI_API_KEY")
  local default_key = openai.new({ model = "gpt-4o-mini" })
  assert_eq(default_key:request("x").env.LALER_OPENAI_KEY, "default-openai-key", "openai default OPENAI_API_KEY")
  local official_url_key = openai.new({
    model = "gpt-4o-mini",
    base_url = "https://api.openai.com/v1",
  })
  assert_eq(
    official_url_key:request("x").env.LALER_OPENAI_KEY,
    "default-openai-key",
    "openai OPENAI_API_KEY on explicit api.openai.com"
  )
  local official_userinfo = openai.new({
    model = "gpt-4o-mini",
    base_url = "https://user:pass@api.openai.com/v1",
  })
  assert_eq(
    official_userinfo:request("x").env.LALER_OPENAI_KEY,
    "default-openai-key",
    "openai OPENAI_API_KEY with userinfo on api.openai.com"
  )
  local official_fqdn = openai.new({
    model = "gpt-4o-mini",
    base_url = "https://api.openai.com./v1",
  })
  assert_eq(
    official_fqdn:request("x").env.LALER_OPENAI_KEY,
    "default-openai-key",
    "openai OPENAI_API_KEY on trailing-dot FQDN"
  )
  local official_scheme_case = openai.new({
    model = "gpt-4o-mini",
    base_url = "HTTPS://api.openai.com/v1",
  })
  assert_eq(
    official_scheme_case:request("x").env.LALER_OPENAI_KEY,
    "default-openai-key",
    "openai OPENAI_API_KEY with uppercase HTTPS scheme"
  )
  local official_http_case = openai.new({
    model = "gpt-4o-mini",
    base_url = "Http://api.openai.com/v1",
  })
  assert_eq(
    official_http_case:request("x").env.LALER_OPENAI_KEY,
    "default-openai-key",
    "openai OPENAI_API_KEY with mixed-case Http scheme"
  )
  local custom_no_key = openai.new({
    model = "local-model",
    base_url = "http://127.0.0.1:11434/v1",
  })
  assert_true(
    custom_no_key:request("x").env.LALER_OPENAI_KEY == nil,
    "non-official host does not use OPENAI_API_KEY"
  )
  assert_true(
    not custom_no_key:request("x").args[2]:find("Authorization", 1, true),
    "custom base_url omits Authorization without explicit key"
  )
  local custom_file = openai.new({
    model = "local-model",
    base_url = "http://127.0.0.1:11434/v1",
    api_key_file = path,
  })
  assert_eq(custom_file:request("x").env.LALER_OPENAI_KEY, "file-secret-key", "custom base_url uses explicit api_key_file")
  vim.env[test_env] = nil
  local skip_default = openai.new({
    model = "local-model",
    api_key_env = test_env,
  })
  assert_true(skip_default:request("hi").env.LALER_OPENAI_KEY == nil, "explicit empty api_key_env skips OPENAI_API_KEY")
  os.remove(path)
  vim.env[test_env] = nil
  vim.env.OPENAI_API_KEY = saved_openai_key

  local no_key = openai.new({
    model = "local-model",
    api_key_env = test_env,
  })
  local nkspec = no_key:request("hi")
  assert_true(nkspec.env.LALER_OPENAI_KEY == nil, "openai omits key env when unset")
  assert_true(not nkspec.args[2]:find("Authorization", 1, true), "openai omits Authorization without key")

  local ok_file, err_file = pcall(function()
    openai.new({
      model = "qwen3.8-flash",
      api_key_env = test_env,
      api_key_file = "/no/such/laler-openai-key",
    }):request("x")
  end)
  assert_true(not ok_file, "openai missing key file errors")
  assert_true(tostring(err_file):find("api_key_file", 1, true) ~= nil, "openai missing key file mentions api_key_file")

  local named = llm.resolve({
    name = "openai",
    model = "qwen3.8-flash",
    base_url = "http://127.0.0.1:11434/v1",
    api_key_env = test_env,
  })
  assert_eq(named.name, "openai", "named builtin openai")
  vim.env[test_env] = "named-key"
  local nspec = named:request("composed-text")
  assert_eq(nspec.env.LALER_OPENAI_URL, "http://127.0.0.1:11434/v1/chat/completions", "named builtin forwards base_url")
  assert_eq(nspec.env.LALER_OPENAI_KEY, "named-key", "named builtin forwards api_key_env")
  assert_eq(decode_body(nspec).messages[1].content, "composed-text", "named builtin stdin prompt")
  vim.env[test_env] = nil

  local via_string = llm.resolve("openai", {
    model = "gpt-4o-mini",
    api_key_env = test_env,
  })
  assert_eq(via_string.name, "openai", "resolve string openai")
  assert_eq(decode_body(via_string:request("z")).model, "gpt-4o-mini", "resolve string openai model")

  local via_pad = llm.resolve("openai", {
    model = "  gpt-4o-mini  ",
    api_key_env = test_env,
    base_url = "  https://api.openai.com/v1  ",
  })
  assert_eq(decode_body(via_pad:request("z")).model, "gpt-4o-mini", "resolve trims model")
  assert_eq(
    via_pad:request("z").env.LALER_OPENAI_URL,
    "https://api.openai.com/v1/chat/completions",
    "resolve trims base_url"
  )

  local ok_unwrap, content = pcall(openai.unwrap_stdout, vim.json.encode({
    choices = {
      { message = { content = '{"variants":[{"text":"Hello"}]}' } },
    },
  }))
  assert_true(ok_unwrap, "unwrap success")
  assert_eq(content, '{"variants":[{"text":"Hello"}]}', "unwrap content")

  local ok_api, api_err = pcall(openai.unwrap_stdout, '{"error":{"message":"nope"}}')
  assert_true(not ok_api, "unwrap API error")
  assert_eq(api_err, "nope", "unwrap API error message")

  local ok_parts, parts_content = pcall(openai.unwrap_stdout, vim.json.encode({
    choices = {
      {
        message = {
          content = {
            { type = "text", text = '{"variants":[' },
            { type = "image_url", image_url = { url = "x" } },
            { type = "text", text = '{"text":"Hi"}]}' },
          },
        },
      },
    },
  }))
  assert_true(ok_parts, "unwrap content parts")
  assert_eq(parts_content, '{"variants":[{"text":"Hi"}]}', "unwrap joins part.text")

  local ok_str_parts, str_parts = pcall(openai.unwrap_stdout, vim.json.encode({
    choices = {
      {
        message = {
          content = {
            '{"variants":[',
            { type = "text", text = '{"text":' },
            '"Hi"}]}',
          },
        },
      },
    },
  }))
  assert_true(ok_str_parts, "unwrap string content parts")
  assert_eq(str_parts, '{"variants":[{"text":"Hi"}]}', "unwrap joins string parts and part.text")

  local ok_one_part, one_part = pcall(openai.unwrap_stdout, vim.json.encode({
    choices = {
      {
        message = {
          content = { type = "text", text = '{"variants":[{"text":"One"}]}' },
        },
      },
    },
  }))
  assert_true(ok_one_part, "unwrap single content part object")
  assert_eq(one_part, '{"variants":[{"text":"One"}]}', "unwrap uses content.text on part object")

  local ok_err_null, null_err_content = pcall(
    openai.unwrap_stdout,
    '{"error":null,"choices":[{"message":{"content":"ok"}}]}'
  )
  assert_true(ok_err_null, "unwrap error null is success")
  assert_eq(null_err_content, "ok", "unwrap error null uses content")

  local ok_ref, ref_err = pcall(openai.unwrap_stdout, '{"choices":[{"message":{"content":null,"refusal":"nope I refuse"}}]}')
  assert_true(not ok_ref, "unwrap refusal")
  assert_eq(ref_err, "nope I refuse", "unwrap refusal message")

  local ok_nil, nil_err = pcall(openai.unwrap_stdout, '{"choices":[{"message":{"content":null}}]}')
  assert_true(not ok_nil, "unwrap null content")
  assert_true(tostring(nil_err):find("missing content", 1, true) ~= nil, "unwrap null content err")

  local ok_empty, empty_err = pcall(openai.unwrap_stdout, '{"choices":[{"message":{"content":""}}]}')
  assert_true(not ok_empty, "unwrap empty content")
  assert_true(tostring(empty_err):find("missing content", 1, true) ~= nil, "unwrap empty content err")

  local ok_reason, reason_err = pcall(openai.unwrap_stdout, vim.json.encode({
    choices = {
      { message = { content = "", reasoning_content = '{"variants":[{"text":"R"}]}' } },
    },
  }))
  assert_true(not ok_reason, "unwrap empty content ignores reasoning_content")
  assert_true(tostring(reason_err):find("missing content", 1, true) ~= nil, "unwrap reasoning_content not used")

  local ok_null_r, null_r_err = pcall(openai.unwrap_stdout, '{"choices":[{"message":{"content":null,"reasoning_content":"from-reason"}}]}')
  assert_true(not ok_null_r, "unwrap null content ignores reasoning_content")
  assert_true(tostring(null_r_err):find("missing content", 1, true) ~= nil, "unwrap null content not reasoning")

  local ok_pref, pref = pcall(openai.unwrap_stdout, vim.json.encode({
    choices = {
      { message = { content = '{"variants":[{"text":"C"}]}', reasoning_content = "nope" } },
    },
  }))
  assert_true(ok_pref, "unwrap uses content when present")
  assert_eq(pref, '{"variants":[{"text":"C"}]}', "unwrap content ignores reasoning_content")

  local ok_bad, bad_err = pcall(openai.unwrap_stdout, "not-json")
  assert_true(not ok_bad, "unwrap rejects non-JSON")
  assert_true(tostring(bad_err):find("not JSON", 1, true) ~= nil, "unwrap non-JSON err")
end

-- --model for pi, cursor, and opencode
do
  local function model_value(args)
    for i, a in ipairs(args) do
      if a == "--model" then
        return args[i + 1], i
      end
    end
    return nil, nil
  end

  local llm = require("laler.llm")
  local pi = llm.resolve("pi", { model = "alibaba-cloud/qwen3.8-flash" })
  local spec = pi:request("hello")
  local pmodel, pi_i = model_value(spec.args)
  assert_eq(pmodel, "alibaba-cloud/qwen3.8-flash", "pi --model value")
  assert_true(vim.tbl_contains(spec.args, "--no-skills"), "pi model keeps builtin flags")
  assert_true(not vim.tbl_contains(spec.args, "--no-extensions"), "pi model omits --no-extensions for catalog lookup")
  assert_eq(spec.stdin, "hello", "pi model stdin")
  assert_true(pi_i ~= nil, "pi --model index")

  local named = llm.resolve({
    name = "pi",
    model = "alibaba-cloud/qwen3.8-flash",
  })
  local nspec = named:request("hello")
  local nmodel = model_value(nspec.args)
  assert_eq(nmodel, "alibaba-cloud/qwen3.8-flash", "named builtin adapter.model")
  assert_true(vim.tbl_contains(nspec.args, "--no-context-files"), "named builtin+model keeps pi flags")

  local top_overridden = llm.resolve({
    name = "pi",
    model = "alibaba-cloud/qwen3.8-flash",
  }, { model = "ignored-top-level" })
  local omodel = model_value(top_overridden:request("x").args)
  assert_eq(omodel, "alibaba-cloud/qwen3.8-flash", "adapter.model wins over top-level")

  local cursor = require("laler.llm.cursor").new({ model = "gpt-5" })
  local cspec = cursor:request("SECRET_PROMPT")
  local cmodel, ci = model_value(cspec.args)
  assert_eq(cmodel, "gpt-5", "cursor --model value")
  assert_eq(cspec.args[#cspec.args], "SECRET_PROMPT", "cursor prompt still last with --model")
  assert_true(ci ~= nil and ci < #cspec.args, "cursor --model before prompt")
  assert_eq(cspec.stdin, "", "cursor stdin empty with --model")

  local oc = require("laler.llm.opencode").new({ model = "anthropic/claude-sonnet-4-5" })
  local ospec_m = oc:request("SECRET_PROMPT")
  local om = model_value(ospec_m.args)
  assert_eq(om, "anthropic/claude-sonnet-4-5", "opencode --model value")
  assert_eq(ospec_m.stdin, "SECRET_PROMPT", "opencode stdin with --model")
  assert_true(not table.concat(ospec_m.args, "\0"):find("SECRET_PROMPT", 1, true), "opencode args have no prompt with --model")
  assert_eq(ospec_m.args[1], "run", "opencode run with --model")

  local via_resolve = llm.resolve("cursor", { model = "gpt-5" })
  local rspec = via_resolve:request("PROMPT")
  local rm = model_value(rspec.args)
  assert_eq(rm, "gpt-5", "resolve cursor model")
  assert_eq(rspec.args[#rspec.args], "PROMPT", "resolve cursor prompt last")

  local oc_resolve = llm.resolve("opencode", { model = "anthropic/claude-sonnet-4-5" })
  local orm = model_value(oc_resolve:request("x").args)
  assert_eq(orm, "anthropic/claude-sonnet-4-5", "resolve opencode model")

  local generic = llm.resolve({
    name = "echo",
    cmd = "echo",
    args = { "-n" },
    model = "custom-model",
  })
  local gspec = generic:request("x")
  local gm = model_value(gspec.args)
  assert_eq(gm, "custom-model", "generic adapter.model")
  assert_true(vim.tbl_contains(gspec.args, "-n"), "generic keeps args")

  local gtop = llm.resolve({
    name = "echo",
    cmd = "echo",
    args = { "-n" },
  }, { model = "from-top" })
  local gtm = model_value(gtop:request("x").args)
  assert_eq(gtm, "from-top", "generic gets top-level model")

  local empty_model = require("laler.llm.pi").new({ model = "" })
  assert_true(not vim.tbl_contains(empty_model:request("x").args, "--model"), "empty model omitted")

  local ok_setup = pcall(function()
    require("laler").setup({ adapter = "pi", model = "alibaba-cloud/qwen3.8-flash" })
  end)
  assert_true(ok_setup, "setup with model")
  assert_eq(require("laler")._config.model, "alibaba-cloud/qwen3.8-flash", "setup stores model")

  local stored = { "-n", "--flag" }
  local copied = require("laler.llm.generic").new({
    name = "echo",
    cmd = "echo",
    args = stored,
    model = "m",
  })
  local cargs = copied:request("x").args
  local cm = model_value(cargs)
  assert_eq(cm, "m", "generic new() model")
  assert_eq(#stored, 2, "generic model does not mutate stored args")
  assert_eq(stored[1], "-n", "generic stored args unchanged")

  -- table with cmd still uses generic (does not switch to builtin flags)
  local generic_pi = llm.resolve({
    name = "pi",
    cmd = "pi",
    args = {
      "-p",
      "--no-tools",
      "--no-session",
      "--thinking",
      "off",
      "--model",
      "alibaba-cloud/qwen3.8-flash",
    },
  })
  local gpspec = generic_pi:request("x")
  assert_true(vim.tbl_contains(gpspec.args, "--thinking"), "generic pi keeps extra args")
  assert_true(vim.tbl_contains(gpspec.args, "alibaba-cloud/qwen3.8-flash"), "generic pi keeps --model in args")
  assert_true(not vim.tbl_contains(gpspec.args, "--no-skills"), "generic pi does not add builtin-only flags")
end

-- thinking = false for pi, cursor, and opencode
do
  local function flag_value(args, flag)
    for i, a in ipairs(args) do
      if a == flag then
        return args[i + 1], i
      end
    end
    return nil, nil
  end

  local llm = require("laler.llm")
  local pi = llm.resolve("pi", {
    model = "alibaba-cloud/qwen3.8-flash",
    thinking = false,
  })
  local spec = pi:request("hello")
  assert_eq(flag_value(spec.args, "--thinking"), "off", "pi --thinking off")
  assert_eq(flag_value(spec.args, "--model"), "alibaba-cloud/qwen3.8-flash", "pi model with thinking off")
  assert_true(vim.tbl_contains(spec.args, "--no-skills"), "pi thinking keeps builtin flags")
  assert_true(not vim.tbl_contains(spec.args, "--no-extensions"), "pi model+thinking omits --no-extensions")
  local think_i, model_i
  for i, a in ipairs(spec.args) do
    if a == "--thinking" then
      think_i = i
    elseif a == "--model" then
      model_i = i
    end
  end
  assert_true(think_i ~= nil and model_i ~= nil and think_i < model_i, "pi --thinking before --model")

  local named = llm.resolve({
    name = "pi",
    model = "alibaba-cloud/qwen3.8-flash",
    thinking = false,
  })
  local nspec = named:request("hello")
  assert_eq(flag_value(nspec.args, "--thinking"), "off", "named builtin adapter.thinking")

  local top_overridden = llm.resolve({
    name = "pi",
    thinking = false,
  }, { thinking = true })
  assert_eq(flag_value(top_overridden:request("x").args, "--thinking"), "off", "adapter.thinking wins over top-level")

  local top_false_overridden = llm.resolve({
    name = "pi",
    thinking = true,
  }, { thinking = false })
  assert_true(
    not vim.tbl_contains(top_false_overridden:request("x").args, "--thinking"),
    "adapter.thinking true wins over top-level false"
  )

  local think_true = llm.resolve("pi", { thinking = true })
  assert_true(not vim.tbl_contains(think_true:request("x").args, "--thinking"), "thinking true does not add --thinking")

  local oc = require("laler.llm.opencode").new({
    model = "anthropic/claude-sonnet-4-5",
    thinking = false,
  })
  local ospec = oc:request("SECRET_PROMPT")
  assert_eq(flag_value(ospec.args, "--variant"), "none", "opencode --variant none")
  assert_true(not vim.tbl_contains(ospec.args, "--thinking"), "opencode thinking false is not --thinking")
  assert_eq(flag_value(ospec.args, "--model"), "anthropic/claude-sonnet-4-5", "opencode model with thinking off")
  assert_eq(ospec.args[1], "run", "opencode run with thinking off")

  local oc_resolve = llm.resolve("opencode", { thinking = false })
  assert_eq(flag_value(oc_resolve:request("x").args, "--variant"), "none", "resolve opencode thinking")

  local cursor = require("laler.llm.cursor").new({ model = "gpt-5", thinking = false })
  local cspec = cursor:request("SECRET_PROMPT")
  assert_true(not vim.tbl_contains(cspec.args, "--thinking"), "cursor thinking false has no --thinking")
  assert_true(not vim.tbl_contains(cspec.args, "--variant"), "cursor thinking false has no --variant")
  assert_eq(cspec.args[#cspec.args], "SECRET_PROMPT", "cursor prompt still last with thinking false")
  assert_eq(flag_value(cspec.args, "--model"), "gpt-5", "cursor model with thinking false")

  local generic = llm.resolve({
    name = "echo",
    cmd = "echo",
    args = { "-n" },
    thinking = false,
  })
  local gspec = generic:request("x")
  assert_eq(flag_value(gspec.args, "--thinking"), "off", "generic adapter.thinking")
  assert_true(vim.tbl_contains(gspec.args, "-n"), "generic thinking keeps args")

  local gtop = llm.resolve({
    name = "echo",
    cmd = "echo",
    args = { "-n" },
  }, { thinking = false })
  assert_eq(flag_value(gtop:request("x").args, "--thinking"), "off", "generic gets top-level thinking")

  local stored = { "-n", "--flag" }
  local copied = require("laler.llm.generic").new({
    name = "echo",
    cmd = "echo",
    args = stored,
    thinking = false,
  })
  local cargs = copied:request("x").args
  assert_eq(flag_value(cargs, "--thinking"), "off", "generic new() thinking")
  assert_eq(#stored, 2, "generic thinking does not mutate stored args")

end

-- setup wires model/thinking into session llm client
do
  local laler = require("laler")
  local session = require("laler.session")

  local function flag_value(args, flag)
    for i, a in ipairs(args) do
      if a == flag then
        return args[i + 1], i
      end
    end
    return nil, nil
  end

  local ok_setup = pcall(function()
    laler.setup({
      adapter = "pi",
      model = "alibaba-cloud/qwen3.8-flash",
      thinking = false,
    })
  end)
  assert_true(ok_setup, "setup with model and thinking false")
  assert_eq(laler._config.model, "alibaba-cloud/qwen3.8-flash", "setup stores model")
  assert_eq(laler._config.thinking, false, "setup stores thinking")

  local ctx = session._ctx()
  assert_true(ctx ~= nil and ctx.llm ~= nil, "setup binds session ctx")
  local spec = ctx.llm:request("hello")
  assert_eq(spec.cmd, "pi", "setup llm pi cmd")
  assert_eq(spec.stdin, "hello", "setup llm stdin")
  assert_eq(flag_value(spec.args, "--model"), "alibaba-cloud/qwen3.8-flash", "setup llm --model")
  assert_eq(flag_value(spec.args, "--thinking"), "off", "setup llm --thinking off")
  assert_true(vim.tbl_contains(spec.args, "--no-skills"), "setup llm keeps pi flags")
  assert_true(not vim.tbl_contains(spec.args, "--no-extensions"), "setup llm omits --no-extensions with model")
end

-- setup wires openai top-level base_url / api_key_env / thinking
do
  local laler = require("laler")
  local session = require("laler.session")
  local test_env = "LALER_TEST_OPENAI_KEY"
  vim.env[test_env] = "setup-secret"

  local ok_setup = pcall(function()
    laler.setup({
      adapter = "openai",
      model = "qwen3.8-flash",
      base_url = "http://127.0.0.1:11434/v1",
      api_key_env = test_env,
      thinking = false,
    })
  end)
  assert_true(ok_setup, "setup openai top-level extras")
  assert_eq(laler._config.base_url, "http://127.0.0.1:11434/v1", "setup stores base_url")
  assert_eq(laler._config.api_key_env, test_env, "setup stores api_key_env")
  local ctx = session._ctx()
  assert_true(ctx ~= nil and ctx.llm ~= nil, "setup binds openai ctx")
  local spec = ctx.llm:request("hello")
  assert_eq(spec.env.LALER_OPENAI_URL, "http://127.0.0.1:11434/v1/chat/completions", "setup forwards base_url")
  assert_eq(spec.env.LALER_OPENAI_KEY, "setup-secret", "setup forwards api_key_env")
  local ok_body, body = pcall(vim.json.decode, spec.stdin)
  assert_true(ok_body and type(body) == "table", "setup openai stdin JSON")
  assert_eq(body.model, "qwen3.8-flash", "setup openai model")
  assert_eq(body.stream, false, "setup openai stream false")
  assert_true(body.enable_thinking == nil, "setup non-dashscope custom base_url omits enable_thinking")
  assert_eq(body.messages[1].content, "hello", "setup openai composed in JSON")

  local ok_ds = pcall(function()
    laler.setup({
      adapter = "openai",
      model = "qwen3.8-flash",
      base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      api_key_env = test_env,
      thinking = false,
    })
  end)
  assert_true(ok_ds, "setup openai dashscope thinking")
  spec = session._ctx().llm:request("hello")
  ok_body, body = pcall(vim.json.decode, spec.stdin)
  assert_true(ok_body and type(body) == "table", "setup dashscope stdin JSON")
  assert_eq(body.enable_thinking, false, "setup dashscope sends enable_thinking")

  local ok_ds_omit = pcall(function()
    laler.setup({
      adapter = "openai",
      model = "qwen3.8-flash",
      base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      api_key_env = test_env,
    })
  end)
  assert_true(ok_ds_omit, "setup openai dashscope omit thinking")
  spec = session._ctx().llm:request("hello")
  ok_body, body = pcall(vim.json.decode, spec.stdin)
  assert_true(ok_body and type(body) == "table", "setup dashscope omit stdin JSON")
  assert_eq(body.enable_thinking, false, "setup dashscope omit thinking still sends enable_thinking")

  local ok_ds_true = pcall(function()
    laler.setup({
      adapter = "openai",
      model = "qwen3.8-flash",
      base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      api_key_env = test_env,
      thinking = true,
    })
  end)
  assert_true(not ok_ds_true, "setup rejects thinking true on dashscope")

  local ok_pad = pcall(function()
    laler.setup({
      adapter = "openai",
      model = "  qwen3.8-flash  ",
      base_url = "  http://127.0.0.1:11434/v1  ",
      api_key_env = "  " .. test_env .. "  ",
    })
  end)
  assert_true(ok_pad, "setup trims padded openai extras")
  assert_eq(laler._config.model, "qwen3.8-flash", "setup stores trimmed model")
  assert_eq(laler._config.base_url, "http://127.0.0.1:11434/v1", "setup stores trimmed base_url")
  assert_eq(laler._config.api_key_env, test_env, "setup stores trimmed api_key_env")
  spec = session._ctx().llm:request("hello")
  assert_eq(spec.env.LALER_OPENAI_URL, "http://127.0.0.1:11434/v1/chat/completions", "setup padded base_url is trimmed")

  local ok_win = pcall(function()
    laler.setup({
      adapter = {
        name = "openai",
        model = "adapter-model",
        base_url = "http://adapter.example/v1",
        api_key_env = test_env,
      },
      model = "top-model",
      base_url = "http://top.example/v1",
      thinking = false,
    })
  end)
  assert_true(ok_win, "setup openai adapter table wins")
  spec = session._ctx().llm:request("x")
  assert_eq(spec.env.LALER_OPENAI_URL, "http://adapter.example/v1/chat/completions", "adapter.base_url wins")
  ok_body, body = pcall(vim.json.decode, spec.stdin)
  assert_true(ok_body and type(body) == "table", "adapter-win stdin JSON")
  assert_eq(body.model, "adapter-model", "adapter.model wins")

  local caller_adapter = {
    name = "openai",
    model = "  keep-padding  ",
    base_url = "  http://caller.example/v1  ",
    api_key_env = test_env,
  }
  local ok_caller = pcall(function()
    laler.setup({ adapter = caller_adapter })
  end)
  assert_true(ok_caller, "setup openai from caller adapter table")
  assert_eq(caller_adapter.model, "  keep-padding  ", "setup does not mutate caller adapter.model")
  assert_eq(caller_adapter.base_url, "  http://caller.example/v1  ", "setup does not mutate caller adapter.base_url")
  spec = session._ctx().llm:request("x")
  assert_eq(spec.env.LALER_OPENAI_URL, "http://caller.example/v1/chat/completions", "setup uses trimmed adapter copy")
  ok_body, body = pcall(vim.json.decode, spec.stdin)
  assert_true(ok_body and type(body) == "table", "caller-adapter stdin JSON")
  assert_eq(body.model, "keep-padding", "setup trims adapter.model on copy")

  vim.env[test_env] = nil
end

-- job generation helper
do
  local job = require("laler.job.vim_system")
  local clear, deliver = job._resolve_exit(1, 2, 2)
  assert_true(not clear, "stale job does not clear newer handle")
  assert_true(not deliver, "stale job does not deliver")
  clear, deliver = job._resolve_exit(2, 2, 2)
  assert_true(clear, "current job clears its handle")
  assert_true(deliver, "current job delivers")
  clear, deliver = job._resolve_exit(1, 2, nil)
  assert_true(not clear, "cancelled job does not clear")
  assert_true(not deliver, "cancelled job does not deliver")
end

-- huge stderr does not fail a successful stdout; huge stdout does
do
  local job = require("laler.job.vim_system")
  local old_max = job.MAX_OUTPUT_BYTES
  job.MAX_OUTPUT_BYTES = 32
  local ok, out, err = job._finalize_output(0, 0, '{"ok":true}', string.rep("e", 100))
  assert_true(ok, "huge stderr does not fail zero-exit")
  assert_eq(out, '{"ok":true}', "stdout kept when only stderr is huge")
  assert_eq(#err, 32, "huge stderr truncated to cap")
  ok, out, err = job._finalize_output(0, 0, string.rep("x", 100), "log")
  assert_true(not ok, "huge stdout fails even with exit 0")
  assert_eq(#out, 32, "huge stdout truncated to cap")
  assert_eq(err, "output too large", "stdout over cap message")
  ok, out, err = job._finalize_output(1, 0, "small", string.rep("e", 100))
  assert_true(not ok, "nonzero exit still fails")
  assert_eq(out, "small", "stdout kept on failed exit")
  assert_eq(#err, 32, "stderr truncated on failed exit")
  ok, out, err = job._finalize_output(0, 0, "small", "log")
  assert_true(ok, "small streams succeed")
  assert_eq(out, "small", "small stdout")
  assert_eq(err, "log", "small stderr")
  job.MAX_OUTPUT_BYTES = old_max
end

-- session ignores stale job callbacks
do
  local session = require("laler.session")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end

  local reviews = {}
  local last_cb
  local view_closed = 0
  local view = {}
  function view:open_loading() end
  function view:show_review(state, cb)
    last_cb = cb
    reviews[#reviews + 1] = state.variants[1].text
  end
  function view:show_error() end
  function view:close()
    view_closed = view_closed + 1
  end

  local apply_ok = true
  local apply = {
    apply = function()
      if not apply_ok then
        return false, "nope"
      end
      return true
    end,
  }

  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = view,
    capture = require("laler.range"),
    apply = apply,
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  local range = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }
  session._start_job(range, "correct")
  session._start_job(range, "correct")
  jobs.cbs[1].on_exit(true, '{"variants":[{"text":"STALE"}]}', "", 0)
  assert_eq(#reviews, 0, "stale callback ignored")
  jobs.cbs[2].on_exit(true, '{"variants":[{"text":"FRESH"}]}', "", 0)
  assert_eq(#reviews, 1, "fresh callback used")
  assert_eq(reviews[1], "FRESH", "fresh text")

  apply_ok = false
  local old_notify = vim.notify
  vim.notify = function() end
  last_cb.on_apply()
  vim.notify = old_notify
  assert_eq(view_closed, 0, "failed apply keeps review UI")
  assert_eq(#reviews, 1, "failed apply does not clear variants")

  local threw = false
  local ok_call, err_call = pcall(session._start_job, {
    bufnr = 999999,
    mode = "char",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 1,
    text = "x",
  }, "correct")
  if not ok_call then
    threw = true
    print("FAIL extra: invalid bufnr threw " .. tostring(err_call))
  end
  assert_true(not threw, "invalid bufnr does not throw")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- session unwrap_stdout before JSON parse
do
  local session = require("laler.session")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end

  local reviews = {}
  local errors = {}
  local view = {}
  function view:open_loading() end
  function view:show_review(state)
    reviews[#reviews + 1] = state.variants[1].text
  end
  function view:show_error(msg)
    errors[#errors + 1] = msg
  end
  function view:close() end

  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "openai",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
      unwrap_stdout = function(_, stdout)
        return require("laler.llm.openai").unwrap_stdout(stdout)
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = view,
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  local range = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }
  session._start_job(range, "correct")
  jobs.cbs[1].on_exit(true, vim.json.encode({
    choices = {
      { message = { content = '{"variants":[{"text":"UNWRAPPED"}]}' } },
    },
  }), "", 0)
  assert_eq(#reviews, 1, "unwrap parse shows review")
  assert_eq(reviews[1], "UNWRAPPED", "unwrap extracts assistant content")

  session._start_job(range, "correct")
  jobs.cbs[2].on_exit(true, '{"error":{"message":"nope"}}', "", 0)
  assert_eq(#errors, 1, "unwrap API error shown")
  assert_eq(errors[1], "nope", "unwrap API error message")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- review <Tab> keymap (optional / best-effort)
do
  local view = require("laler.view.float")
  local diff = require("laler.diff.vim_diff")
  local nop = function() end
  local cb = {
    on_apply = nop,
    on_next = nop,
    on_prev = nop,
    on_jump = nop,
    on_yank = nop,
    on_retry = nop,
    on_cancel = nop,
    on_close = nop,
  }
  local ok_show = pcall(function()
    view:show_review({
      prompt_id = "correct",
      adapter_name = "pi",
      original = "a",
      variants = { { label = "a", text = "b", notes = {} } },
      index = 1,
      diff_doc = diff:diff("a", "b"),
    }, cb)
  end)
  assert_true(ok_show, "show_review for keymap test")
  if ok_show then
    local buf = vim.api.nvim_get_current_buf()
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local has_tab = false
    local has_bare_tab = false
    for _, m in ipairs(maps) do
      if m.lhs == "<Tab>" or m.lhs == "\t" then
        has_tab = true
      end
      if m.lhs == "Tab" then
        has_bare_tab = true
      end
    end
    assert_true(has_tab, "review maps <Tab>")
    assert_true(not has_bare_tab, "review does not map bare Tab")
    pcall(function()
      view:close()
    end)
  end
end

-- prefer last JSON object; skip example placeholder
do
  local parser = require("laler.parse.json")
  local example = [[{"variants":[{"label":"short-name","text":"corrected passage only","notes":["brief learning note"]}]}]]
  local ok, variants = parser:parse(example .. '\n{"variants":[{"text":"Hello there"}]}')
  assert_true(ok, "example then real object parses")
  assert_eq(variants[1].text, "Hello there", "prefers last valid object")

  local fenced = "```json\n" .. example .. "\n```\n" .. '{"variants":[{"text":"Hello there"}]}'
  ok, variants = parser:parse(fenced)
  assert_true(ok, "fenced example then real parses")
  assert_eq(variants[1].text, "Hello there", "placeholder fenced falls back to later object")

  local fenced_valid = '```json\n{"variants":[{"text":"from-fence"}]}\n```\nthinking {"variants":[{"text":"from-object"}]}'
  ok, variants = parser:parse(fenced_valid)
  assert_true(ok, "valid fenced plus later object")
  assert_eq(variants[1].text, "from-fence", "valid fenced wins over later object")

  ok, variants = parser:parse('{"variants":[{"text":"good"},{"text":""}]}')
  assert_true(ok, "skips empty variant")
  assert_eq(#variants, 1, "one valid variant remains")
  assert_eq(variants[1].text, "good", "kept non-empty variant")
end

-- repair extra `}` / duplicate notes from model JSON
do
  local parser = require("laler.parse.json")
  local raw = [[{"variants":[{"label":"conservative","text":"Please set the original GPL v3 as the project's license.","notes":["The sentence is grammatically correct. 'Set...as' is acceptable, though less idiomatic than 'use' or 'adopt' in this context. No changes needed."]},{"label":"native","text":"Please use the original GPL v3 as the project's license.","notes":["'Use' is the most natural verb when talking about applying a license to a project. 'Set' feels more like configuring a setting in software, not choosing a legal license."],"notes":["In software licensing discussions, 'adopt' is a common collocation that sounds slightly more formal and intentional than 'use.' It implies a deliberate decision."]}},{"label":"alternative","text":"Please assign GPL v3 as the project's license.","notes":["'Assign' is widely used in open-source contexts when designating a license for a repository. Dropping 'the original' is natural since GPL v3 already implies the standard version unless stated otherwise."]}]}]]
  local ok, variants = parser:parse(raw)
  assert_true(ok, "repairs extra brace plus duplicate notes")
  assert_eq(#variants, 3, "three variants after repair")
  assert_eq(variants[1].label, "conservative", "conservative label")
  assert_eq(variants[2].label, "native", "native label")
  assert_eq(variants[3].label, "alternative", "alternative label")
  assert_eq(variants[2].text, "Please use the original GPL v3 as the project's license.", "native text")
  assert_eq(#variants[2].notes, 2, "merged duplicate notes keys")
  assert_true(variants[2].notes[1]:find("Use", 1, true) ~= nil, "kept first notes")
  assert_true(variants[2].notes[2]:find("adopt", 1, true) ~= nil, "kept second notes")

  ok, variants = parser:parse(
    '{"variants":[{"label":"a","text":"one"},{"label":"b","text":"two"}},{"label":"c","text":"three"}]}'
  )
  assert_true(ok, "repairs extra brace between variants")
  assert_eq(#variants, 3, "three variants after extra brace")
  assert_eq(variants[3].text, "three", "recovered trailing variant")

  ok, variants = parser:parse('{"variants":[{"text":"hi","notes":["a"],"notes":["b"]}]}')
  assert_true(ok, "merges duplicate notes on valid JSON")
  assert_eq(#variants[1].notes, 2, "both notes kept")
  assert_eq(variants[1].notes[1], "a", "first note")
  assert_eq(variants[1].notes[2], "b", "second note")

  ok, variants = parser:parse('{"label":"a","text":"one"}{"label":"b","text":"two"}')
  assert_true(ok, "salvages concatenated variant objects")
  assert_eq(#variants, 2, "two salvaged variants")
  assert_eq(variants[1].text, "one", "first salvaged text")
  assert_eq(variants[2].text, "two", "second salvaged text")

  ok, variants = parser:parse('{"variants":[{"text":"x","extra":{"n":[1]}},{"text":"y"}]}')
  assert_true(ok, "valid nested ]}},{ is unchanged")
  assert_eq(#variants, 2, "two variants with nested object")
  assert_eq(variants[1].text, "x", "nested extra kept wrapper")
  assert_eq(variants[2].text, "y", "second after nested extra")

  ok, variants = parser:parse('{"variants":[{"text":"foo ]}},{ bar"}]}')
  assert_true(ok, "does not rewrite ]}},{ inside text")
  assert_eq(variants[1].text, "foo ]}},{ bar", "keeps brace sequence in passage")
end

-- combining marks / ZWJ exclusive end
do
  local capture = require("laler.range")
  local acute = vim.fn.nr2char(0x301)
  local comb = "e" .. acute
  assert_eq(capture.utf_exclusive_end(comb, 1), #comb, "combining exclusive end")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { comb })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 0, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "operator combining " .. tostring(err))
  assert_eq(range.text, comb, "operator includes combining mark")

  local family = vim.fn.nr2char(0x1F468)
    .. vim.fn.nr2char(0x200D)
    .. vim.fn.nr2char(0x1F469)
    .. vim.fn.nr2char(0x200D)
    .. vim.fn.nr2char(0x1F467)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { family })
  vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 0, {})
  range, err = capture:from_operator("char")
  assert_true(range ~= nil, "operator zwj " .. tostring(err))
  assert_eq(range.text, family, "operator includes ZWJ family emoji")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- from_visual (still in visual)
do
  local capture = require("laler.range")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcde" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd("normal! 0v2l")
  local range, err = capture:from_visual()
  assert_true(range ~= nil, "from_visual ascii " .. tostring(err))
  assert_eq(range.text, "abc", "visual ascii 0v2l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "привет" })
  vim.cmd("normal! 0v2l")
  range, err = capture:from_visual()
  assert_true(range ~= nil, "from_visual cyrillic " .. tostring(err))
  assert_eq(range.text, "при", "visual cyrillic 0v2l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  vim.cmd("normal! V")
  range, err = capture:from_visual()
  assert_true(range ~= nil, "from_visual linewise " .. tostring(err))
  assert_eq(range.mode, "line", "visual linewise mode")
  assert_eq(range.text, "привет", "visual linewise text")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcde", "fghij" })
  local old_notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  vim.cmd("normal! gg0" .. vim.api.nvim_replace_termcodes("<C-v>j2l", true, false, true))
  range, err = capture:from_visual()
  vim.notify = old_notify
  assert_true(range ~= nil, "from_visual blockwise " .. tostring(err))
  assert_eq(range.mode, "line", "blockwise visual is linewise")
  assert_eq(range.text, "abcde\nfghij", "blockwise visual uses line range")
  assert_true(#msgs > 0, "blockwise fallback notifies")
  assert_true(tostring(msgs[#msgs]):find("blockwise", 1, true) ~= nil, "blockwise notify mentions blockwise")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- apply CRLF
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  local apply = require("laler.apply")
  local ok, err = apply:apply({
    bufnr = buf,
    mode = "char",
    start_row = 0,
    start_col = 4,
    end_row = 0,
    end_col = 7,
    text = "bar",
  }, "qux\r\nquux")
  assert_true(ok, "crlf apply " .. tostring(err))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[1], "foo qux", "crlf first line")
  assert_eq(lines[2], "quux baz", "crlf second line")
  assert_true(not lines[1]:find("\r", 1, true) and not lines[2]:find("\r", 1, true), "no CR left")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- abort apply if captured text diverged
do
  local capture = require("laler.range")
  local apply = require("laler.apply")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for diverge " .. tostring(err))
  assert_eq(range.text, "bar", "captured bar before edit")
  vim.api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, { "BAR" })
  local ok, aerr = apply:apply(range, "qux")
  assert_true(not ok, "diverged apply fails")
  assert_true(type(aerr) == "string", "diverged apply err")
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "foo BAR baz", "edited text preserved")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- retry re-reads from extmarks
do
  local capture = require("laler.range")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for refresh " .. tostring(err))
  -- Edit inside the span. Replacing through the exclusive end collapses it
  -- (end mark right_gravity = false: insert-at-end stays outside).
  vim.api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.start_row, range.start_col + 1, { "B" })
  local ok = capture:refresh_from_marks(range)
  assert_true(ok, "refresh_from_marks")
  assert_eq(range.text, "Bar", "retry re-reads current span")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- catalog / config prompts validation
do
  local catalog = require("laler.prompt.catalog")
  local config = require("laler.config")
  local ok, err = pcall(function()
    catalog.new({ prompts = {} })
  end)
  assert_true(not ok, "empty prompts catalog errors")
  assert_true(tostring(err):find("laler:", 1, true) ~= nil, "empty prompts laler: prefix")

  ok, err = pcall(function()
    catalog.new({ prompts = { { template = "x" } } })
  end)
  assert_true(not ok, "missing id catalog errors")
  assert_true(tostring(err):find("laler:", 1, true) ~= nil, "missing id laler: prefix")

  ok, err = config.validate({ prompts = {} })
  assert_true(not ok, "empty prompts config")
  ok, err = config.validate({ prompts = { { template = "x" } } })
  assert_true(not ok, "missing id config")

  ok, err = pcall(function()
    require("laler").setup({ prompts = {} })
  end)
  assert_true(not ok, "setup empty prompts errors")
  assert_true(tostring(err):find("laler:", 1, true) ~= nil, "setup empty prompts prefix")
end

-- re-setup unmaps previous keys
do
  local laler = require("laler")
  laler._apply_mappings({ run = "ll", pick = "lL", buffer = "la", pick_buffer = "lA" })
  assert_true(vim.fn.maparg("ll", "n") ~= "", "ll mapped")
  assert_true(vim.fn.maparg("la", "n") ~= "", "buffer mapped")
  assert_true(vim.fn.maparg("lA", "n") ~= "", "pick_buffer mapped")
  laler._apply_mappings({ run = "zz" })
  assert_eq(vim.fn.maparg("ll", "n"), "", "old nmap gone after remap")
  assert_true(vim.fn.maparg("zz", "n") ~= "", "zz mapped")
  assert_eq(vim.fn.maparg("lL", "n"), "", "old pick unmapped")
  assert_eq(vim.fn.maparg("la", "n"), "", "old buffer unmapped")
  assert_eq(vim.fn.maparg("lA", "n"), "", "old pick_buffer unmapped")
  laler._apply_mappings({ buffer = "lb", pick_buffer = "lB" })
  assert_true(vim.fn.maparg("lb", "n") ~= "", "buffer remapped")
  assert_true(vim.fn.maparg("lB", "n") ~= "", "pick_buffer remapped")
  laler._apply_mappings(false)
  assert_eq(vim.fn.maparg("zz", "n"), "", "mappings=false unmaps")
  assert_eq(vim.fn.maparg("lb", "n"), "", "mappings=false unmaps buffer")
  assert_eq(vim.fn.maparg("lB", "n"), "", "mappings=false unmaps pick_buffer")
end

-- run_buffer / pick_buffer use whole-buffer line range
do
  local laler = require("laler")
  laler.setup({})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  local session = require("laler.session")
  local orig = session.run_with_range
  local got
  session.run_with_range = function(r)
    got = r
  end
  laler.run_buffer()
  session.run_with_range = orig
  assert_true(got ~= nil, "run_buffer captured")
  assert_eq(got.mode, "line", "run_buffer line mode")
  assert_eq(got.text, "one\ntwo\nthree", "run_buffer whole buffer text")

  local orig_pick = session.pick_and_run
  local picked
  session.pick_and_run = function(r)
    picked = r
  end
  laler.pick_buffer()
  session.pick_and_run = orig_pick
  assert_true(picked ~= nil, "pick_buffer captured")
  assert_eq(picked.mode, "line", "pick_buffer line mode")
  assert_eq(picked.text, "one\ntwo\nthree", "pick_buffer whole buffer text")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- CJK per-char tokens; Cyrillic still groups
do
  local diff = require("laler.diff.vim_diff")
  local zh = diff._tokenize("汉字词")
  assert_true(#zh > 1, "CJK splits into multiple tokens")
  assert_true(#zh >= 3, "each CJK char is a token")
  local cyr = diff._tokenize("привет")
  assert_eq(#cyr, 1, "Cyrillic groups into a word")
end

-- fzf-lua keys by id
do
  local fzf = require("laler.picker.fzf_lua")
  local a = fzf._item_line({ id = "one", label = "Same" })
  local b = fzf._item_line({ id = "two", label = "Same" })
  assert_true(a ~= b, "duplicate labels produce unique lines")
  assert_eq(fzf._id_from_line(a), "one", "parse id one")
  assert_eq(fzf._id_from_line(b), "two", "parse id two")
end

-- session: timeout message, remember after parse
do
  local session = require("laler.session")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end

  local remembered = {}
  local cat = require("laler.prompt.catalog").new({})
  local orig_remember = cat.remember
  function cat:remember(id)
    remembered[#remembered + 1] = id
    orig_remember(self, id)
  end

  local errors = {}
  local view = {}
  function view:open_loading() end
  function view:show_review() end
  function view:show_error(msg)
    errors[#errors + 1] = msg
  end
  function view:close() end

  session.bind({
    config = { language = "en", n_variants = 1, timeout_ms = 5000 },
    catalog = cat,
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = view,
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  local range = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }
  session._start_job(range, "correct")
  assert_eq(#remembered, 0, "not remembered before parse")
  jobs.cbs[#jobs.cbs].on_exit(true, "not json", "", 0)
  assert_eq(#remembered, 0, "not remembered on parse fail")

  session._start_job(range, "formal")
  jobs.cbs[#jobs.cbs].on_exit(true, '{"variants":[{"text":"ok"}]}', "", 0)
  assert_eq(remembered[#remembered], "formal", "remembered after successful parse")

  session._start_job(range, "correct")
  jobs.cbs[#jobs.cbs].on_exit(false, "", "", 124)
  assert_true(#errors > 0, "timeout show_error")
  local last_err = errors[#errors]
  assert_true(last_err:find("timed out", 1, true) ~= nil, "timeout message says timed out")
  assert_true(last_err:find("5000", 1, true) ~= nil, "timeout message includes timeout_ms")

  session._start_job(range, "correct")
  jobs.cbs[#jobs.cbs].on_exit(false, "", "", 0, 9)
  last_err = errors[#errors]
  assert_true(last_err:find("killed by signal", 1, true) ~= nil, "SIGKILL says killed by signal")
  assert_true(last_err:find("9", 1, true) ~= nil, "signal number in message")
  assert_true(last_err:find("timed out", 1, true) == nil, "SIGKILL is not timeout")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- cap raw error dump
do
  local view = require("laler.view.float")
  local nop = function() end
  local cb = {
    on_apply = nop,
    on_next = nop,
    on_prev = nop,
    on_jump = nop,
    on_yank = nop,
    on_retry = nop,
    on_cancel = nop,
    on_close = nop,
  }
  local raw = string.rep("line\n", 250)
  local ok_err = pcall(function()
    view:show_error("boom", raw, cb)
  end)
  assert_true(ok_err, "show_error with huge raw")
  if ok_err then
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert_true(joined:find("truncated", 1, true) ~= nil, "raw dump truncated marker")
    assert_true(#lines < 260, "raw dump line cap")
    pcall(function()
      view:close()
    end)
  end
end

-- preserve variant indent / padding (do not vim.trim passages)
do
  local parser = require("laler.parse.json")
  local ok, variants = parser:parse('{"variants":[{"text":"    Hello world"}]}')
  assert_true(ok, "parses indented variant")
  assert_eq(variants[1].text, "    Hello world", "preserves leading indent")

  ok, variants = parser:parse('{"variants":[{"text":"  hi  "}]}')
  assert_true(ok, "parses padded variant")
  assert_eq(variants[1].text, "  hi  ", "preserves leading and trailing spaces")

  ok, variants = parser:parse('{"variants":[{"text":"\\n    Hello world\\n"}]}')
  assert_true(ok, "parses newline-wrapped indented variant")
  assert_eq(variants[1].text, "    Hello world", "strips wrapping newlines only")

  ok, variants = parser:parse('{"variants":[{"text":"\\n\\nkeep blank\\n\\n"}]}')
  assert_true(ok, "parses double wrapping newlines")
  assert_eq(variants[1].text, "\nkeep blank\n", "strips at most one wrapping newline")
end

-- completion prefix filter
do
  local session = require("laler.session")
  local ids = { "correct", "concise", "formal", "casual" }
  local all = session.filter_prompt_ids(ids, "")
  assert_eq(#all, 4, "empty prefix keeps all")
  local co = session.filter_prompt_ids(ids, "co")
  assert_eq(#co, 2, "co matches two")
  assert_true(vim.tbl_contains(co, "correct"), "co matches correct")
  assert_true(vim.tbl_contains(co, "concise"), "co matches concise")
  assert_true(not vim.tbl_contains(co, "formal"), "co does not match formal")
  local none = session.filter_prompt_ids(ids, "zzz")
  assert_eq(#none, 0, "no match is empty")

  local laler = require("laler")
  laler.setup({})
  local filtered = laler.complete_prompts("for")
  assert_true(vim.tbl_contains(filtered, "formal"), "complete_prompts formal")
  assert_true(not vim.tbl_contains(filtered, "correct"), "complete_prompts prefix")
end

-- missing prompt label defaults to id
do
  local catalog = require("laler.prompt.catalog").new({
    prompts = { { id = "x", template = "t {{text}}" } },
  })
  local p = catalog:get("x")
  assert_true(p ~= nil, "prompt x exists")
  assert_eq(p.label, "x", "label defaults to id")
  local line = require("laler.picker.fzf_lua")._item_line({ id = p.id, label = p.label })
  assert_true(line:find("x", 1, true) ~= nil, "picker line uses id label")
end

-- catalog duplicate ids
do
  local catalog = require("laler.prompt.catalog")
  local ok, err = pcall(function()
    catalog.new({
      prompts = {
        { id = "a", template = "t {{text}}" },
        { id = "a", template = "u {{text}}" },
      },
    })
  end)
  assert_true(not ok, "duplicate prompt id errors")
  assert_true(tostring(err):find("duplicate", 1, true) ~= nil, "duplicate id message")
  assert_true(tostring(err):find("laler:", 1, true) ~= nil, "duplicate id laler: prefix")

  local config = require("laler.config")
  ok, err = config.validate({
    prompts = {
      { id = "a", template = "t {{text}}" },
      { id = "a", template = "u {{text}}" },
    },
  })
  assert_true(not ok, "validate duplicate prompt id")
  assert_true(type(err) == "string" and err:find("duplicate", 1, true) ~= nil, "validate duplicate id message")
end

-- oversize range rejected
do
  local session = require("laler.session")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
    },
  })
  assert_true(session._too_large(string.rep("x", session.MAX_RANGE_BYTES + 1)), "cap helper")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  local old_notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  session.run_with_range({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = string.rep("x", session.MAX_RANGE_BYTES + 1),
  })
  vim.notify = old_notify
  assert_eq(#jobs.cbs, 0, "oversize does not start job")
  assert_true(#msgs > 0 and tostring(msgs[#msgs]):find("too large", 1, true) ~= nil, "oversize notify")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- refuse nomodifiable / readonly before starting the job
do
  local session = require("laler.session")
  local start_n = 0
  local jobs = {}
  function jobs:start()
    start_n = start_n + 1
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].modifiable = false
  local range, err = require("laler.range"):from_command_range(1, 1)
  assert_true(range ~= nil, "capture nomodifiable " .. tostring(err))
  local mark = range.start_mark
  local old_notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  session.run_with_range(range)
  vim.notify = old_notify
  assert_eq(start_n, 0, "nomodifiable does not start job")
  assert_true(#msgs > 0 and tostring(msgs[#msgs]):find("not modifiable", 1, true) ~= nil, "nomodifiable notify")
  assert_eq(range.start_mark, nil, "nomodifiable deletes marks")
  if mark then
    local leftover = vim.api.nvim_buf_get_extmark_by_id(buf, vim.api.nvim_create_namespace("laler_range"), mark, {})
    assert_true(not leftover or #leftover == 0, "nomodifiable removes extmark")
  end

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = true
  range, err = require("laler.range"):from_command_range(1, 1)
  assert_true(range ~= nil, "capture readonly " .. tostring(err))
  start_n = 0
  msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  session.run_with_range(range)
  vim.notify = old_notify
  assert_eq(start_n, 0, "readonly does not start job")
  assert_true(#msgs > 0 and tostring(msgs[#msgs]):find("not modifiable", 1, true) ~= nil, "readonly notify")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- session uses range.cwd for the job spec (retry after float :lcd)
do
  local session = require("laler.session")
  local specs = {}
  local jobs = {}
  function jobs:start(spec)
    specs[#specs + 1] = spec
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  session._start_job({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
    cwd = "/captured/cwd",
  }, "correct")
  assert_eq(#specs, 1, "job started with range.cwd")
  assert_eq(specs[1].cwd, "/captured/cwd", "job spec uses range.cwd")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Hiragana / Katakana / Hangul group; Han stays per-char
do
  local diff = require("laler.diff.vim_diff")
  local hira = diff._tokenize("ひらがな")
  assert_eq(#hira, 1, "hiragana groups into a word")
  local kata = diff._tokenize("カタカナ")
  assert_eq(#kata, 1, "katakana groups into a word")
  local hang = diff._tokenize("한글")
  assert_eq(#hang, 1, "hangul groups into a word")
  local zh = diff._tokenize("汉字词")
  assert_true(#zh >= 3, "each CJK ideograph is a token")
end

-- :'<,'>Laler from char visual is char-wise
do
  local laler = require("laler")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz", "second" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd("normal! 0fbv2l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  assert_eq(vim.fn.visualmode(), "v", "last visual is char")
  local range, err = laler.range_from_command(1, 1, 2)
  assert_true(range ~= nil, "char visual command range " .. tostring(err))
  assert_eq(range.mode, "char", "char visual stays char-wise")
  assert_eq(range.text, "bar", "char visual captures substring not whole line")

  local session = require("laler.session")
  laler.setup({})
  local got
  local orig_run = session.run_with_range
  session.run_with_range = function(r)
    got = r
  end
  laler.run_command(1, 1, nil, 2)
  session.run_with_range = orig_run
  assert_true(got ~= nil, "run_command captured")
  assert_eq(got.text, "bar", "run_command char visual text")
  assert_eq(got.mode, "char", "run_command char visual mode")

  local linewise, lerr = laler.range_from_command(2, 2)
  assert_true(linewise ~= nil, "mismatched lines linewise " .. tostring(lerr))
  assert_eq(linewise.mode, "line", "non-matching lines stay linewise")
  assert_eq(linewise.text, "second", "line 2 text")

  vim.cmd("normal! V")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  local vline, verr = laler.range_from_command(1, 1)
  assert_true(vline ~= nil, "linewise visual command " .. tostring(verr))
  assert_eq(vline.mode, "line", "V stays linewise")
  assert_eq(vline.text, "foo bar baz", "V captures whole line")

  vim.cmd("normal! 0" .. vim.api.nvim_replace_termcodes("<C-v>2l", true, false, true))
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  assert_eq(vim.fn.visualmode(), "\22", "last visual is block")
  local block, berr = laler.range_from_command(1, 1)
  assert_true(block ~= nil, "block visual command range " .. tostring(berr))
  assert_eq(block.mode, "line", "blockwise command is linewise")
  assert_eq(block.text, "foo bar baz", "blockwise command uses line range")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- empty mapping lhs is unset; generic adapter error prefix
do
  local laler = require("laler")
  local ok_map = pcall(function()
    laler._apply_mappings({ run = "", pick = "" })
  end)
  assert_true(ok_map, "empty mapping lhs does not error")
  assert_eq(vim.fn.maparg("", "n"), "", "empty lhs not mapped")

  local ok, err = pcall(function()
    require("laler.llm.generic").new({})
  end)
  assert_true(not ok, "generic requires cmd or build")
  assert_true(tostring(err):find("laler:", 1, true) ~= nil, "generic error laler: prefix")

  ok, err = pcall(function()
    require("laler.llm.generic").new({ cmd = {} }):request("x")
  end)
  assert_true(not ok, "empty cmd table errors")
  assert_true(tostring(err):find("laler:", 1, true) ~= nil, "empty cmd laler: prefix")
end

-- wait(0) is not used to probe cancel; nvim version guard in plugin
do
  local job_src = table.concat(vim.fn.readfile(root .. "/lua/laler/job/vim_system.lua"), "\n")
  assert_true(not job_src:find(":wait(0)", 1, true), "job cancel does not wait(0)")
  assert_true(job_src:find("is_closing", 1, true) ~= nil, "job cancel uses is_closing")
  assert_true(job_src:find('spec.stdin or ""', 1, true) ~= nil, "job stdin defaults to empty")
  local plugin_src = table.concat(vim.fn.readfile(root .. "/plugin/laler.lua"), "\n")
  assert_true(plugin_src:find("nvim%-0%.10", 1) ~= nil, "plugin has nvim-0.10 guard")
end

-- picker cancel deletes marks; confirm refreshes; stale on_choice ignored
do
  local session = require("laler.session")
  local capture = require("laler.range")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  local pick_choice, pick_cancel
  local composed_text
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = {
      compose = function(_, _, ctx)
        composed_text = ctx.text
        return "prompt"
      end,
    },
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = {
      pick = function(_, _, _, on_choice, on_cancel)
        pick_choice = on_choice
        pick_cancel = on_cancel
      end,
    },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = capture,
    apply = {
      apply = function()
        return true
      end,
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for picker cancel " .. tostring(err))
  local mark = range.start_mark
  session.pick_and_run(range)
  assert_true(pick_cancel ~= nil, "picker on_cancel captured")
  pick_cancel()
  assert_eq(range.start_mark, nil, "picker cancel deletes marks")
  if mark then
    local leftover = vim.api.nvim_buf_get_extmark_by_id(buf, vim.api.nvim_create_namespace("laler_range"), mark, {})
    assert_true(not leftover or #leftover == 0, "extmark removed on cancel")
  end

  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for picker confirm " .. tostring(err))
  assert_eq(range.text, "bar", "captured bar before edit")
  vim.api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.start_row, range.start_col + 1, { "B" })
  composed_text = nil
  session.pick_and_run(range)
  pick_choice("correct")
  vim.wait(200, function()
    return composed_text ~= nil
  end)
  assert_eq(composed_text, "Bar", "on_choice refreshes from marks")

  -- stale on_choice after a newer job
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
  local r1 = capture:from_command_range(1, 1)
  local r2 = capture:from_command_range(2, 2)
  composed_text = nil
  session.pick_and_run(r1)
  local stale_choice = pick_choice
  local cbs_before = #jobs.cbs
  session._start_job(r2, "correct")
  assert_eq(#jobs.cbs, cbs_before + 1, "new job started")
  stale_choice("correct")
  vim.wait(50)
  assert_eq(#jobs.cbs, cbs_before + 1, "stale picker on_choice ignored")

  -- replacing active deletes marks on a different range
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
  local a = capture:from_command_range(1, 1)
  local b = capture:from_command_range(2, 2)
  assert_true(a.start_mark ~= nil, "range a has mark")
  session._start_job(a, "correct")
  session._start_job(b, "correct")
  assert_eq(a.start_mark, nil, "previous range marks deleted")
  assert_true(b.start_mark ~= nil, "current range keeps marks")

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- :LalerCancel invalidates a pending picker on_choice
do
  local session = require("laler.session")
  local capture = require("laler.range")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  local pick_choice
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = {
      pick = function(_, _, _, on_choice)
        pick_choice = on_choice
      end,
    },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = capture,
    apply = {
      apply = function()
        return true
      end,
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for cancel pick " .. tostring(err))
  local mark = range.start_mark
  session.pick_and_run(range)
  assert_true(pick_choice ~= nil, "picker on_choice captured")
  local cbs_before = #jobs.cbs
  session.cancel()
  if mark then
    local leftover = vim.api.nvim_buf_get_extmark_by_id(buf, vim.api.nvim_create_namespace("laler_range"), mark, {})
    assert_true(not leftover or #leftover == 0, "cancel deletes pending pick marks")
  end
  pick_choice("correct")
  vim.wait(50)
  assert_eq(#jobs.cbs, cbs_before, "cancel invalidates picker on_choice")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- selection=exclusive after Esc still includes last character
do
  local capture = require("laler.range")
  local laler = require("laler")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcde" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  local old_sel = vim.o.selection
  vim.o.selection = "exclusive"
  vim.cmd("normal! 0v2l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  local a = vim.fn.getpos("'<")
  local b = vim.fn.getpos("'>")
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  local expected = line:sub(a[3], capture.utf_exclusive_end(line, b[3]))
  local range, err = capture:from_visual()
  assert_true(range ~= nil, "exclusive after Esc from_visual " .. tostring(err))
  assert_eq(range.text, expected, "exclusive after Esc includes last mark char")
  assert_true(#range.text >= 1, "exclusive after Esc has text")
  local last_ch = expected:sub(-1)
  assert_eq(range.text:sub(-1), last_ch, "last character kept after Esc")

  local cmd_range, cerr = laler.range_from_command(1, 1, 2)
  assert_true(cmd_range ~= nil, "exclusive after Esc command " .. tostring(cerr))
  assert_eq(cmd_range.text, expected, "exclusive command range includes last char")
  vim.o.selection = old_sel
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- child env unsets NVIM*; adapter env still wins
do
  local job = require("laler.job.vim_system")
  local env = job._child_env({ OPENCODE_PERMISSION = "deny" })
  assert_true(env.NVIM == nil, "NVIM unset")
  assert_true(env.NVIM_LISTEN_ADDRESS == nil, "NVIM_LISTEN_ADDRESS unset")
  assert_eq(env.OPENCODE_PERMISSION, "deny", "adapter env wins")
  local env2 = job._child_env({ NVIM = "custom" })
  assert_eq(env2.NVIM, "custom", "spec.env overrides blank NVIM")
  local env3 = job._child_env({})
  assert_true(env3.NVIM == nil, "_child_env({}) has no NVIM")
  assert_true(env3.NVIM_LISTEN_ADDRESS == nil, "_child_env({}) has no NVIM_LISTEN_ADDRESS")
end

-- compose language/filetype coerced to string
do
  local composer = require("laler.prompt.composer")
  local ok_coerced = pcall(function()
    composer:compose({
      id = "t",
      label = "T",
      template = "Lang={{language}} FT={{filetype}}\n{{text}}",
    }, {
      text = "hello",
      language = {},
      filetype = {},
      n_variants = 3,
    })
  end)
  assert_true(ok_coerced, "non-string language/filetype does not throw")
end

-- multiline notes/labels/errors must not throw
do
  local view = require("laler.view.float")
  local diff = require("laler.diff.vim_diff")
  local nop = function() end
  local cb = {
    on_apply = nop,
    on_next = nop,
    on_prev = nop,
    on_jump = nop,
    on_yank = nop,
    on_retry = nop,
    on_cancel = nop,
    on_close = nop,
  }
  local ok_nl, err_nl = pcall(function()
    view:show_review({
      prompt_id = "correct",
      adapter_name = "pi",
      original = "a",
      variants = { { label = "lab\nel", text = "b", notes = { "line1\nline2" } } },
      index = 1,
      diff_doc = diff:diff("a", "b"),
    }, cb)
  end)
  assert_true(ok_nl, "show_review multiline notes/label " .. tostring(err_nl))
  if ok_nl then
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert_true(joined:find("line1", 1, true) ~= nil, "note line1 present")
    assert_true(joined:find("line2", 1, true) ~= nil, "note line2 present")
    local has_nl = false
    for _, l in ipairs(lines) do
      if l:find("\n", 1, true) or l:find("\r", 1, true) then
        has_nl = true
      end
    end
    assert_true(not has_nl, "review buffer lines have no embedded newlines")
    pcall(function()
      view:close()
    end)
  end
  local ok_err, err_show = pcall(function()
    view:show_error("foo\nbar", nil, cb)
  end)
  assert_true(ok_err, "show_error with newline " .. tostring(err_show))
  if ok_err then
    pcall(function()
      view:close()
    end)
  end
end

-- bare :Laler (range=0) is linewise; range=2 keeps char visual
do
  local laler = require("laler")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd("normal! 0fbv2l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  assert_eq(vim.fn.visualmode(), "v", "leftover visual is char")
  local bare, berr = laler.range_from_command(1, 1, 0)
  assert_true(bare ~= nil, "range=0 captures " .. tostring(berr))
  assert_eq(bare.mode, "line", "range=0 is linewise whole line")
  assert_eq(bare.text, "foo bar baz", "range=0 does not reuse substring")
  local nilrange, nerr = laler.range_from_command(1, 1, nil)
  assert_true(nilrange ~= nil, "nil range captures " .. tostring(nerr))
  assert_eq(nilrange.mode, "line", "nil range is linewise")
  local with2, werr = laler.range_from_command(1, 1, 2)
  assert_true(with2 ~= nil, "range=2 captures " .. tostring(werr))
  assert_eq(with2.mode, "char", "range=2 char-wise still works")
  assert_eq(with2.text, "bar", "range=2 captures substring")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- vim_ui duplicate labels map to the correct id
do
  local ui = require("laler.picker.vim_ui")
  local a = ui._item_line({ id = "one", label = "Same" })
  local b = ui._item_line({ id = "two", label = "Same" })
  assert_true(a ~= b, "duplicate labels produce unique keys")
  assert_eq(ui._id_from_line(a), "one", "vim_ui id one")
  assert_eq(ui._id_from_line(b), "two", "vim_ui id two")

  local orig = vim.ui.select
  local shown
  local select_cb
  vim.ui.select = function(items, _, cb)
    shown = items
    select_cb = cb
  end
  local chosen = {}
  ui:pick({
    { id = "one", label = "Same" },
    { id = "two", label = "Same" },
  }, {}, function(id)
    chosen[#chosen + 1] = id
  end)
  assert_true(shown ~= nil and #shown == 2, "vim_ui select got two items")
  select_cb(shown[2])
  assert_eq(chosen[#chosen], "two", "duplicate label maps to second id")
  select_cb(shown[1])
  assert_eq(chosen[#chosen], "one", "duplicate label maps to first id")
  vim.ui.select = orig
end

-- refuse capture on the review float
do
  local capture = require("laler.range")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "laler"
  vim.bo[buf].buftype = "nofile"
  local r, err = capture:from_command_range(1, 1)
  assert_true(r == nil, "from_command_range refuses laler buf")
  assert_true(type(err) == "string" and err:find("cannot run on the review window", 1, true) ~= nil, "command refuse message")
  r, err = capture:from_visual()
  assert_true(r == nil, "from_visual refuses laler buf")
  assert_true(type(err) == "string" and err:find("cannot run on the review window", 1, true) ~= nil, "visual refuse message")
  r, err = capture:from_operator("char")
  assert_true(r == nil, "from_operator refuses laler buf")
  assert_true(type(err) == "string" and err:find("cannot run on the review window", 1, true) ~= nil, "operator refuse message")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- retry on emptied span stops the session (Apply must not run)
do
  local session = require("laler.session")
  local capture = require("laler.range")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  local last_cb
  local apply_n = 0
  local view = {}
  function view:open_loading() end
  function view:show_review(_, cb)
    last_cb = cb
  end
  function view:show_error() end
  function view:close() end
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = view,
    capture = capture,
    apply = {
      apply = function()
        apply_n = apply_n + 1
        return true
      end,
      normalize_apply_text = require("laler.apply").normalize_apply_text,
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for empty retry " .. tostring(err))
  assert_eq(range.text, "bar", "captured bar")
  session._start_job(range, "correct")
  jobs.cbs[#jobs.cbs].on_exit(true, '{"variants":[{"text":"HELLO"}]}', "", 0)
  assert_true(session._active() ~= nil, "session active after review")
  assert_true(last_cb ~= nil, "review callbacks captured")
  vim.api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, { "" })
  local old_notify = vim.notify
  vim.notify = function() end
  last_cb.on_retry()
  vim.notify = old_notify
  assert_true(session._active() == nil, "empty retry stops session")
  last_cb.on_apply()
  assert_eq(apply_n, 0, "apply does not run after empty retry")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- unknown default_prompt
do
  local catalog = require("laler.prompt.catalog")
  local config = require("laler.config")
  local ok, err = pcall(function()
    catalog.new({ default_prompt = "nope" })
  end)
  assert_true(not ok, "catalog unknown default_prompt errors")
  assert_true(tostring(err):find("unknown default_prompt", 1, true) ~= nil, "catalog unknown default_prompt message")

  ok, err = config.validate({ default_prompt = "nope" })
  assert_true(not ok, "validate unknown default_prompt")
  assert_true(tostring(err):find("unknown default_prompt", 1, true) ~= nil, "validate unknown default_prompt message")

  ok, err = config.validate({ default_prompt = "correct" })
  assert_true(ok, "validate known default_prompt")
end

-- apply.normalize_apply_text shared helper
do
  local apply = require("laler.apply")
  assert_eq(apply.normalize_apply_text("qux\n"), "qux", "normalize strips one trailing nl")
  assert_eq(apply.normalize_apply_text("qux\r\n"), "qux", "normalize strips crlf")
  assert_eq(apply.normalize_apply_text("a\nb\n"), "a\nb", "normalize strips only one trailing")
end

-- re-bind tears down in-flight work
do
  local session = require("laler.session")
  local cancel_n, close_n = 0, 0
  local function stub_ctx()
    return {
      config = { language = "en", n_variants = 1 },
      catalog = require("laler.prompt.catalog").new({}),
      composer = require("laler.prompt.composer"),
      llm = {
        name = "fake",
        request = function()
          return { cmd = "true", args = {}, stdin = "" }
        end,
      },
      jobs = {
        start = function() end,
        cancel = function()
          cancel_n = cancel_n + 1
        end,
        is_running = function()
          return false
        end,
      },
      parser = require("laler.parse.json"),
      picker = { pick = function() end },
      diff = require("laler.diff.vim_diff"),
      view = {
        open_loading = function() end,
        show_review = function() end,
        show_error = function() end,
        close = function()
          close_n = close_n + 1
        end,
      },
      capture = {
        delete_marks = function() end,
      },
      apply = {
        apply = function()
          return true
        end,
      },
    }
  end
  session.bind(stub_ctx())
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  session._start_job({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }, "correct")
  cancel_n, close_n = 0, 0
  session.bind(stub_ctx())
  assert_true(cancel_n >= 1, "rebind cancels job")
  assert_true(close_n >= 1, "rebind closes view")
  assert_true(session._active() == nil, "rebind clears active")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- retry aborts if marks exist and refresh fails; no marks uses stored coords
do
  local session = require("laler.session")
  local capture = require("laler.range")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  local last_cb
  local view = {}
  function view:open_loading() end
  function view:show_review(_, cb)
    last_cb = cb
  end
  function view:show_error() end
  function view:close() end
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = view,
    capture = capture,
    apply = {
      apply = function()
        return true
      end,
      normalize_apply_text = require("laler.apply").normalize_apply_text,
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for gone retry " .. tostring(err))
  session._start_job(range, "correct")
  jobs.cbs[#jobs.cbs].on_exit(true, '{"variants":[{"text":"HELLO"}]}', "", 0)
  assert_true(last_cb ~= nil, "review callbacks for gone retry")
  local ns = vim.api.nvim_create_namespace("laler_range")
  if range.start_mark then
    vim.api.nvim_buf_del_extmark(buf, ns, range.start_mark)
  end
  if range.end_mark then
    vim.api.nvim_buf_del_extmark(buf, ns, range.end_mark)
  end
  local cbs_before = #jobs.cbs
  local old_notify = vim.notify
  local msgs = {}
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  last_cb.on_retry()
  vim.notify = old_notify
  assert_true(session._active() == nil, "gone marks retry stops session")
  assert_eq(#jobs.cbs, cbs_before, "gone marks does not start a job")
  assert_true(tostring(msgs[#msgs] or ""):find("selection is gone", 1, true) ~= nil, "gone marks notify")

  local nomark = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "foo bar baz",
  }
  session._start_job(nomark, "correct")
  jobs.cbs[#jobs.cbs].on_exit(true, '{"variants":[{"text":"HELLO"}]}', "", 0)
  cbs_before = #jobs.cbs
  last_cb.on_retry()
  assert_eq(#jobs.cbs, cbs_before + 1, "retry without marks uses stored coords")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- picker pick() throw runs cancel path
do
  local session = require("laler.session")
  local capture = require("laler.range")
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = {
      start = function() end,
      cancel = function() end,
      is_running = function()
        return false
      end,
    },
    parser = require("laler.parse.json"),
    picker = {
      pick = function()
        error("picker boom")
      end,
    },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = capture,
    apply = {
      apply = function()
        return true
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "capture for picker throw " .. tostring(err))
  local mark = range.start_mark
  local old_notify = vim.notify
  vim.notify = function() end
  local ok_pick = pcall(session.pick_and_run, range)
  vim.notify = old_notify
  assert_true(ok_pick, "pick_and_run does not throw")
  assert_eq(range.start_mark, nil, "picker throw deletes marks")
  if mark then
    local leftover = vim.api.nvim_buf_get_extmark_by_id(buf, vim.api.nvim_create_namespace("laler_range"), mark, {})
    assert_true(not leftover or #leftover == 0, "picker throw removes extmark")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- line-mode exclusive end extmark
do
  local capture = require("laler.range")
  local apply = require("laler.apply")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  local range, err = capture:from_command_range(1, 2)
  assert_true(range ~= nil, "line 1-2 capture " .. tostring(err))
  assert_eq(range.end_row, 1, "stored end_row is inclusive")
  local ns = vim.api.nvim_create_namespace("laler_range")
  local em = vim.api.nvim_buf_get_extmark_by_id(buf, ns, range.end_mark, {})
  assert_eq(em[1], 2, "line end mark on next line")
  assert_eq(em[2], 0, "line end mark col 0")
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "INSERTED" })
  local ok_r = capture:refresh_from_marks(range)
  assert_true(ok_r, "refresh after insert at start of line 2")
  assert_eq(range.text, "one\nINSERTED\ntwo", "exclusive span includes insert between")
  assert_eq(range.end_row, 2, "inclusive end_row after insert")
  local ok, aerr = apply:apply(range, "REPLACED")
  assert_true(ok, "apply exclusive line span " .. tostring(aerr))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(#lines, 2, "two lines remain")
  assert_eq(lines[1], "REPLACED", "replaced exclusive span")
  assert_eq(lines[2], "three", "line after exclusive end kept")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- insert at exclusive end stays outside the span (end mark right_gravity = false)
do
  local capture = require("laler.range")
  local apply = require("laler.apply")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  local range, err = capture:from_command_range(1, 2)
  assert_true(range ~= nil, "line 1-2 for exclusive-end insert " .. tostring(err))
  vim.api.nvim_buf_set_text(buf, 2, 0, 2, 0, { "XXX" })
  local ok_r = capture:refresh_from_marks(range)
  assert_true(ok_r, "refresh after insert at start of three")
  assert_eq(range.text, "one\ntwo", "insert at exclusive end not in span")
  local ok, aerr = apply:apply(range, "REPLACED")
  assert_true(ok, "apply after exclusive-end insert " .. tostring(aerr))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[1], "REPLACED", "replaced lines 1-2")
  assert_true(lines[#lines]:find("three", 1, true) ~= nil, "three remains")
  assert_eq(lines[#lines], "XXXthree", "XXX stays on three")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- char exclusive end: insert after last included char is not swallowed
do
  local capture = require("laler.range")
  local apply = require("laler.apply")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo bar baz" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_mark(buf, "[", 1, 4, {})
  vim.api.nvim_buf_set_mark(buf, "]", 1, 6, {})
  local range, err = capture:from_operator("char")
  assert_true(range ~= nil, "char capture for exclusive-end insert " .. tostring(err))
  assert_eq(range.text, "bar", "captured bar")
  vim.api.nvim_buf_set_text(buf, range.end_row, range.end_col, range.end_row, range.end_col, { "X" })
  local ok_r = capture:refresh_from_marks(range)
  assert_true(ok_r, "refresh after insert at exclusive char end")
  assert_eq(range.text, "bar", "char insert at exclusive end not in span")
  local ok, aerr = apply:apply(range, "qux")
  assert_true(ok, "apply after exclusive char insert " .. tostring(aerr))
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "foo quxX baz", "inserted char not swallowed")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- yank uses normalize_apply_text
do
  local session = require("laler.session")
  local jobs = { cbs = {} }
  function jobs:start(_, cb)
    self.cbs[#self.cbs + 1] = cb
  end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  local last_cb
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = require("laler.prompt.composer"),
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function(_, _, cb)
        last_cb = cb
      end,
      show_error = function() end,
      close = function() end,
    },
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
      normalize_apply_text = require("laler.apply").normalize_apply_text,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  session._start_job({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }, "correct")
  local old_notify = vim.notify
  vim.notify = function() end
  jobs.cbs[#jobs.cbs].on_exit(true, '{"variants":[{"text":"HELLO\\n"}]}', "", 0)
  assert_true(last_cb ~= nil, "yank review callbacks")
  last_cb.on_yank()
  vim.notify = old_notify
  assert_eq(vim.fn.getreg('"'), "HELLO", "yank matches apply text")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- whitespace in prompt ids
do
  local catalog = require("laler.prompt.catalog")
  local config = require("laler.config")
  local ok, err = pcall(function()
    catalog.new({ prompts = { { id = "bad id", template = "x {{text}}" } } })
  end)
  assert_true(not ok, "space in id catalog errors")
  assert_true(tostring(err):find("whitespace", 1, true) ~= nil, "space id catalog message")

  ok, err = pcall(function()
    catalog.new({ prompts = { { id = "bad\tid", template = "x {{text}}" } } })
  end)
  assert_true(not ok, "tab in id catalog errors")

  ok, err = config.validate({ prompts = { { id = "bad id", template = "x" } } })
  assert_true(not ok, "space in id config")
  assert_true(tostring(err):find("whitespace", 1, true) ~= nil, "space id config message")
  ok, err = config.validate({ prompts = { { id = "bad\nid", template = "x" } } })
  assert_true(not ok, "newline in id config")
end

-- generic args copy
do
  local stored = { "-n", "--flag" }
  local client = require("laler.llm.generic").new({ name = "echo", cmd = "echo", args = stored })
  local spec = client:request("x")
  spec.args[1] = "mutated"
  assert_eq(stored[1], "-n", "generic args copy not mutated")
  table.insert(spec.args, "extra")
  assert_eq(#stored, 2, "generic stored args length")
end

-- compose failure shows error and does not throw
do
  local session = require("laler.session")
  local errors = {}
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = {
      compose = function()
        error("compose fail")
      end,
    },
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = {
      start = function() end,
      cancel = function() end,
      is_running = function()
        return false
      end,
    },
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function(_, msg)
        errors[#errors + 1] = msg
      end,
      close = function() end,
    },
    capture = {
      delete_marks = function() end,
    },
    apply = {
      apply = function()
        return true
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  local threw = not pcall(session._start_job, {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }, "correct")
  assert_true(not threw, "compose error does not throw")
  assert_true(#errors > 0, "compose show_error")
  assert_true(session._active() ~= nil, "compose fail keeps active with error UI")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- cursor composed-argv size
do
  local cursor = require("laler.llm.cursor")
  local ok, err = pcall(function()
    cursor:request(string.rep("x", 24001))
  end)
  assert_true(not ok, "huge cursor prompt errors")
  assert_true(tostring(err):find("too large", 1, true) ~= nil, "cursor too large message")
  local ok_small = pcall(function()
    cursor:request("small")
  end)
  assert_true(ok_small, "small cursor prompt ok")
end

-- diff context cap
do
  local diff = require("laler.diff.vim_diff")
  local oldt, newt = {}, {}
  for i = 1, 20 do
    oldt[i] = "line " .. i
    newt[i] = "line " .. i
  end
  newt[20] = "changed"
  local doc = diff:diff(table.concat(oldt, "\n"), table.concat(newt, "\n"))
  local ctx_before = 0
  for _, l in ipairs(doc.lines) do
    if l.kind == "add" or l.kind == "delete" then
      break
    end
    if l.kind == "context" then
      ctx_before = ctx_before + 1
    end
  end
  assert_true(ctx_before <= 3, "at most 3 context lines before hunk")
  assert_true(ctx_before >= 1, "has context before last-line hunk")
  local total_ctx = 0
  for _, l in ipairs(doc.lines) do
    if l.kind == "context" then
      total_ctx = total_ctx + 1
    end
  end
  assert_true(total_ctx < 20, "does not emit all 20 lines as context")
end

-- _start_job cancels in-flight job before compose/request (even if they fail)
do
  local session = require("laler.session")
  local cancel_n, start_n = 0, 0
  local compose_ok, request_ok = true, true
  local errors = {}
  local jobs = {}
  function jobs:start()
    start_n = start_n + 1
  end
  function jobs:cancel()
    cancel_n = cancel_n + 1
  end
  function jobs:is_running()
    return false
  end
  session.bind({
    config = { language = "en", n_variants = 1 },
    catalog = require("laler.prompt.catalog").new({}),
    composer = {
      compose = function(_, prompt, ctx)
        if not compose_ok then
          error("compose fail")
        end
        return require("laler.prompt.composer"):compose(prompt, ctx)
      end,
    },
    llm = {
      name = "fake",
      request = function()
        if not request_ok then
          error("request fail")
        end
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function(_, msg)
        errors[#errors + 1] = msg
      end,
      close = function() end,
    },
    capture = {
      delete_marks = function() end,
    },
    apply = {
      apply = function()
        return true
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  local range = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }
  session._start_job(range, "correct")
  assert_eq(start_n, 1, "first job started")
  local cancel_after_start = cancel_n
  compose_ok = false
  local nerr = #errors
  session._start_job(range, "correct")
  assert_true(cancel_n > cancel_after_start, "compose fail still cancels previous job")
  assert_eq(start_n, 1, "compose fail does not start another job")
  assert_true(#errors > nerr, "compose fail show_error")

  compose_ok = true
  request_ok = true
  session._start_job(range, "correct")
  assert_eq(start_n, 2, "job started after compose recovered")
  cancel_after_start = cancel_n
  request_ok = false
  nerr = #errors
  session._start_job(range, "correct")
  assert_true(cancel_n > cancel_after_start, "request fail still cancels previous job")
  assert_eq(start_n, 2, "request fail does not start another job")
  assert_true(#errors > nerr, "request fail show_error")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- omitted stdin defaults to empty string (does not hang on fd 0)
do
  local job = require("laler.job.vim_system")
  local done, ok_exit, code_exit = false, nil, nil
  job:cancel()
  job:start({ cmd = "cat", args = {} }, {
    on_exit = function(ok, _, _, code)
      done = true
      ok_exit = ok
      code_exit = code
    end,
  }, { timeout_ms = 5000 })
  vim.wait(1500, function()
    return done
  end)
  assert_true(done, "omitted stdin does not hang cat")
  assert_true(ok_exit, "cat with empty stdin succeeds")
  assert_eq(code_exit, 0, "cat exit 0")
  job:cancel()
end

-- rebind keeps request_gen monotonic (stale callback cannot collide)
do
  local session = require("laler.session")
  local function make_jobs()
    local jobs = { cbs = {} }
    function jobs:start(_, cb)
      self.cbs[#self.cbs + 1] = cb
    end
    function jobs:cancel() end
    function jobs:is_running()
      return false
    end
    return jobs
  end
  local function make_ctx(jobs, reviews)
    return {
      config = { language = "en", n_variants = 1 },
      catalog = require("laler.prompt.catalog").new({}),
      composer = require("laler.prompt.composer"),
      llm = {
        name = "fake",
        request = function()
          return { cmd = "true", args = {}, stdin = "" }
        end,
      },
      jobs = jobs,
      parser = require("laler.parse.json"),
      picker = { pick = function() end },
      diff = require("laler.diff.vim_diff"),
      view = {
        open_loading = function() end,
        show_review = function(_, state)
          reviews[#reviews + 1] = state.variants[1].text
        end,
        show_error = function() end,
        close = function() end,
      },
      capture = {
        delete_marks = function() end,
      },
      apply = {
        apply = function()
          return true
        end,
      },
    }
  end
  local jobs1, reviews1 = make_jobs(), {}
  session.bind(make_ctx(jobs1, reviews1))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  local range = {
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }
  session._start_job(range, "correct")
  local jobs2, reviews2 = make_jobs(), {}
  session.bind(make_ctx(jobs2, reviews2))
  session._start_job(range, "correct")
  jobs1.cbs[1].on_exit(true, '{"variants":[{"text":"STALE"}]}', "", 0)
  assert_eq(#reviews1, 0, "stale callback after rebind ignored")
  assert_eq(#reviews2, 0, "stale does not land on new view")
  jobs2.cbs[1].on_exit(true, '{"variants":[{"text":"FRESH"}]}', "", 0)
  assert_eq(#reviews2, 1, "fresh callback after rebind used")
  assert_eq(reviews2[1], "FRESH", "fresh text after rebind")
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- prompt n_variants overrides global; catalog map merge / list replace
do
  local composer = require("laler.prompt.composer")
  local catalog_mod = require("laler.prompt.catalog")
  local config = require("laler.config")

  local out = composer:compose(catalog_mod.new({}):get("correct"), {
    text = "hi",
    language = "en",
    filetype = "",
    n_variants = 1,
  })
  assert_true(out:find("1. conservative", 1, true) ~= nil, "n=1 has conservative")
  assert_true(out:find("2. native", 1, true) == nil, "n=1 has no native")
  assert_true(out:find("exactly 1 variant when possible", 1, true) ~= nil, "preamble singular variant")
  assert_true(out:find("exactly 1 variants", 1, true) == nil, "preamble not plural for n=1")
  assert_true(out:find("Provide 1 corrected variant:", 1, true) ~= nil, "correct body singular n=1")
  assert_true(out:find("1 corrected variants", 1, true) == nil, "correct body not plural for n=1")
  assert_true(out:find(",\n    ...", 1, true) == nil, "n=1 JSON sketch has no extra-item ellipsis")

  local ctx_omit = { text = "hi", language = "en", filetype = "" }
  local from_prompt = composer:compose({
    id = "x",
    template = "N={{n_variants}}\n{{text}}",
    n_variants = 1,
  }, ctx_omit)
  assert_true(from_prompt:find("N=1", 1, true) ~= nil, "compose uses prompt.n_variants when ctx omits it")
  assert_true(from_prompt:find("exactly 1 variant when possible", 1, true) ~= nil, "prompt n_variants singular preamble")
  assert_true(from_prompt:find(",\n    ...", 1, true) == nil, "prompt n_variants n=1 sketch has no ellipsis")
  local ctx_wins = composer:compose({
    id = "x",
    template = "N={{n_variants}}\n{{text}}",
    n_variants = 1,
  }, { text = "hi", language = "en", filetype = "", n_variants = 3 })
  assert_true(ctx_wins:find("N=3", 1, true) ~= nil, "ctx.n_variants wins over prompt.n_variants")
  local from_default = composer:compose({
    id = "x",
    template = "N={{n_variants}}\n{{text}}",
  }, ctx_omit)
  assert_true(from_default:find("N=3", 1, true) ~= nil, "compose defaults n_variants to 3")

  local ctx1 = { text = "hi", language = "en", filetype = "", n_variants = 1 }
  local ctx3 = { text = "hi", language = "en", filetype = "", n_variants = 3 }
  local builtins = catalog_mod.new({})
  for _, id in ipairs({ "formal", "casual", "concise" }) do
    local one = composer:compose(builtins:get(id), ctx1)
    assert_true(one:find("Provide 1 variant:", 1, true) ~= nil, id .. " body singular n=1")
    assert_true(one:find("1 variants", 1, true) == nil, id .. " body not plural for n=1")
    assert_true(one:find("etc.", 1, true) == nil, id .. " n=1 has no etc.")
    assert_true(one:find(id .. "-1", 1, true) ~= nil, id .. " n=1 has " .. id .. "-1")
    assert_true(one:find(id .. "-2", 1, true) == nil, id .. " n=1 has no " .. id .. "-2")
    assert_true(one:find("1. conservative", 1, true) == nil, id .. " n=1 does not use correct labels")
    local many = composer:compose(builtins:get(id), ctx3)
    assert_true(many:find("Provide 3 variants:", 1, true) ~= nil, id .. " body plural n=3")
    assert_true(many:find("Provide 3 variant:", 1, true) == nil, id .. " body not singular for n=3")
    assert_true(many:find("etc.", 1, true) == nil, id .. " n=3 has no etc.")
    assert_true(many:find(id .. "-1", 1, true) ~= nil, id .. " n=3 has " .. id .. "-1")
    assert_true(many:find(id .. "-2", 1, true) ~= nil, id .. " n=3 has " .. id .. "-2")
    assert_true(many:find(id .. "-3", 1, true) ~= nil, id .. " n=3 has " .. id .. "-3")
    assert_true(many:find(id .. "-4", 1, true) == nil, id .. " n=3 has no " .. id .. "-4")
    assert_true(many:find("1. conservative", 1, true) == nil, id .. " n=3 does not use correct labels")
  end

  local custom_list = composer:compose({
    id = "plain",
    template = "List:\n{{variant_list}}\n{{text}}",
  }, ctx3)
  assert_true(custom_list:find('1. plain-1 (label: "plain-1")', 1, true) ~= nil, "custom variant_list uses id-1")
  assert_true(custom_list:find("plain-3", 1, true) ~= nil, "custom variant_list uses id-n")
  assert_true(custom_list:find("plain-4", 1, true) == nil, "custom variant_list stops at n")
  assert_true(custom_list:find("1. conservative", 1, true) == nil, "custom variant_list not correct specs")
  local correct_named = composer:compose(builtins:get("correct"), ctx3)
  assert_true(correct_named:find("1. conservative", 1, true) ~= nil, "correct n=3 keeps conservative")
  assert_true(correct_named:find("correct-1", 1, true) == nil, "correct does not use id-n labels")

  local overlay_n1 = catalog_mod.new({
    prompts = { correct = { n_variants = 1 } },
  })
  local overlay_out = composer:compose(overlay_n1:get("correct"), {
    text = "hi",
    language = "en",
    filetype = "",
    n_variants = overlay_n1:get("correct").n_variants,
  })
  assert_true(overlay_out:find("Provide 1 corrected variant:", 1, true) ~= nil, "overlay n=1 correct body singular")
  assert_true(overlay_out:find("1 corrected variants", 1, true) == nil, "overlay n=1 correct body not plural")
  assert_true(overlay_out:find("exactly 1 variant when possible", 1, true) ~= nil, "overlay n=1 preamble singular")

  local merged = catalog_mod.new({
    prompts = {
      conservative = {
        label = "Conservative",
        template = "Conservative correction.\n{{text}}",
        n_variants = 1,
      },
      zebra = { template = "Z {{text}}" },
      apple = { template = "A {{text}}" },
    },
    default_prompt = "conservative",
  })
  assert_true(merged:get("correct") ~= nil, "map merge keeps builtin correct")
  assert_true(merged:get("formal") ~= nil, "map merge keeps builtin formal")
  assert_true(merged:get("conservative") ~= nil, "map merge adds conservative")
  assert_eq(merged:get("conservative").n_variants, 1, "merged prompt keeps n_variants")
  assert_eq(merged:default_id(), "conservative", "default_prompt extra id")
  local ids = {}
  for _, p in ipairs(merged:list()) do
    ids[#ids + 1] = p.id
  end
  assert_eq(ids[1], "correct", "builtins stay first")
  local apple_i, zebra_i
  for i, id in ipairs(ids) do
    if id == "apple" then
      apple_i = i
    end
    if id == "zebra" then
      zebra_i = i
    end
  end
  assert_true(apple_i ~= nil and zebra_i ~= nil, "extras present")
  assert_true(apple_i < zebra_i, "new map ids appended sorted")

  local overridden = catalog_mod.new({
    prompts = {
      correct = { label = "Correct+", template = "override {{text}}" },
    },
  })
  assert_eq(overridden:get("correct").template, "override {{text}}", "map overrides builtin")
  assert_eq(overridden:list()[1].id, "correct", "override keeps builtin position")
  assert_true(overridden:get("casual") ~= nil, "override still has other builtins")
  assert_eq(
    overridden:get("correct").description,
    "Grammar + native-speaker fluency",
    "template overlay keeps builtin description"
  )

  local partial = catalog_mod.new({
    prompts = { correct = { n_variants = 1 } },
  })
  local builtin_correct
  for _, p in ipairs(catalog_mod.builtin()) do
    if p.id == "correct" then
      builtin_correct = p
      break
    end
  end
  assert_true(builtin_correct ~= nil, "found builtin correct")
  assert_eq(partial:get("correct").n_variants, 1, "partial overlay sets n_variants")
  assert_eq(partial:get("correct").label, "Correct", "partial overlay keeps builtin label")
  assert_eq(
    partial:get("correct").description,
    "Grammar + native-speaker fluency",
    "partial overlay keeps builtin description"
  )
  assert_eq(partial:get("correct").template, builtin_correct.template, "partial overlay keeps builtin template")

  local tmpl_only = catalog_mod.new({
    prompts = { concise = { template = "short {{text}}" } },
  })
  assert_eq(tmpl_only:get("concise").template, "short {{text}}", "template-only overlay")
  assert_eq(tmpl_only:get("concise").label, "Concise", "template-only overlay keeps builtin label")
  assert_eq(tmpl_only:get("concise").description, "Shorter and clearer", "template-only overlay keeps builtin description")

  local replaced = catalog_mod.new({
    prompts = { { id = "only", template = "t {{text}}" } },
  })
  assert_true(replaced:get("only") ~= nil, "list replace has only")
  assert_true(replaced:get("correct") == nil, "list replace drops builtins")

  local ok, err = pcall(function()
    catalog_mod.new({
      prompts = { { id = "x", template = "t {{text}}", n_variants = 0 } },
    })
  end)
  assert_true(not ok, "catalog rejects prompt n_variants 0")
  assert_true(tostring(err):find("n_variants", 1, true) ~= nil, "catalog n_variants message")

  ok, err = config.validate({
    prompts = { { id = "x", template = "t {{text}}", n_variants = 10 } },
  })
  assert_true(not ok, "validate rejects prompt n_variants 10")
  assert_true(type(err) == "string" and err:find("n_variants", 1, true) ~= nil, "validate prompt n_variants message")

  ok, err = config.validate({
    prompts = {
      conservative = { template = "t {{text}}", n_variants = 1 },
    },
    default_prompt = "conservative",
  })
  assert_true(ok, "validate map extra default_prompt")

  ok, err = config.validate({
    prompts = {
      conservative = { template = "t {{text}}", n_variants = 1 },
    },
    default_prompt = "correct",
  })
  assert_true(ok, "validate map keeps builtin default_prompt")

  ok, err = config.validate({
    prompts = { { id = "only", template = "t {{text}}" } },
    default_prompt = "correct",
  })
  assert_true(not ok, "validate list replace unknown default_prompt")

  ok, err = config.validate({
    prompts = { correct = { n_variants = 1 } },
  })
  assert_true(ok, "validate partial overlay n_variants")

  ok, err = config.validate({
    prompts = { newbie = { n_variants = 1 } },
  })
  assert_true(not ok, "validate new map id requires template")
  assert_true(type(err) == "string" and err:find("template", 1, true) ~= nil, "validate new id template message")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { newbie = { n_variants = 1 } },
    })
  end)
  assert_true(not ok, "catalog new map id requires template")
  assert_true(tostring(err):find("template", 1, true) ~= nil, "catalog new id template message")

  ok, err = config.validate({
    prompts = { { id = "x", template = "t {{text}}", n_variants = 1.5 } },
  })
  assert_true(not ok, "validate rejects prompt n_variants 1.5")
  assert_true(type(err) == "string" and err:find("n_variants", 1, true) ~= nil, "validate prompt n_variants 1.5 message")

  ok, err = config.validate({
    prompts = { correct = { n_variants = 1.5 } },
  })
  assert_true(not ok, "validate rejects overlay n_variants 1.5")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { correct = { n_variants = 1.5 } },
    })
  end)
  assert_true(not ok, "catalog rejects overlay n_variants 1.5")
  assert_true(tostring(err):find("n_variants", 1, true) ~= nil, "catalog overlay n_variants 1.5 message")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { correct = { id = "foo", template = "t {{text}}" } },
    })
  end)
  assert_true(not ok, "catalog rejects map key vs id mismatch")
  assert_true(tostring(err):find("must match id", 1, true) ~= nil, "catalog mismatch message")

  ok, err = config.validate({
    prompts = { correct = { id = "foo", template = "t {{text}}" } },
  })
  assert_true(not ok, "validate rejects map key vs id mismatch")
  assert_true(type(err) == "string" and err:find("must match id", 1, true) ~= nil, "validate mismatch message")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = {
        a = { id = "same", template = "t {{text}}" },
        b = { id = "same", template = "u {{text}}" },
      },
    })
  end)
  assert_true(not ok, "catalog rejects two map keys resolving to same id")
  assert_true(
    tostring(err):find("must match id", 1, true) ~= nil or tostring(err):find("duplicate", 1, true) ~= nil,
    "catalog two-key same id message"
  )

  ok, err = config.validate({
    prompts = {
      a = { id = "same", template = "t {{text}}" },
      b = { id = "same", template = "u {{text}}" },
    },
  })
  assert_true(not ok, "validate rejects two map keys resolving to same id")
  assert_true(
    type(err) == "string" and (err:find("must match id", 1, true) ~= nil or err:find("duplicate", 1, true) ~= nil),
    "validate two-key same id message"
  )

  ok, err = config.validate({
    prompts = { correct = { description = { "x" } } },
  })
  assert_true(not ok, "validate rejects table description")
  assert_true(type(err) == "string" and err:find("description", 1, true) ~= nil, "validate description type message")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { correct = { description = { "x" } } },
    })
  end)
  assert_true(not ok, "catalog rejects table description")
  assert_true(tostring(err):find("description", 1, true) ~= nil, "catalog description type message")

  ok, err = config.validate({
    prompts = { correct = { label = 1 } },
  })
  assert_true(not ok, "validate rejects numeric label")
  assert_true(type(err) == "string" and err:find("label", 1, true) ~= nil, "validate label type message")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { correct = { label = 1 } },
    })
  end)
  assert_true(not ok, "catalog rejects numeric label")
  assert_true(tostring(err):find("label", 1, true) ~= nil, "catalog label type message")

  ok, err = config.validate({
    prompts = { { id = "x", template = "t {{text}}", label = true } },
  })
  assert_true(not ok, "validate list rejects boolean label")

  ok, err = config.validate({
    prompts = { newbie = { template = "no placeholder" } },
  })
  assert_true(not ok, "validate new template requires {{text}}")
  assert_true(type(err) == "string" and err:find("{{text}}", 1, true) ~= nil, "validate {{text}} message")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { newbie = { template = "no placeholder" } },
    })
  end)
  assert_true(not ok, "catalog new template requires {{text}}")
  assert_true(tostring(err):find("{{text}}", 1, true) ~= nil, "catalog {{text}} message")

  ok, err = config.validate({
    prompts = { correct = { template = "override without passage" } },
  })
  assert_true(not ok, "validate overlay template requires {{text}}")

  ok, err = pcall(function()
    catalog_mod.new({
      prompts = { correct = { template = "override without passage" } },
    })
  end)
  assert_true(not ok, "catalog overlay template requires {{text}}")
  assert_true(tostring(err):find("{{text}}", 1, true) ~= nil, "catalog overlay {{text}} message")

  ok, err = config.validate({
    prompts = { { id = "x", template = "hello" } },
  })
  assert_true(not ok, "validate list template requires {{text}}")

  ok, err = config.validate({
    prompts = { correct = { n_variants = 1 } },
  })
  assert_true(ok, "validate overlay omitting template still ok after {{text}} rule")

  local util = require("laler.util")
  assert_true(util.is_list({}), "empty table is a list")
  assert_true(util.is_list({ { id = "a" } }), "array of prompts is a list")
  assert_true(not util.is_list({ correct = { n_variants = 1 } }), "prompt map is not a list")
  assert_true(not util.is_list({ { id = "a" }, extra = true }), "mixed table is not a list")
  assert_true(not util.is_list({ [2] = { id = "a" } }), "hole is not a list")
  assert_true(not util.is_list("x"), "string is not a list")

  local session = require("laler.session")
  local got_n
  local jobs = {}
  function jobs:start() end
  function jobs:cancel() end
  function jobs:is_running()
    return false
  end
  session.bind({
    config = { language = "en", n_variants = 3 },
    catalog = catalog_mod.new({
      prompts = {
        { id = "fast", template = "t {{text}}", n_variants = 1 },
        { id = "slow", template = "t {{text}}" },
      },
    }),
    composer = {
      compose = function(_, _, ctx)
        got_n = ctx.n_variants
        return "composed"
      end,
    },
    llm = {
      name = "fake",
      request = function()
        return { cmd = "true", args = {}, stdin = "" }
      end,
    },
    jobs = jobs,
    parser = require("laler.parse.json"),
    picker = { pick = function() end },
    diff = require("laler.diff.vim_diff"),
    view = {
      open_loading = function() end,
      show_review = function() end,
      show_error = function() end,
      close = function() end,
    },
    capture = require("laler.range"),
    apply = {
      apply = function()
        return true
      end,
    },
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  session._start_job({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }, "fast")
  assert_eq(got_n, 1, "session uses prompt n_variants over global")
  session._start_job({
    bufnr = buf,
    mode = "line",
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 0,
    text = "hello",
  }, "slow")
  assert_eq(got_n, 3, "session uses global n_variants when prompt omits it")
  vim.api.nvim_buf_delete(buf, { force = true })
end

print(string.format("laler tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
