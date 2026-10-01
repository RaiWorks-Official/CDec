local Names = {}
Names.__type = "Names"
Names.__index = Names

function Names.new()
	local self = setmetatable({}, Names)

	self.Counts = { v = 0, T = 0, U = 0 }
	self.Used = {}

	return self
end

local keywords = {}

for word in string.gmatch("and break continue do else elseif end false for function if in local nil not or repeat return then true until while", "%a+") do
	keywords[word] = true
end

function Names:Pick(debug_name, expression)
	if type(debug_name) == "buffer" then
		debug_name = buffer.tostring(debug_name)
	end

	if type(debug_name) == "string" and string.match(debug_name, "^[%a_][%w_]*$") and not keywords[debug_name] and not string.match(debug_name, "^[vTU]%d+$") then
		local used = self.Used[debug_name]

		self.Used[debug_name] = (used or 0) + 1

		return if used then debug_name .. "_" .. (used + 1) else debug_name
	end

	return self:ForExpression(expression)
end

function Names:Next(prefix)
	self.Counts[prefix] = self.Counts[prefix] + 1

	return prefix .. self.Counts[prefix]
end

function Names:ForExpression(expression)
	if expression and expression.k == "table" then
		return self:Next("T")
	elseif expression and expression.k == "func" then
		return self:Next("U")
	end

	return self:Next("v")
end

function Names:Snapshot()
	local used = {}

	for name, count in pairs(self.Used) do
		used[name] = count
	end

	return { v = self.Counts.v, T = self.Counts.T, U = self.Counts.U, Used = used }
end

function Names:Restore(snapshot)
	self.Counts = { v = snapshot.v, T = snapshot.T, U = snapshot.U }
	self.Used = {}

	for name, count in pairs(snapshot.Used) do
		self.Used[name] = count
	end
end

export type Names = typeof(Names.new())

return Names
