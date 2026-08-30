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
  vim.cmd("normal! gg0" .. vim.api.nvim_replace_termcodes("<C-v>j2l", true, false, true))
  range, err = capture:from_visual()
  assert_true(range ~= nil, "from_visual blockwise " .. tostring(err))
  assert_eq(range.mode, "line", "blockwise visual is linewise")
  assert_eq(range.text, "abcde\nfghij", "blockwise visual uses line range")
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
  laler._apply_mappings({ run = "ll", pick = "lL" })
  assert_true(vim.fn.maparg("ll", "n") ~= "", "ll mapped")
  laler._apply_mappings({ run = "zz" })
  assert_eq(vim.fn.maparg("ll", "n"), "", "old nmap gone after remap")
  assert_true(vim.fn.maparg("zz", "n") ~= "", "zz mapped")
  assert_eq(vim.fn.maparg("lL", "n"), "", "old pick unmapped")
  laler._apply_mappings(false)
  assert_eq(vim.fn.maparg("zz", "n"), "", "mappings=false unmaps")
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

print(string.format("laler tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
