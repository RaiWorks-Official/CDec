local Names = require("./Names")
local Function = require("./Function")

local Lifter = {}
Lifter.__type = "Lifter"
Lifter.__index = Lifter

function Lifter.new(deserialized)
	local self = setmetatable({}, Lifter)

	self.Deserialized = deserialized
	self.Names = Names.new()

	return self
end

function Lifter:Lift()
	local deserialized = self.Deserialized
	local main = deserialized.Protos[deserialized.ProtoEntryPoint]
	local lifted = Function.new(main, {
		Deserialized = deserialized,
		Names = self.Names,
		Captures = {},
	})

	lifted:Build()

	return lifted:Render()
end

export type Lifter = typeof(Lifter.new(nil :: never))

return Lifter
