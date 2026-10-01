local Expression = require("./Expression")
local Import = require("./Deserializer/Import")

local Constants = {}
Constants.__type = "Constants"
Constants.__index = Constants

local escapes = {
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\\"] = "\\\\",
	['"'] = '\\"',
}

local function quote(raw)
	local escaped = string.gsub(raw, '[%c\\"]', function(character)
		return escapes[character] or string.format("\\%03d", string.byte(character))
	end)

	return '"' .. escaped .. '"'
end

local function number_text(value)
	if value ~= value then
		return "0/0"
	elseif value == math.huge then
		return "math.huge"
	elseif value == -math.huge then
		return "-math.huge"
	elseif value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end

	return string.format("%.14g", value)
end

function Constants.new(proto)
	local self = setmetatable({}, Constants)

	self.List = proto.Constants
	self.Cache = {}

	return self
end

function Constants:Raw(index)
	return self.List[index + 1]
end

function Constants:String(index)
	local constant = self:Raw(index)

	if constant and constant.__type == "String" then
		return buffer.tostring(constant.Value)
	end

	return tostring(constant)
end

function Constants:Build(constant)
	local kind = constant.__type

	if kind == "Nil" then
		return Expression.const("nil")
	elseif kind == "Boolean" then
		return Expression.const(constant.Value and "true" or "false")
	elseif kind == "Number" then
		return Expression.number(number_text(constant.Value))
	elseif kind == "Integer" then
		return Expression.number(number_text(constant.Value))
	elseif kind == "String" then
		local raw = buffer.tostring(constant.Value)

		return Expression.string(raw, quote(raw))
	elseif kind == "Import" then
		return Import.new(constant):Expression()
	elseif kind == "Vector" then
		return Expression.call(
			Expression.import({ "vector", "create" }),
			{
				Expression.number(number_text(constant.X)),
				Expression.number(number_text(constant.Y)),
				Expression.number(number_text(constant.Z)),
			}
		)
	elseif kind == "Table" then
		local hash = {}

		for _, key in ipairs(constant.Value) do
			local raw = buffer.tostring(key.Value)

			hash[#hash + 1] = { key = Expression.string(raw, quote(raw)), value = Expression.const("nil") }
		end

		return Expression.table({}, hash)
	elseif kind == "TableWithConstants" then
		local hash = {}

		for _, pair in ipairs(constant.Value) do
			if pair.Key and pair.Value then
				hash[#hash + 1] = { key = self:Build(pair.Key), value = self:Build(pair.Value) }
			end
		end

		return Expression.table({}, hash)
	end

	return Expression.const(tostring(constant))
end

function Constants:Get(index)
	local cached = self.Cache[index]

	if cached then
		return cached
	end

	local constant = self:Raw(index)
	local expression

	if constant then
		expression = self:Build(constant)
	else
		expression = Expression.const("nil")
	end

	self.Cache[index] = expression

	return expression
end

export type Constants = typeof(Constants.new(nil :: never))

return Constants
