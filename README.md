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
  adapter = "pi", -- "cursor" | "opencode" | { name, cmd, args, env, build }
  language = "en",
  n_variants = 3,
  default_prompt = "correct",
  remember_last_prompt = true,
  picker = nil, -- "fzf-lua" | "telescope" | "vim_ui" | nil = auto
  timeout_ms = 60000,
  mappings = { run = "<leader>ll", pick = "<leader>lL", buffer = "<leader>la", pick_buffer = "<leader>lA" }, -- or false
  -- prompts = { ... }, -- override builtins
})
```

### Custom adapter

```lua
require("laler").setup({
  adapter = {
    name = "my-cli",
    cmd = "my-llm",
    args = { "--print" },
  },
})
```

Prompt delivery:

- **pi** and **opencode:** composed prompt on **stdin**
- **cursor:** composed prompt as a **positional argv** argument (`agent -p` ignores stdin)

Built-in adapters disable agent tools so they do not edit files:

- **pi:** `-p --no-tools --no-session --no-context-files --no-extensions --no-skills`
- **cursor:** `-p --mode ask --output-format text --trust --sandbox enabled` (ask is read-only; workspace trust for headless; not `--force`)
- **opencode:** `run --format default --pure`, plus `OPENCODE_PERMISSION` deny-all (no `--permissions` flag; that option is not on `run`)

## Built-in prompts

| id | Purpose |
| --- | --- |
| `correct` | Grammar + native-speaker fluency (conservative / native / alternative) |
| `formal` | More formal register |
| `casual` | More conversational |
| `concise` | Shorter and clearer |

Templates support `{{text}}`, `{{language}}`, `{{filetype}}`, `{{n_variants}}`, `{{text_open}}`, `{{text_close}}`, `{{variant_list}}`. `{{text}}` is the passage inside unique delimiters; `{{text_open}}` / `{{text_close}}` are those markers; `{{variant_list}}` lists requested variant labels. Output must be JSON with `variants[{label,text,notes}]`.

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
