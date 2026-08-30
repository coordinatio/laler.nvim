---@mod laler.contracts Port contracts (EmmyLua annotations only)
--- No runtime OOP. Modules implement these shapes; session depends on ports.

---@class laler.Range
---@field bufnr integer
---@field mode "char"|"line"
---@field start_row integer 0-indexed
---@field start_col integer 0-indexed byte
---@field end_row integer 0-indexed
---@field end_col integer 0-indexed byte (exclusive for char mode)
---@field text string
---@field start_mark? integer extmark id at range start (right_gravity = false)
---@field end_mark? integer extmark id at exclusive end (right_gravity = true)

---@class laler.Variant
---@field label string
---@field text string
---@field notes string[]

---@class laler.JobSpec
---@field cmd string
---@field args string[]
---@field stdin string
---@field env? table<string, string>
---@field cwd? string

---@class laler.JobCallbacks
---@field on_exit fun(ok: boolean, stdout: string, stderr: string, code: integer)
---@field on_start? fun()

---@class laler.WordSpan
---@field line integer 1-indexed line in DiffDoc.lines
---@field col_start integer 0-indexed byte
---@field col_end integer 0-indexed byte
---@field kind "add"|"delete"

---@class laler.DiffLine
---@field kind "context"|"add"|"delete"|"header"|"meta"
---@field text string

---@class laler.DiffDoc
---@field lines laler.DiffLine[]
---@field word_spans laler.WordSpan[]

---@class laler.PromptDef
---@field id string
---@field label string
---@field description? string
---@field template string

---@class laler.ComposeCtx
---@field text string
---@field language string
---@field filetype string
---@field n_variants integer

---@class laler.ReviewState
---@field prompt_id string
---@field adapter_name string
---@field original string
---@field variants laler.Variant[]
---@field index integer
---@field diff_doc laler.DiffDoc

---@class laler.ReviewCallbacks
---@field on_apply fun(variant: laler.Variant)
---@field on_next fun()
---@field on_prev fun()
---@field on_jump fun(index: integer)
---@field on_yank fun(variant: laler.Variant)
---@field on_retry fun()
---@field on_cancel fun()
---@field on_close fun()

---@class laler.LlmClient
---@field name string
---@field request fun(self: laler.LlmClient, composed: string): laler.JobSpec

---@class laler.JobRunner
---@field start fun(self: laler.JobRunner, spec: laler.JobSpec, callbacks: laler.JobCallbacks, opts?: { timeout_ms?: integer })
---@field cancel fun(self: laler.JobRunner)
---@field is_running fun(self: laler.JobRunner): boolean

---@class laler.VariantParser
---@field parse fun(self: laler.VariantParser, stdout: string): boolean, laler.Variant[]|string

---@class laler.PromptCatalog
---@field list fun(self: laler.PromptCatalog): laler.PromptDef[]
---@field get fun(self: laler.PromptCatalog, id: string): laler.PromptDef?
---@field default_id fun(self: laler.PromptCatalog): string
---@field remember fun(self: laler.PromptCatalog, id: string)

---@class laler.PromptComposer
---@field compose fun(self: laler.PromptComposer, prompt: laler.PromptDef, ctx: laler.ComposeCtx): string

---@class laler.PickerItem
---@field id string
---@field label string
---@field description? string

---@class laler.Picker
---@field pick fun(self: laler.Picker, items: laler.PickerItem[], opts: { prompt?: string, default_id?: string }, on_choice: fun(id: string), on_cancel?: fun())

---@class laler.DiffEngine
---@field diff fun(self: laler.DiffEngine, original: string, variant: string): laler.DiffDoc

---@class laler.ReviewView
---@field open_loading fun(self: laler.ReviewView, info: { prompt_id: string, adapter_name: string }, callbacks: laler.ReviewCallbacks)
---@field show_review fun(self: laler.ReviewView, state: laler.ReviewState, callbacks: laler.ReviewCallbacks)
---@field show_error fun(self: laler.ReviewView, err: string, raw?: string, callbacks: laler.ReviewCallbacks)
---@field close fun(self: laler.ReviewView)

---@class laler.RangeCapture
---@field from_visual fun(self: laler.RangeCapture): laler.Range?, string?
---@field from_operator fun(self: laler.RangeCapture, mode: string): laler.Range?, string?
---@field from_command_range fun(self: laler.RangeCapture, line1: integer, line2: integer): laler.Range?, string?

---@class laler.RangeApplier
---@field apply fun(self: laler.RangeApplier, range: laler.Range, text: string): boolean, string?

---@class laler.SessionCtx
---@field config table
---@field catalog laler.PromptCatalog
---@field composer laler.PromptComposer
---@field llm laler.LlmClient
---@field jobs laler.JobRunner
---@field parser laler.VariantParser
---@field picker laler.Picker
---@field diff laler.DiffEngine
---@field view laler.ReviewView
---@field capture laler.RangeCapture
---@field apply laler.RangeApplier

return {}
