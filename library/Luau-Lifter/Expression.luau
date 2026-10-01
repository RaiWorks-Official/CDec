local Expression = {}

local keywords = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
	["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
	["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
	["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
	["while"] = true, ["continue"] = true,
}

local binary_prec = {
	["or"] = 1, ["and"] = 2,
	["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
	[".."] = 5, ["+"] = 6, ["-"] = 6, ["*"] = 7, ["/"] = 7, ["//"] = 7, ["%"] = 7, ["^"] = 10,
}

local comparison = { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true, ["~="] = true, ["=="] = true }
local right_assoc = { [".."] = true, ["^"] = true }
local unary_prec = 8

local flipped = { ["<"] = ">", [">"] = "<", ["<="] = ">=", [">="] = "<=", ["=="] = "==", ["~="] = "~=" }
local negated = { ["=="] = "~=", ["~="] = "==" }

Expression.keywords = keywords

function Expression.is_identifier(text)
	return type(text) == "string" and string.match(text, "^[%a_][%w_]*$") ~= nil and not keywords[text]
end

function Expression.indent_text(level)
	return string.rep("  ", level)
end

function Expression.const(text)
	return { k = "const", text = text }
end

function Expression.number(text)
	return { k = "const", text = text, number = true }
end

function Expression.string(raw, quoted)
	return { k = "const", text = quoted, str = raw }
end

function Expression.var(name)
	return { k = "var", name = name }
end

function Expression.upvalue(name)
	return { k = "var", name = name, upvalue = true, impure = true }
end

function Expression.global(name)
	return { k = "global", name = name, impure = true }
end

function Expression.vararg()
	return { k = "vararg" }
end

function Expression.import(parts)
	return { k = "import", parts = parts }
end

function Expression.index(obj, key)
	return { k = "index", obj = obj, key = key, impure = true }
end

function Expression.call(fn, args)
	return { k = "call", fn = fn, args = args, impure = true }
end

function Expression.method(obj, name, args)
	return { k = "method", obj = obj, name = name, args = args, impure = true }
end

function Expression.methodref(obj, name)
	return { k = "methodref", obj = obj, name = name, impure = true }
end

function Expression.selfarg()
	return { k = "const", text = "self", selfarg = true }
end

function Expression.unop(op, a)
	return { k = "unop", op = op, a = a, impure = a.impure }
end

function Expression.binop(op, a, b)
	local impure = nil
	if a.impure or b.impure then
		impure = true
	end
	return { k = "binop", op = op, a = a, b = b, impure = impure }
end

function Expression.cmp(op, a, b)
	if a.k == "const" and b.k ~= "const" and flipped[op] then
		return Expression.binop(flipped[op], b, a)
	end
	return Expression.binop(op, a, b)
end

function Expression.concat(parts)
	local impure = nil
	for _, part in ipairs(parts) do
		if part.impure then
			impure = true
		end
	end
	return { k = "concat", parts = parts, impure = impure }
end

function Expression.table(array, hash)
	return { k = "table", array = array, hash = hash }
end

function Expression.func(head, render_body, captures)
	return { k = "func", head = head, render_body = render_body, captures = captures or {} }
end

function Expression.is_constant(e)
	return e.k == "const" or e.k == "import"
end

function Expression.negate(e)
	if e.k == "unop" and e.op == "not" then
		return e.a
	end
	if e.k == "binop" then
		if negated[e.op] then
			return Expression.binop(negated[e.op], e.a, e.b)
		end
		if e.op == "and" then
			return Expression.binop("or", Expression.negate(e.a), Expression.negate(e.b))
		end
		if e.op == "or" then
			return Expression.binop("and", Expression.negate(e.a), Expression.negate(e.b))
		end
	end
	if e.k == "const" then
		if e.text == "true" then
			return Expression.const("false")
		elseif e.text == "false" or e.text == "nil" then
			return Expression.const("true")
		end
	end
	return Expression.unop("not", e)
end

local function children(e)
	local list = {}
	local k = e.k
	if k == "index" then
		list[1], list[2] = e.obj, e.key
	elseif k == "call" then
		list[1] = e.fn
		for _, arg in ipairs(e.args) do
			list[#list + 1] = arg
		end
	elseif k == "method" then
		list[1] = e.obj
		for _, arg in ipairs(e.args) do
			list[#list + 1] = arg
		end
	elseif k == "methodref" then
		list[1] = e.obj
	elseif k == "unop" then
		list[1] = e.a
	elseif k == "binop" then
		list[1], list[2] = e.a, e.b
	elseif k == "concat" then
		for _, part in ipairs(e.parts) do
			list[#list + 1] = part
		end
	elseif k == "table" then
		for _, value in ipairs(e.array) do
			list[#list + 1] = value
		end
		for _, pair in ipairs(e.hash) do
			list[#list + 1] = pair.key
			list[#list + 1] = pair.value
		end
	end
	return list
end

function Expression.each_var(e, visit)
	if e.k == "var" then
		if not e.upvalue then
			visit(e.name, e)
		end
		return
	end
	if e.k == "func" then
		for _, name in ipairs(e.captures) do
			visit(name, e)
		end
		return
	end
	for _, child in ipairs(children(e)) do
		Expression.each_var(child, visit)
	end
end

function Expression.references(e, name)
	if e.k == "var" then
		return e.name == name
	end
	if e.k == "func" then
		for _, captured in ipairs(e.captures) do
			if captured == name then
				return true
			end
		end
		return false
	end
	for _, child in ipairs(children(e)) do
		if Expression.references(child, name) then
			return true
		end
	end
	return false
end

local function prec_of(e)
	if e.k == "binop" then
		return binary_prec[e.op]
	elseif e.k == "unop" then
		return unary_prec
	elseif e.k == "concat" then
		return 5
	elseif e.k == "const" and e.number and string.sub(e.text, 1, 1) == "-" then
		return unary_prec
	end
	return 100
end

local render

local function render_path(parts)
	local out = parts[1]
	if not Expression.is_identifier(out) then
		out = "_G[" .. string.format("%q", out) .. "]"
	end
	for i = 2, #parts do
		if Expression.is_identifier(parts[i]) then
			out = out .. "." .. parts[i]
		else
			out = out .. "[" .. string.format("%q", parts[i]) .. "]"
		end
	end
	return out
end

Expression.render_path = render_path

local function prefix(e, level)
	local text = render(e, level, 0)
	local k = e.k
	if k == "const" or k == "table" or k == "func" or k == "vararg" or k == "binop" or k == "unop" or k == "concat" then
		return "(" .. text .. ")"
	end
	return text
end

local function render_list(list, level)
	local out = {}
	for i, item in ipairs(list) do
		out[i] = render(item, level, 0)
	end
	return table.concat(out, ", ")
end

Expression.render_list = render_list

local function render_raw(e, level)
	local k = e.k
	if k == "const" then
		return e.text
	elseif k == "var" then
		return e.name
	elseif k == "global" then
		if Expression.is_identifier(e.name) then
			return e.name
		end
		return "_G[" .. string.format("%q", e.name) .. "]"
	elseif k == "vararg" then
		return "..."
	elseif k == "import" then
		return render_path(e.parts)
	elseif k == "index" then
		local key = e.key
		if key.k == "const" and key.str and Expression.is_identifier(key.str) then
			return prefix(e.obj, level) .. "." .. key.str
		end
		return prefix(e.obj, level) .. "[" .. render(key, level, 0) .. "]"
	elseif k == "call" then
		return prefix(e.fn, level) .. "(" .. render_list(e.args, level) .. ")"
	elseif k == "method" then
		return prefix(e.obj, level) .. ":" .. e.name .. "(" .. render_list(e.args, level) .. ")"
	elseif k == "methodref" then
		return prefix(e.obj, level) .. ":" .. e.name
	elseif k == "unop" then
		local inner = render(e.a, level, unary_prec)
		if e.op == "not" then
			return "not " .. inner
		end
		if string.sub(inner, 1, 1) == "-" then
			return e.op .. " " .. inner
		end
		return e.op .. inner
	elseif k == "binop" then
		local p = binary_prec[e.op]
		local left_min, right_min = p, p + 1
		if right_assoc[e.op] then
			left_min, right_min = p + 1, p
		end
		if comparison[e.op] then
			left_min, right_min = p + 1, p + 1
		end
		return render(e.a, level, left_min) .. " " .. e.op .. " " .. render(e.b, level, right_min)
	elseif k == "concat" then
		local out = {}
		for i, part in ipairs(e.parts) do
			out[i] = render(part, level, 6)
		end
		return table.concat(out, " .. ")
	elseif k == "table" then
		local out = {}
		for _, value in ipairs(e.array) do
			out[#out + 1] = render(value, level, 0)
		end
		for _, pair in ipairs(e.hash) do
			local key = pair.key
			if key.k == "const" and key.str and Expression.is_identifier(key.str) then
				out[#out + 1] = key.str .. " = " .. render(pair.value, level, 0)
			else
				out[#out + 1] = "[" .. render(key, level, 0) .. "] = " .. render(pair.value, level, 0)
			end
		end
		if #out == 0 then
			return "{}"
		end
		return "{ " .. table.concat(out, ", ") .. " }"
	elseif k == "func" then
		local body = e.render_body(level + 1)
		if body == "" then
			return e.head .. " end"
		end
		return e.head .. "\n" .. body .. "\n" .. Expression.indent_text(level) .. "end"
	end
	return "nil"
end

render = function(e, level, min_prec)
	level = level or 0
	local text = render_raw(e, level)
	if min_prec and prec_of(e) < min_prec then
		return "(" .. text .. ")"
	end
	return text
end

Expression.render = render

return Expression
