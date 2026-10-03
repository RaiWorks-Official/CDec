--!strict
--This is an open sourced decompiler released by Primez Rai
--Main.luau

--[[
  Idk if this thing is good, decent, mid nor bad it's up to you, we are planning to make a better one but will make it paid

  thanks for ActualMasterOogway for the deserializer (iridium)
  look at the repo: https://github.com/ActualMasterOogway/Iridium
]]--

local Analyze = require("./src/Analyze")

-- May have to improve Lifter
getgenv = getgenv or function() return _G end
getgenv().decompile = function(script)
  local getbc = _G.getscriptbytecode or getscriptbytecode or function(bc) return bc end
  local bytecode = getbc(script) or nil
  return Analyze(bytecode or script)
end
