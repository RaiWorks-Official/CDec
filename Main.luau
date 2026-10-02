--!strict
--This is an open sourced decompiler released by Primez Rai
--Main.luau

--[[
  feel free to give credits or not idk. your choice

  This is a decent one, we are planning to make a better one but will make it paid

  thanks for ActualMasterOogway for the deserializer (iridium)
  look at the repo: https://github.com/ActualMasterOogway/Iridium
]]--

local Analyze = require("./src/Analyze")

-- May have to improve Lifter
getgenv().decompile = function(script)
<<<<<<< HEAD
  local getbc = _G.getscriptbytecode or getscriptbytecode or function(bc) return bc end
=======
  local getbc = getgenv().getscriptbytecode or getscriptbytecode or function(bc) return bc end
>>>>>>> c142da7 (Lifter wiring, debug local names, bytecode v13 support, README)
  local bytecode = getbc(script) or nil
  return Analyze(bytecode or script)
end
