---@implements laler.DiffEngine
local M = {}

---@param s string
---@return string[]
local function split_lines(s)
  if s == "" then
    return {}
  end
  return vim.split(s, "\n", { plain = true })
end

--- Tokenize into words and separators (punctuation / whitespace runs kept).
---@param line string
---@return string[]
local function tokenize(line)
  local tokens = {}
  local i = 1
  local n = #line
  while i <= n do
    local a, b = line:find("[%w_%']+", i)
    if a and a == i then
      tokens[#tokens + 1] = line:sub(a, b)
      i = b + 1
    else
      -- group consecutive non-word chars
      local j = i
      while j <= n and not line:find("^[%w_%']", j) do
        j = j + 1
      end
      tokens[#tokens + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return tokens
end

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
  local indices = vim.diff(a_s, b_s, {
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
    for _, l in ipairs(old_lines) do
      lines[#lines + 1] = { kind = "context", text = " " .. l }
    end
    return { lines = lines, word_spans = word_spans }
  end

  local indices = vim.diff(old_s .. "\n", new_s .. "\n", {
    result_type = "indices",
    algorithm = "histogram",
    linematch = 120,
  }) or {}

  -- Walk both sequences emitting context and hunks
  local oi, ni = 1, 1
  local hunk_i = 1

  local function emit_context_until(o_end, n_end)
    while oi < o_end and ni < n_end do
      lines[#lines + 1] = { kind = "context", text = " " .. (old_lines[oi] or "") }
      oi = oi + 1
      ni = ni + 1
    end
  end

  while hunk_i <= #indices or oi <= #old_lines or ni <= #new_lines do
    local h = indices[hunk_i]
    if not h then
      while oi <= #old_lines and ni <= #new_lines do
        lines[#lines + 1] = { kind = "context", text = " " .. (old_lines[oi] or "") }
        oi = oi + 1
        ni = ni + 1
      end
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
    emit_context_until(start_a, start_b)

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
