# laler.nvim

**Language Learner** for Neovim — select text, get LLM corrections with a delta-style diff and learning notes, apply the variant you want.

Write prompts, notes, or prose in Neovim and get a tight feedback loop on how native / correct your language is.

## Requirements

- Neovim **0.10+** (`vim.system`, `vim.diff`, `vim.json`)
- One of: [pi](https://pi.dev/), [Cursor CLI](https://cursor.com/docs/cli/overview) (`agent`), or [OpenCode](https://opencode.ai/) — or a custom CLI
- Optional picker: [fzf-lua](https://github.com/ibhagwan/fzf-lua) or [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)

## Install

lazy.nvim:

```lua
{
  "coordinatio/laler.nvim",
  opts = {
    adapter = "pi",
    mappings = {
      run = "<leader>ll",
      pick = "<leader>lL",
      buffer = "<leader>la",
      pick_buffer = "<leader>lA",
    },
  },
}
```

## Usage

1. Select text in visual mode, or in normal mode use **`run`** / **`pick`** as operators:
   - `<leader>lliw` — current word
   - `<leader>llip` / `<leader>llap` — inner / around paragraph
   - `<leader>llis` / `<leader>llas` — inner / around sentence
   - `<leader>ll$` — to end of line
   - `<leader>llG` — to end of buffer
   - `<leader>ll}` — next blank-line-separated block
2. **`run`** uses the default / last-used prompt immediately.
3. **`pick`** opens a prompt selector (first item = default); same motions work with `<leader>lL`.
4. **`buffer`** (`<leader>la`) corrects the whole buffer (same as `:%Laler`).
5. **`pick_buffer`** (`<leader>lA`) picks a prompt, then corrects the whole buffer (same as `:%LalerPick`).
6. A float shows loading, then variants with unified diff + notes.
7. Cycle with `Tab` / `S-Tab`, apply with `<CR>`, cancel with `q` / `<Esc>`.

Commands:

| Command | Description |
| --- | --- |
| `:[range]Laler [prompt]` | Correct range |
| `:[range]LalerPick` | Pick prompt, then correct |
| `:LalerCancel` | Cancel job / close UI |

## Configuration

```lua
require("laler").setup({
  adapter = "pi", -- "cursor" | "opencode" | { name, model, thinking, cmd, args, env, build }
  model = nil, -- optional CLI --model for pi, cursor, and opencode
  thinking = nil, -- optional; `false` disables model reasoning
  language = "en",
  n_variants = 3,
  default_prompt = "correct",
  remember_last_prompt = true,
  picker = nil, -- "fzf-lua" | "telescope" | "vim_ui" | nil = auto
  timeout_ms = 60000,
  mappings = { run = "<leader>ll", pick = "<leader>lL", buffer = "<leader>la", pick_buffer = "<leader>lA" }, -- or false
  -- prompts = { ... }, -- map: add/override builtins; list: replace catalog
})
```

### Model

Built-in adapters pass `--model NAME` to the CLI when `model` is set. Omit it to use the CLI default.

If both top-level `model` and `adapter.model` are set on an adapter table, **`adapter.model` takes precedence**.

```lua
-- pi (same flag as `pi --model alibaba-cloud/qwen3.8-flash`)
require("laler").setup({
  adapter = "pi",
  model = "alibaba-cloud/qwen3.8-flash",
})

-- Cursor CLI (`agent -p --model gpt-5`)
require("laler").setup({
  adapter = "cursor",
  model = "gpt-5",
})

-- OpenCode (`opencode run --model anthropic/claude-sonnet-4-5`)
require("laler").setup({
  adapter = "opencode",
  model = "anthropic/claude-sonnet-4-5",
})
```

Same option on a named built-in table (keeps the adapter's default flags):

```lua
require("laler").setup({
  adapter = {
    name = "pi",
    model = "alibaba-cloud/qwen3.8-flash",
  },
})
```

### Thinking

Set `thinking = false` to disable model reasoning. Omit it (or set `true`) to leave the CLI default.

If both top-level `thinking` and `adapter.thinking` are set on an adapter table, **`adapter.thinking` takes precedence**.

Generic adapters (custom `cmd` / `args` tables) use pi-style `--thinking off` when `thinking = false`. Only the built-in **opencode** adapter uses `--variant none` instead (best-effort: some models may still emit reasoning).

```lua
-- pi: `--thinking off`
require("laler").setup({
  adapter = "pi",
  model = "alibaba-cloud/qwen3.8-flash",
  thinking = false,
})

-- OpenCode: `--variant none` (not `run --thinking`, which only shows thinking blocks)
require("laler").setup({
  adapter = "opencode",
  model = "anthropic/claude-sonnet-4-5",
  thinking = false,
})

-- Cursor has no thinking flag; pick a non-thinking model instead
require("laler").setup({
  adapter = "cursor",
  model = "gpt-5",
  thinking = false,
})
```

Same option on a named built-in table:

```lua
require("laler").setup({
  adapter = {
    name = "pi",
    model = "alibaba-cloud/qwen3.8-flash",
    thinking = false,
  },
})
```

### Custom adapter

```lua
require("laler").setup({
  adapter = {
    name = "my-cli",
    cmd = "my-llm",
    args = { "--print" },
    model = "my-model", -- optional; appends --model
    thinking = false, -- optional; appends --thinking off (pi-style, not opencode --variant none)
  },
})
```

Generic adapters append `--model` / `--thinking` to `args`; avoid duplicating those flags in `args` when also using `model` / `thinking` options.

Custom adapters with a `build()` function ignore `model` and `thinking`; emit those flags inside `build()` if needed.

Prompt delivery:

- **pi** and **opencode:** composed prompt on **stdin**
- **cursor:** composed prompt as a **positional argv** argument (`agent -p` ignores stdin)

Built-in adapters disable agent tools so they do not edit files:

- **pi:** `-p --no-tools --no-session --no-context-files --no-skills` (and `--no-extensions` when no `model` is set; pi needs extensions to resolve `provider/model` IDs)
- **cursor:** `-p --mode ask --output-format text --trust --sandbox enabled` (ask is read-only; workspace trust for headless; not `--force`)
- **opencode:** `run --format default --pure`, plus `OPENCODE_PERMISSION` deny-all (no `--permissions` flag; that option is not on `run`)

When `model` is set, each of those invocations also gets `--model NAME` (for cursor, before the positional prompt). When `thinking` is `false`, pi also gets `--thinking off` and opencode gets `--variant none`. Cursor has no thinking flag.

## Built-in prompts

| id | Purpose |
| --- | --- |
| `correct` | Grammar + native-speaker fluency (conservative / native / alternative) |
| `formal` | More formal register |
| `casual` | More conversational |
| `concise` | Shorter and clearer |

Templates support `{{text}}`, `{{language}}`, `{{filetype}}`, `{{n_variants}}`, `{{variant_noun}}`, `{{text_open}}`, `{{text_close}}`, `{{variant_list}}`. `{{text}}` is the passage inside unique delimiters; `{{text_open}}` / `{{text_close}}` are those markers; `{{n_variants}}` / `{{variant_noun}}` are the requested count and “variant”/“variants”; `{{variant_list}}` is a numbered label list for that prompt (`conservative` / `native` / `alternative` on `correct`; `{id}-1`…`{id}-n` otherwise). Output must be JSON with `variants[{label,text,notes}]`.

The composer already prepends that JSON contract plus language, variant count, and delimiter rules. A custom task template only needs the instruction that is unique to the prompt and `{{text}}`. When you set `template` (a new prompt or a template override), it must contain `{{text}}`. Overlaying other fields without `template` (for example `{ correct = { n_variants = 1 } }`) keeps the builtin template. `label` and `description`, when set, must be strings.

## Custom prompts

A **map** adds or overrides prompts and keeps the builtins. (Older versions treated a map as a full replacement; pass a **list** if you still want that.) Overlaying a builtin merges fields: omitted `template` / `label` / `description` stay. New map ids still need a `template`. If you set `id`, it must equal the map key. A **list** replaces the catalog and drops builtins. `n_variants` on a prompt (1–9) overrides the global count. `default_prompt` is the id used by `run` / `:Laler` until a successful run remembers another prompt (`remember_last_prompt`).

Add a prompt (map merge):

```lua
require("laler").setup({
  default_prompt = "conservative",
  prompts = {
    conservative = {
      label = "Conservative",
      description = "Grammar + native-speaker fluency (minimal edits only)",
      n_variants = 1,
      template = [[Conservative correction: minimal edits, same meaning.

{{text}}]],
    },
  },
})
```

Override a builtin (map; omitted fields stay). `{ correct = { n_variants = 1 } }` keeps the builtin template, label, and description:

```lua
require("laler").setup({
  prompts = {
    correct = { n_variants = 1 },
    concise = {
      template = [[Make the passage shorter. Keep technical terms.

{{text}}]],
    },
  },
})
```

Replace the catalog (list form; builtins are dropped):

```lua
require("laler").setup({
  default_prompt = "plain",
  prompts = {
    {
      id = "plain",
      label = "Plain",
      template = [[Fix grammar only.

{{text}}]],
    },
  },
})
```

## Review keys

| Key | Action |
| --- | --- |
| `<CR>` | Apply variant |
| `Tab` / `n` / `]` | Next |
| `S-Tab` / `p` / `[` | Previous |
| `1`–`9` | Jump |
| `y` | Yank |
| `r` | Retry |
| `q` / `<Esc>` | Close (`Esc` cancels while loading) |

## Architecture

Ports and wiring follow SOLID: `session` depends on contracts in `lua/laler/contracts.lua`; `setup()` is the composition root. New LLMs/pickers register without changing the orchestrator.

## Tests

```bash
nvim --headless -u NONE -c "luafile tests/run.lua"
```

## License

[GPL-3.0](LICENSE)
