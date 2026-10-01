local Expression = require("../Expression")

local Import = {}
Import.__type = "Import"
Import.__index = Import

function Import.new(constant)
	local self = setmetatable({}, Import)

	self.Parts = {}

	for Index, Part in ipairs(constant.Value) do
		self.Parts[Index] = buffer.tostring(Part.Value)
	end

	return self
end

function Import:Expression()
	return Expression.import(self.Parts)
end

function Import:__tostring()
	return table.concat(self.Parts, ".")
end

export type Import = typeof(Import.new(nil :: never))

return Import
