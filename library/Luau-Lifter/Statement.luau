local Expression = require("./Expression")

local Block = {}
Block.__type = "Block"
Block.__index = Block

function Block.new()
	local self = setmetatable({}, Block)

	self.Statements = {}
	self.Refs = {}

	return self
end

function Block:Add(statement)
	self.Statements[#self.Statements + 1] = statement

	return statement
end

function Block:IsEmpty()
	return #self.Statements == 0
end

local Statement = {}
Statement.__type = "Statement"
Statement.__index = Statement
Statement.Block = Block

function Statement.new(kind, fields)
	local self = setmetatable(fields or {}, Statement)

	self.Kind = kind
	self.Refs = {}
	self.OwnRefs = {}

	return self
end

function Statement.Assign(targets, values)
	return Statement.new("assign", { Targets = targets, Values = values, Declares = {} })
end

function Statement.Call(expression)
	return Statement.new("call", { Expression = expression })
end

function Statement.Return(values)
	return Statement.new("return", { Values = values })
end

function Statement.If(condition, then_block, else_block)
	return Statement.new("if", { Condition = condition, Then = then_block, Else = else_block })
end

function Statement.While(condition, body)
	return Statement.new("while", { Condition = condition, Body = body })
end

function Statement.Repeat(body, condition)
	return Statement.new("repeat", { Body = body, Condition = condition })
end

function Statement.NumericFor(variable, start, limit, step, body)
	return Statement.new("fornum", {
		Variable = variable,
		Start = start,
		Limit = limit,
		Step = step,
		Body = body,
		Bound = { variable },
	})
end

function Statement.GenericFor(variables, values, body)
	return Statement.new("forin", { Variables = variables, Values = values, Body = body, Bound = variables })
end

function Statement.Break()
	return Statement.new("break")
end

function Statement.Continue()
	return Statement.new("continue")
end

function Statement.Comment(text)
	return Statement.new("comment", { Text = text })
end

function Statement.Declare(names)
	return Statement.new("declare", { Names = names })
end

local function sub_blocks(statement)
	local kind = statement.Kind

	if kind == "if" then
		if statement.Else then
			return { statement.Then, statement.Else }
		end
		return { statement.Then }
	elseif kind == "while" or kind == "repeat" or kind == "fornum" or kind == "forin" then
		return { statement.Body }
	end

	return {}
end

local function add_refs(set, expression)
	Expression.each_var(expression, function(name)
		set[name] = true
	end)
end

local function own_refs(statement)
	local set = {}
	local kind = statement.Kind

	if kind == "assign" then
		for _, target in ipairs(statement.Targets) do
			add_refs(set, target)
		end
		for _, value in ipairs(statement.Values) do
			add_refs(set, value)
		end
	elseif kind == "call" then
		add_refs(set, statement.Expression)
	elseif kind == "return" or kind == "forin" then
		for _, value in ipairs(statement.Values) do
			add_refs(set, value)
		end
	elseif kind == "if" or kind == "while" or kind == "repeat" then
		add_refs(set, statement.Condition)
	elseif kind == "fornum" then
		add_refs(set, statement.Start)
		add_refs(set, statement.Limit)
		if statement.Step then
			add_refs(set, statement.Step)
		end
	end

	return set
end

local function collect(block)
	local refs = {}

	for _, statement in ipairs(block.Statements) do
		local own = own_refs(statement)
		local all = {}

		for name in pairs(own) do
			all[name] = true
		end

		for _, sub in ipairs(sub_blocks(statement)) do
			for name in pairs(collect(sub)) do
				all[name] = true
			end
		end

		if statement.Bound then
			for _, name in ipairs(statement.Bound) do
				all[name] = nil
			end
		end

		statement.OwnRefs = own
		statement.Refs = all

		for name in pairs(all) do
			refs[name] = true
		end
	end

	block.Refs = refs

	return refs
end

local function can_fold_declaration(statement, name)
	if statement.Kind ~= "assign" or not statement.OwnRefs[name] then
		return false
	end

	local is_target = false

	for _, target in ipairs(statement.Targets) do
		if target.k == "var" and target.name == name then
			is_target = true
		end
	end

	if not is_target then
		return false
	end

	for _, value in ipairs(statement.Values) do
		if Expression.references(value, name) then
			return false
		end
	end

	return true
end

local function decide(block, name)
	local first = nil
	local count = 0

	for index, statement in ipairs(block.Statements) do
		if statement.Refs[name] then
			count = count + 1
			first = first or index
		end
	end

	if not first then
		return
	end

	local statement = block.Statements[first]

	if count == 1 and not statement.OwnRefs[name] then
		local holder = nil
		local holders = 0

		for _, sub in ipairs(sub_blocks(statement)) do
			if sub.Refs[name] then
				holders = holders + 1
				holder = sub
			end
		end

		if holders == 1 then
			return decide(holder, name)
		end
	end

	if can_fold_declaration(statement, name) then
		statement.Declares[name] = true
	else
		table.insert(block.Statements, first, Statement.Declare({ name }))
	end
end

local function merge_declares(block)
	local merged = {}

	for _, statement in ipairs(block.Statements) do
		local previous = merged[#merged]

		if statement.Kind == "declare" and previous and previous.Kind == "declare" then
			for _, name in ipairs(statement.Names) do
				previous.Names[#previous.Names + 1] = name
			end
		else
			merged[#merged + 1] = statement
		end

		for _, sub in ipairs(sub_blocks(statement)) do
			merge_declares(sub)
		end
	end

	block.Statements = merged
end

function Statement.Finalize(block, predeclared)
	collect(block)

	local names = {}

	for name in pairs(block.Refs) do
		if not predeclared[name] then
			names[#names + 1] = name
		end
	end

	table.sort(names)

	for _, name in ipairs(names) do
		decide(block, name)
	end

	merge_declares(block)
end

local render_block

local function render_if(statement, level, out, keyword)
	local pad = Expression.indent_text(level)
	local condition = statement.Condition
	local then_block = statement.Then
	local else_block = statement.Else

	if then_block:IsEmpty() and else_block and not else_block:IsEmpty() then
		condition = Expression.negate(condition)
		then_block, else_block = else_block, nil
	end

	out[#out + 1] = pad .. keyword .. " " .. Expression.render(condition, level, 0) .. " then"
	render_block(then_block, level + 1, out)

	if else_block and not else_block:IsEmpty() then
		local only = else_block.Statements[1]

		if #else_block.Statements == 1 and only.Kind == "if" then
			render_if(only, level, out, "elseif")
			return
		end

		out[#out + 1] = pad .. "else"
		render_block(else_block, level + 1, out)
	end

	out[#out + 1] = pad .. "end"
end

local function render_assign(statement, level, out)
	local pad = Expression.indent_text(level)
	local targets = {}
	local declared = 0

	for index, target in ipairs(statement.Targets) do
		targets[index] = Expression.render(target, level, 0)

		if target.k == "var" and statement.Declares[target.name] then
			declared = declared + 1
		end
	end

	local values = Expression.render_list(statement.Values, level)

	if declared == 1 and #statement.Targets == 1 and #statement.Values == 1 and statement.Values[1].k == "func" then
		local name = statement.Targets[1].name

		if name then
			local head = statement.Values[1].head
			local rest = string.sub(head, 9)
			local func = Expression.func("function" .. rest, statement.Values[1].render_body, statement.Values[1].captures)
			local text = Expression.render(func, level, 0)

			out[#out + 1] = pad .. "local " .. string.gsub(text, "^function", "function " .. name, 1)
			return
		end
	end

	if declared == #statement.Targets and declared > 0 then
		out[#out + 1] = pad .. "local " .. table.concat(targets, ", ") .. " = " .. values
		return
	end

	if declared > 0 then
		for _, target in ipairs(statement.Targets) do
			if target.k == "var" and statement.Declares[target.name] then
				out[#out + 1] = pad .. "local " .. target.name
			end
		end
	end

	out[#out + 1] = pad .. table.concat(targets, ", ") .. " = " .. values
end

local function render_statement(statement, level, out)
	local pad = Expression.indent_text(level)
	local kind = statement.Kind

	if kind == "assign" then
		render_assign(statement, level, out)
	elseif kind == "call" then
		out[#out + 1] = pad .. Expression.render(statement.Expression, level, 0)
	elseif kind == "return" then
		if #statement.Values == 0 then
			out[#out + 1] = pad .. "return"
		else
			out[#out + 1] = pad .. "return " .. Expression.render_list(statement.Values, level)
		end
	elseif kind == "if" then
		render_if(statement, level, out, "if")
	elseif kind == "while" then
		out[#out + 1] = pad .. "while " .. Expression.render(statement.Condition, level, 0) .. " do"
		render_block(statement.Body, level + 1, out)
		out[#out + 1] = pad .. "end"
	elseif kind == "repeat" then
		out[#out + 1] = pad .. "repeat"
		render_block(statement.Body, level + 1, out)
		out[#out + 1] = pad .. "until " .. Expression.render(statement.Condition, level, 0)
	elseif kind == "fornum" then
		local header = statement.Variable .. " = " .. Expression.render(statement.Start, level, 0) .. ", " .. Expression.render(statement.Limit, level, 0)

		if statement.Step then
			header = header .. ", " .. Expression.render(statement.Step, level, 0)
		end

		out[#out + 1] = pad .. "for " .. header .. " do"
		render_block(statement.Body, level + 1, out)
		out[#out + 1] = pad .. "end"
	elseif kind == "forin" then
		out[#out + 1] = pad .. "for " .. table.concat(statement.Variables, ", ") .. " in " .. Expression.render_list(statement.Values, level) .. " do"
		render_block(statement.Body, level + 1, out)
		out[#out + 1] = pad .. "end"
	elseif kind == "break" then
		out[#out + 1] = pad .. "break"
	elseif kind == "continue" then
		out[#out + 1] = pad .. "continue"
	elseif kind == "comment" then
		out[#out + 1] = pad .. "-- " .. statement.Text
	elseif kind == "declare" then
		out[#out + 1] = pad .. "local " .. table.concat(statement.Names, ", ")
	end
end

render_block = function(block, level, out)
	for _, statement in ipairs(block.Statements) do
		render_statement(statement, level, out)
	end
end

function Statement.Render(block, level)
	local out = {}

	render_block(block, level or 0, out)

	return table.concat(out, "\n")
end

export type Statement = typeof(Statement.new("break"))

return Statement
