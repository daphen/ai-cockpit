local channel = vim.fn.sockconnect("pipe", arg[1], { rpc = true })
assert(channel > 0, "VM editor unavailable")
io.stdout:setvbuf("no")
while true do
  local json = vim.rpcrequest(channel, "nvim_exec_lua", [[
    local instance = vim.env.COCKPIT_INSTANCE or "main"
    local path = vim.fn.expand("~/.local/state/cockpit/chin-" .. instance .. ".json")
    return vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or "{}"
  ]], {})
  io.write(json .. "\n")
  vim.wait(100)
end
