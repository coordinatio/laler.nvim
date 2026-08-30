if vim.g.loaded_laler then
  return
end
vim.g.loaded_laler = true

vim.api.nvim_create_user_command("Laler", function(opts)
  require("laler").run_command(opts.line1, opts.line2, opts.args)
end, {
  range = true,
  nargs = "?",
  desc = "laler: correct range with prompt (default/last if omitted)",
  complete = function()
    local ok, laler = pcall(require, "laler")
    if not ok then
      return {}
    end
    laler.setup_if_needed()
    return require("laler.session").prompt_ids()
  end,
})

vim.api.nvim_create_user_command("LalerPick", function(opts)
  require("laler").pick_command(opts.line1, opts.line2)
end, {
  range = true,
  desc = "laler: pick prompt then correct range",
})

vim.api.nvim_create_user_command("LalerCancel", function()
  require("laler").cancel()
end, {
  desc = "laler: cancel in-flight job and close UI",
})
