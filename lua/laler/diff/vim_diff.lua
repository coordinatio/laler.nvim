---@implements laler.DiffEngine
local M = {}

---@param a string
---@param b string
---@param opts table
---@return any
local function nvim_diff(a, b, opts)
  if vim.text and vim.text.diff then
    return vim.text.diff(a, b, opts)
  end
  return vim.diff(a, b, opts)
end

---@param s string
---@return string[]
local function split_lines(s)
  if s == "" then
    return {}
  end
  return vim.split(s, "\n", { plain = true })
end

---@param ch string single UTF-8 character
---@return boolean
local function is_combining(ch)
  local ok1, skip = pcall(vim.fn.strchars, "a" .. ch, true)
  local ok2, noskip = pcall(vim.fn.strchars, "a" .. ch, false)
  return ok1 and ok2 and skip == 1 and noskip > 1
end

---@param ch string single UTF-8 character
---@return boolean
local function is_kana_or_hangul(ch)
  local cp = vim.fn.char2nr(ch)
  -- Hiragana
  if cp >= 0x3040 and cp <= 0x309F then
    return true
  end
  -- Katakana + phonetic extensions
  if cp >= 0x30A0 and cp <= 0x30FF then
    return true
  end
  if cp >= 0x31F0 and cp <= 0x31FF then
    return true
  end
  -- Halfwidth Katakana
  if cp >= 0xFF65 and cp <= 0xFF9F then
    return true
  end
  -- Hangul Jamo / Compatibility Jamo / syllables / Extended-A/B
  if cp >= 0x1100 and cp <= 0x11FF then
    return true
  end
  if cp >= 0x3130 and cp <= 0x318F then
    return true
  end
  if cp >= 0xA960 and cp <= 0xA97F then
    return true
  end
  if cp >= 0xAC00 and cp <= 0xD7AF then
    return true
  end
  if cp >= 0xD7B0 and cp <= 0xD7FF then
    return true
  end
  return false
end

---@param ch string single UTF-8 character
---@return boolean
local function is_cjk_char(ch)
  local b = string.byte(ch, 1)
  if b and b < 128 then
    return false
  end
  if is_kana_or_hangul(ch) then
    return false
  end
  local cc = vim.fn.charclass(ch)
  -- 0 blank, 1 punctuation, 2 keyword, 3 emoji; >3 = specific Unicode class (Han/CJK)
  return type(cc) == "number" and cc > 3
end

---@param ch string single UTF-8 character
---@return boolean
local function is_word_char(ch)
  if ch == "_" or ch == "'" then
    return true
  end
  local b = string.byte(ch, 1)
  if b and b < 128 then
    return ch:match("^[%w]$") ~= nil
  end
  if is_combining(ch) then
    return true
  end
  if is_kana_or_hangul(ch) then
    return true
  end
  local cc = vim.fn.charclass(ch)
  -- Keyword class groups Latin/Cyrillic/etc. Han/CJK is handled per-character.
  return cc == 2
end

--- Tokenize into words and separators (punctuation / whitespace runs kept).
---@param line string
---@return string[]
local function tokenize(line)
  local tokens = {}
  if line == "" then
    return tokens
  end
  local positions = vim.str_utf_pos(line)
  if not positions or #positions == 0 then
    return { line }
  end

  local function char_at(byte_idx)
    return line:sub(byte_idx, byte_idx + vim.str_utf_end(line, byte_idx))
  end

  local i = 1
  local n = #positions
  while i <= n do
    local start_byte = positions[i]
    local ch = char_at(start_byte)
    if is_cjk_char(ch) then
      -- Each CJK character is its own word token (plus following combining marks).
      local j = i + 1
      while j <= n and is_combining(char_at(positions[j])) do
        j = j + 1
      end
      local last_byte = positions[j - 1]
      local end_byte = last_byte + vim.str_utf_end(line, last_byte)
      tokens[#tokens + 1] = line:sub(start_byte, end_byte)
      i = j
    else
      local word = is_word_char(ch)
      local j = i + 1
      while j <= n do
        local nj = char_at(positions[j])
        if is_cjk_char(nj) or is_word_char(nj) ~= word then
          break
        end
        j = j + 1
      end
      local last_byte = positions[j - 1]
      local end_byte = last_byte + vim.str_utf_end(line, last_byte)
      tokens[#tokens + 1] = line:sub(start_byte, end_byte)
      i = j
    end
  end
  return tokens
end

M._tokenize = tokenize

---@param a string[]
---@param b string[]
---@return table[] indices from vim.diff style for sequences
local function seq_diff_indices(a, b)
  -- Use string keys joined uniquely? vim.diff works on strings (lines).
  -- Encode tokens as lines temporarily.
  local a_s = table.concat(a, "\n")
  local b_s = table.concat(b, "\n")
  if a_s == b_s then
    return {}
  end
  local indices = nvim_diff(a_s, b_s, {
    result_type = "indices",
    algorithm = "histogram",
  })
  return indices or {}
end

---@param old_line string
---@param new_line string
---@param delete_line_idx integer 1-based in DiffDoc.lines
---@param add_line_idx integer
---@param word_spans laler.WordSpan[]
local function add_word_spans(old_line, new_line, delete_line_idx, add_line_idx, word_spans)
  local ot = tokenize(old_line)
  local nt = tokenize(new_line)
  local hunks = seq_diff_indices(ot, nt)

  -- Build cumulative byte offsets for tokens
  local function offsets(tokens)
    local offs = {}
    local col = 0
    for i, t in ipairs(tokens) do
      offs[i] = col
      col = col + #t
    end
    offs[#tokens + 1] = col
    return offs
  end

  local o_off = offsets(ot)
  local n_off = offsets(nt)

  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    if count_a > 0 then
      local col_start = o_off[start_a] or 0
      local col_end = o_off[start_a + count_a] or #old_line
      word_spans[#word_spans + 1] = {
        line = delete_line_idx,
        col_start = col_start,
        col_end = col_end,
        kind = "delete",
      }
    end
    if count_b > 0 then
      local col_start = n_off[start_b] or 0
      local col_end = n_off[start_b + count_b] or #new_line
      word_spans[#word_spans + 1] = {
        line = add_line_idx,
        col_start = col_start,
        col_end = col_end,
        kind = "add",
      }
    end
  end
end

--- First line index of a hunk (1-based). When count==0, `start` is the
--- insertion point (line after which to insert; 0 = beginning).
---@param start integer
---@param count integer
---@return integer
local function hunk_line_start(start, count)
  if count == 0 then
    return start + 1
  end
  return start
end

---@param original string
---@param variant string
---@return laler.DiffDoc
function M:diff(original, variant)
  local old_lines = split_lines(original)
  local new_lines = split_lines(variant)

  local old_s = table.concat(old_lines, "\n")
  local new_s = table.concat(new_lines, "\n")

  ---@type laler.DiffLine[]
  local lines = {}
  ---@type laler.WordSpan[]
  local word_spans = {}

  if old_s == new_s then
    lines[#lines + 1] = { kind = "meta", text = "(no changes)" }
    local CONTEXT = 3
    if #old_lines <= CONTEXT * 2 then
      for _, l in ipairs(old_lines) do
        lines[#lines + 1] = { kind = "context", text = " " .. l }
      end
    else
      for i = 1, CONTEXT do
        lines[#lines + 1] = { kind = "context", text = " " .. old_lines[i] }
      end
      local skip = #old_lines - CONTEXT * 2
      lines[#lines + 1] = {
        kind = "meta",
        text = string.format("@@ skipped %d unchanged line%s @@", skip, skip == 1 and "" or "s"),
      }
      for i = #old_lines - CONTEXT + 1, #old_lines do
        lines[#lines + 1] = { kind = "context", text = " " .. old_lines[i] }
      end
    end
    return { lines = lines, word_spans = word_spans }
  end

  local indices = nvim_diff(old_s .. "\n", new_s .. "\n", {
    result_type = "indices",
    algorithm = "histogram",
    linematch = 120,
  }) or {}

  -- Walk both sequences emitting capped context and hunks (±3 around changes).
  local CONTEXT = 3
  local oi, ni = 1, 1
  local hunk_i = 1

  local function emit_skipped_meta(n)
    if n > 0 then
      lines[#lines + 1] = {
        kind = "meta",
        text = string.format("@@ skipped %d unchanged line%s @@", n, n == 1 and "" or "s"),
      }
    end
  end

  local function emit_context_until(o_end, n_end)
    local available = 0
    do
      local t_oi, t_ni = oi, ni
      while t_oi < o_end and t_ni < n_end do
        available = available + 1
        t_oi = t_oi + 1
        t_ni = t_ni + 1
      end
    end
    local skip = math.max(0, available - CONTEXT)
    emit_skipped_meta(skip)
    oi = oi + skip
    ni = ni + skip
    while oi < o_end and ni < n_end do
      lines[#lines + 1] = { kind = "context", text = " " .. (old_lines[oi] or "") }
      oi = oi + 1
      ni = ni + 1
    end
  end

  while hunk_i <= #indices or oi <= #old_lines or ni <= #new_lines do
    local h = indices[hunk_i]
    if not h then
      local available = 0
      do
        local t_oi, t_ni = oi, ni
        while t_oi <= #old_lines and t_ni <= #new_lines do
          available = available + 1
          t_oi = t_oi + 1
          t_ni = t_ni + 1
        end
      end
      local keep = math.min(CONTEXT, available)
      for _ = 1, keep do
        lines[#lines + 1] = { kind = "context", text = " " .. (old_lines[oi] or "") }
        oi = oi + 1
        ni = ni + 1
      end
      emit_skipped_meta(available - keep)
      oi = oi + (available - keep)
      ni = ni + (available - keep)
      while oi <= #old_lines do
        lines[#lines + 1] = { kind = "delete", text = "-" .. (old_lines[oi] or "") }
        oi = oi + 1
      end
      while ni <= #new_lines do
        lines[#lines + 1] = { kind = "add", text = "+" .. (new_lines[ni] or "") }
        ni = ni + 1
      end
      break
    end

    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    emit_context_until(hunk_line_start(start_a, count_a), hunk_line_start(start_b, count_b))

    local del_texts = {}
    local add_texts = {}
    local del_idxs = {}
    local add_idxs = {}

    for i = 0, count_a - 1 do
      local t = old_lines[start_a + i] or ""
      lines[#lines + 1] = { kind = "delete", text = "-" .. t }
      del_texts[#del_texts + 1] = t
      del_idxs[#del_idxs + 1] = #lines
      oi = start_a + i + 1
    end
    for i = 0, count_b - 1 do
      local t = new_lines[start_b + i] or ""
      lines[#lines + 1] = { kind = "add", text = "+" .. t }
      add_texts[#add_texts + 1] = t
      add_idxs[#add_idxs + 1] = #lines
      ni = start_b + i + 1
    end

    -- Pair similar lines for word-level highlight (simple 1:1 by min count)
    local pair_n = math.min(#del_texts, #add_texts)
    for i = 1, pair_n do
      -- Skip prefix +/- for word cols: spans refer to DiffDoc.lines text including prefix
      -- Word spans should highlight within the content after the first char
      local old_t = del_texts[i]
      local new_t = add_texts[i]
      local tmp_spans = {}
      add_word_spans(old_t, new_t, 1, 2, tmp_spans)
      for _, sp in ipairs(tmp_spans) do
        local line_idx = sp.kind == "delete" and del_idxs[i] or add_idxs[i]
        word_spans[#word_spans + 1] = {
          line = line_idx,
          col_start = sp.col_start + 1, -- account for +/- prefix
          col_end = sp.col_end + 1,
          kind = sp.kind,
        }
      end
    end

    hunk_i = hunk_i + 1
  end

  return { lines = lines, word_spans = word_spans }
end

return M
