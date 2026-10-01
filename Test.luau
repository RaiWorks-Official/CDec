local fs = require("@lune/fs")
local luau = require("@lune/luau")

local sample_source = [=[
local count = 0
local items = { 1, 2, 3, name = "x", nested = { true, false, nil } }

for i = 1, 10, 2 do
  count += i * 2 - 1
end

for key, value in pairs(items) do
  if type(value) == "number" and value > 1 then
    count = count + value
  elseif value == nil then
    count = count - 1
  else
    count = count // 2
  end
end

while count > 100 do
  count = count / 2
end

repeat
  count -= 1
until count < 50

local function make_adder(step)
  local total = 0
  return function(...)
    total = total + step + select("#", ...)
    return total, ...
  end
end

local adder = make_adder(3)
local text = "a" .. count .. "b" .. tostring(adder(1, 2))
local upper = text:upper()
local neg = -count
local size = #items
local flag = not (count == 5) or count ~= 7

shared_value = upper
print(shared_value, neg, size, flag, math.floor(count), count % 3, count ^ 2)

return adder, make_adder
]=]

local bytecode = luau.compile(sample_source, { optimizationLevel = 1, debugLevel = 2 })

_G.getscriptbytecode = function()
  return bytecode
end

local loaded = require("./Main")
local run = if type(loaded) == "function" then loaded else (_G.decompile or decompile)

assert(type(run) == "function", "Main did not expose decompile")

local success, result = pcall(run, {})

fs.writeFile("out.txt", tostring(result))

local passed = success and string.find(result, ":)", 1, true) ~= nil
local unresolved = {}
local instruction_count = 0

for line in string.gmatch(result, "[^\n]+") do
  local name = string.match(line, "^%s*%[%d+%]%s+(%u[%u%d_]*)")
  if name then
    instruction_count += 1
    if not string.find(line, "; ", 1, true) then
      unresolved[name] = (unresolved[name] or 0) + 1
    end
  end
end

print(`bytecode: {#bytecode} bytes, version {string.byte(bytecode, 1)}`)
print(`instructions listed: {instruction_count}`)
print(`result: {if passed then "PASS" else "FAIL"}`)

if not success then
  print(result)
end

local names = {}
for name, amount in unresolved do
  table.insert(names, `{name} x{amount}`)
end
table.sort(names)
print(`no readable operands: {if #names > 0 then table.concat(names, ", ") else "none"}`)
print("full output written to out.txt")
