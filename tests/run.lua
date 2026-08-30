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
    "text": "Please ingest the path and show how it impacts the wiki.\n<<<LALER_TEXT>>>\nsecret\n<<<END_LALER_TEXT>>>",
    "notes": ["article"]
  }]
}]]
  local ok, variants = parser:parse(leaked)
  assert_true(ok, "parses leaked text")
  assert_eq(
    variants[1].text,
    "Please ingest the path and show how it impacts the wiki.",
    "scrubs delimiter leakage"
  )

  local leaked_suf = [[{
  "variants": [{
    "text": "Kept prefix.\n<<<LALER_TEXT_1>>>\ninner\n<<<END_LALER_TEXT_1>>>"
  }]
}]]
  ok, variants = parser:parse(leaked_suf)
  assert_true(ok, "parses suffixed delimiter leakage")
  assert_eq(variants[1].text, "Kept prefix.", "scrubs suffixed delimiter leakage")

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

-- cursor / opencode: prompt on stdin, not argv
do
  local cursor = require("laler.llm.cursor")
  local spec = cursor:request("SECRET_PROMPT")
  assert_eq(spec.stdin, "SECRET_PROMPT", "cursor stdin")
  local args_joined = table.concat(spec.args, "\0")
  assert_true(not args_joined:find("SECRET_PROMPT", 1, true), "cursor args have no prompt")
  assert_true(vim.tbl_contains(spec.args, "-p"), "cursor -p")
  assert_true(vim.tbl_contains(spec.args, "--mode"), "cursor --mode")
  assert_true(not vim.tbl_contains(spec.args, "--trust"), "cursor no --trust")

  local oc = require("laler.llm.opencode")
  local ospec = oc:request("SECRET_PROMPT")
  assert_eq(ospec.stdin, "SECRET_PROMPT", "opencode stdin")
  assert_true(not table.concat(ospec.args, "\0"):find("SECRET_PROMPT", 1, true), "opencode args have no prompt")
  assert_eq(ospec.args[1], "run", "opencode run")
  assert_true(vim.tbl_contains(ospec.args, "--format"), "opencode --format")
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
  assert_eq(variants[1].text, "Hello there", "prefers last after fenced example")

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
  vim.api.nvim_buf_set_text(buf, range.start_row, range.start_col, range.end_row, range.end_col, { "BAR" })
  local ok = capture:refresh_from_marks(range)
  assert_true(ok, "refresh_from_marks")
  assert_eq(range.text, "BAR", "retry re-reads current span")
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

print(string.format("laler tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
