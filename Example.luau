local fs = require("@lune/fs")
local process = require("@lune/process")

local bytecode_path = process.args[1] or "realfike.bin"
local bytecode = fs.readFile(bytecode_path)

_G.getscriptbytecode = function()
  return bytecode
end

local loaded = require("./Main")
local run = if type(loaded) == "function" then loaded else (_G.decompile or decompile)

assert(type(run) == "function", "Main did not expose decompile")

local fake_script = {}

local success, result = pcall(run, fake_script)

print(`bytecode: {bytecode_path} ({#bytecode} bytes, first byte {string.byte(bytecode, 1)})`)
print(`status: {if success then "ok" else "error"}`)
print(result)
