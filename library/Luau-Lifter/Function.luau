local LuauSpec = require("@root/Luau/Spec")
local Expression = require("./Expression")
local Statement = require("./Statement")
local Constants = require("./Constants")
local Analysis = require("./Deserializer/Block")
local instructions = require("./instructions")

local op = LuauSpec.LuauOpcode

local Function = {}
Function.__type = "Function"
Function.__index = Function

local function copy_list(list)
	local copy = {}

	for index, value in ipairs(list) do
		copy[index] = value
	end

	return copy
end

function Function.new(proto, context)
	local self = setmetatable({}, Function)

	self.Proto = proto
	self.Context = context
	self.Names = context.Names
	self.Captures = context.Captures or {}
	self.Info = Analysis.new(proto)
	self.Constants = Constants.new(proto)
	self.Regs = {}
	self.Bound = {}
	self.BoundEntry = {}
	self.Pc = 0
	self.MultiOwner = {}
	self.Resolved = {}
	self.Seq = 0
	self.Body = Statement.Block.new()
	self.Current = self.Body
	self.ParamList = {}
	self.CaptureList = {}

	return self
end

function Function:Constant(index)
	return self.Constants:Get(index)
end

function Function:ConstantString(index)
	return self.Constants:String(index)
end

function Function:UpvalueName(index)
	return self.Captures[index + 1] or ("up" .. index)
end

function Function:NextSeq()
	self.Seq = self.Seq + 1

	return self.Seq
end

function Function:Emit(statement)
	self.Current:Add(statement)
end

function Function:Descend(block, callback)
	local previous = self.Current

	self.Current = block
	callback()
	self.Current = previous
end

function Function:DebugLocal(register, ahead)
	local locals = self.Proto.LocalVariables

	if not locals then
		return nil
	end

	local pc = self.Pc
	local upcoming = nil

	for _, entry in ipairs(locals) do
		if entry.Register == register then
			if entry.StartPc <= pc and pc <= entry.EndPc then
				return entry
			elseif ahead and entry.StartPc > pc and (not upcoming or entry.StartPc < upcoming.StartPc) then
				upcoming = entry
			end
		end
	end

	return upcoming
end

function Function:Declare(register, expression)
	local entry = self:DebugLocal(register, true)
	local name = self.Names:Pick(entry and entry.Name, expression)

	self.Bound[register] = name
	self.BoundEntry[register] = entry

	return name
end

function Function:Name(register, expression)
	local name = self.Bound[register]
	local entry = self:DebugLocal(register)

	if not name or (entry and self.BoundEntry[register] and self.BoundEntry[register] ~= entry) then
		name = self:Declare(register, expression)
	end

	return name
end

function Function:Variable(register)
	return Expression.var(self:Name(register, nil))
end

function Function:Pending()
	local list = {}

	for _, entry in pairs(self.Regs) do
		list[#list + 1] = entry
	end

	table.sort(list, function(a, b)
		return a.Seq < b.Seq
	end)

	return list
end

function Function:FlushBelow(seq)
	for _, entry in ipairs(self:Pending()) do
		if entry.Seq < seq and entry.Expression.impure and self.Regs[entry.Register] == entry then
			self:Materialize(entry.Register)
		end
	end
end

function Function:Invalidate(names)
	for _, entry in ipairs(self:Pending()) do
		if self.Regs[entry.Register] == entry then
			for _, name in ipairs(names) do
				if Expression.references(entry.Expression, name) then
					self:Materialize(entry.Register)
					break
				end
			end
		end
	end
end

function Function:Assign(name, expression)
	self:Invalidate({ name })
	self:Emit(Statement.Assign({ Expression.var(name) }, { expression }))
end

function Function:Materialize(register)
	local entry = self.Regs[register]

	if not entry then
		return
	end

	self:FlushBelow(entry.Seq)

	if self.Regs[register] ~= entry then
		return
	end

	self.Regs[register] = nil

	if entry.Multi then
		local targets = {}
		local names = {}

		for offset = 0, entry.Multi - 1 do
			self.MultiOwner[register + offset] = nil

			local name = self:Name(register + offset, nil)

			names[#names + 1] = name
			targets[#targets + 1] = Expression.var(name)
		end

		self:Invalidate(names)
		self:Emit(Statement.Assign(targets, { entry.Expression }))

		return
	end

	self:Assign(self:Name(register, entry.Expression), entry.Expression)
end

function Function:Kill(register)
	local entry = self.Regs[register]

	if not entry then
		return
	end

	self:FlushBelow(entry.Seq)

	if self.Regs[register] ~= entry then
		return
	end

	self.Regs[register] = nil

	if entry.Multi then
		for offset = 0, entry.Multi - 1 do
			self.MultiOwner[register + offset] = nil
		end
	end

	local kind = entry.Expression.k

	if kind == "call" or kind == "method" then
		self:Emit(Statement.Call(entry.Expression))
	end
end

function Function:FlushAll(live)
	for _, entry in ipairs(self:Pending()) do
		if self.Regs[entry.Register] == entry then
			local alive = live == nil

			if live then
				for offset = 0, (entry.Multi or 1) - 1 do
					if live[entry.Register + offset] then
						alive = true
					end
				end
			end

			if alive then
				self:Materialize(entry.Register)
			else
				self:Kill(entry.Register)
			end
		end
	end
end

function Function:ResolveMulti(register)
	local owner = self.MultiOwner[register]

	if owner and self.Regs[owner] and self.Regs[owner].Multi then
		self:Materialize(owner)
	end
end

function Function:FindOpen(from)
	local best = nil

	for _, entry in pairs(self.Regs) do
		if entry.Open and entry.Register >= from and (not best or entry.Register < best.Register) then
			best = entry
		end
	end

	return best
end

function Function:Take(i, registers, statement, force)
	local info = self.Info
	local live = info.LiveOut[i]
	local written = {}

	for _, register in ipairs(info.Writes[i]) do
		written[register] = true
	end

	local counts = {}

	for _, register in ipairs(registers) do
		counts[register] = (counts[register] or 0) + 1
	end

	for _, register in ipairs(registers) do
		self:ResolveMulti(register)
	end

	local function inlinable(register)
		local entry = self.Regs[register]

		if not entry or entry.Multi then
			return false
		end

		if not force and live[register] and not written[register] then
			return false
		end

		return counts[register] == 1 or not entry.Expression.impure
	end

	local keep = {}

	for _, register in ipairs(registers) do
		if inlinable(register) then
			keep[register] = true
		end
	end

	local min_keep = math.huge

	for register in pairs(keep) do
		local entry = self.Regs[register]

		if entry.Expression.impure and entry.Seq < min_keep then
			min_keep = entry.Seq
		end
	end

	local flush = {}
	local max_other = -1

	for register, entry in pairs(self.Regs) do
		if entry.Expression.impure and not keep[register] then
			if statement or entry.Seq > min_keep then
				flush[#flush + 1] = entry

				if entry.Seq > max_other then
					max_other = entry.Seq
				end
			end
		end
	end

	if #flush > 0 then
		for register in pairs(keep) do
			local entry = self.Regs[register]

			if entry.Expression.impure and entry.Seq < max_other then
				flush[#flush + 1] = entry
			end
		end

		table.sort(flush, function(a, b)
			return a.Seq < b.Seq
		end)

		for _, entry in ipairs(flush) do
			if self.Regs[entry.Register] == entry then
				self:Materialize(entry.Register)
			end
		end
	end

	local last = -1

	for _, register in ipairs(registers) do
		local entry = self.Regs[register]

		if entry and inlinable(register) and entry.Expression.impure then
			if entry.Seq < last then
				self:Materialize(register)
			else
				last = entry.Seq
			end
		end
	end

	local taken = {}
	local result = {}

	for index, register in ipairs(registers) do
		if taken[register] ~= nil then
			result[index] = taken[register]
		else
			local entry = self.Regs[register]

			if entry and inlinable(register) then
				taken[register] = entry.Expression
				result[index] = entry.Expression
			else
				if entry then
					self:Materialize(register)
				end

				result[index] = self:Variable(register)
			end
		end
	end

	for register in pairs(taken) do
		self.Regs[register] = nil
	end

	return result
end

function Function:Define(i, register, expression)
	if self.Regs[register] then
		self:Kill(register)
	end

	self.MultiOwner[register] = nil

	if not self.Info.LiveOut[i][register] then
		if expression.k == "call" or expression.k == "method" then
			self:Emit(Statement.Call(expression))
		end

		return
	end

	self.Regs[register] = { Expression = expression, Seq = self:NextSeq(), Register = register }
end

function Function:DefineMulti(i, register, count, expression)
	local live = false

	for offset = 0, count - 1 do
		if self.Regs[register + offset] then
			self:Kill(register + offset)
		end

		self.MultiOwner[register + offset] = nil

		if self.Info.LiveOut[i][register + offset] then
			live = true
		end
	end

	if not live then
		if expression.k == "call" or expression.k == "method" then
			self:Emit(Statement.Call(expression))
		end

		return
	end

	self.Regs[register] = { Expression = expression, Seq = self:NextSeq(), Register = register, Multi = count }

	for offset = 1, count - 1 do
		self.MultiOwner[register + offset] = register
	end
end

function Function:Builder(register)
	local entry = self.Regs[register]

	if entry and entry.Expression.k == "table" and not entry.Multi then
		return entry
	end

	return nil
end

function Function:Replace(entry, expression)
	self.Regs[entry.Register] = { Expression = expression, Seq = entry.Seq, Register = entry.Register }
end

function Function:Store(i, table_register, value_register, key_register, key_expression)
	local builder = self:Builder(table_register)
	local registers = {}

	if not builder then
		registers[#registers + 1] = table_register
	end

	if key_register then
		registers[#registers + 1] = key_register
	end

	registers[#registers + 1] = value_register

	local operands = self:Take(i, registers, true)
	local cursor = 1
	local object = nil
	local key = key_expression

	if not builder then
		object = operands[cursor]
		cursor = cursor + 1
	end

	if key_register then
		key = operands[cursor]
		cursor = cursor + 1
	end

	local value = operands[cursor]

	if builder then
		local current = self:Builder(table_register)

		if current and not value.impure and not key.impure then
			local hash = copy_list(current.Expression.hash)

			hash[#hash + 1] = { key = key, value = value }
			self:Replace(current, Expression.table(current.Expression.array, hash))

			return
		end

		if current then
			self:Materialize(table_register)
		end

		object = self:Variable(table_register)
	end

	self:Emit(Statement.Assign({ Expression.index(object, key) }, { value }))
end

function Function:SetList(i, instruction)
	local A, B, C = instruction.A, instruction.B, instruction.C
	local start = instructions.AuxValue(instruction)
	local builder = self:Builder(A)
	local registers = {}

	if not builder then
		registers[1] = A
	end

	if C == 0 then
		local open = self:FindOpen(B)
		local last = open and open.Register - 1 or B - 1

		for register = B, last do
			registers[#registers + 1] = register
		end

		if open then
			registers[#registers + 1] = open.Register
		end
	else
		for register = B, B + C - 2 do
			registers[#registers + 1] = register
		end
	end

	local operands = self:Take(i, registers, true)
	local first = 1
	local object = nil

	if not builder then
		object = operands[1]
		first = 2
	end

	local values = {}

	for index = first, #operands do
		values[#values + 1] = operands[index]
	end

	local pure = true

	for _, value in ipairs(values) do
		if value.impure then
			pure = false
		end
	end

	if builder then
		local current = self:Builder(A)

		if current and pure and start == #current.Expression.array + 1 then
			local array = copy_list(current.Expression.array)

			for _, value in ipairs(values) do
				array[#array + 1] = value
			end

			self:Replace(current, Expression.table(array, current.Expression.hash))

			return
		end

		if current then
			self:Materialize(A)
		end

		object = self:Variable(A)
	end

	for index, value in ipairs(values) do
		self:Emit(Statement.Assign({ Expression.index(object, Expression.number(tostring(start + index - 1))) }, { value }))
	end
end

function Function:Call(i, instruction)
	local A, B, C = instruction.A, instruction.B, instruction.C
	local registers = { A }

	if B == 0 then
		local open = self:FindOpen(A + 1)
		local last = open and open.Register - 1 or A

		for register = A + 1, last do
			registers[#registers + 1] = register
		end

		if open then
			registers[#registers + 1] = open.Register
		end
	else
		for register = A + 1, A + B - 1 do
			registers[#registers + 1] = register
		end
	end

	local dead = C == 1

	if C >= 2 then
		dead = true

		for offset = 0, C - 2 do
			if self.Info.LiveOut[i][A + offset] then
				dead = false
			end
		end
	end

	local operands = self:Take(i, registers, dead)
	local fn = operands[1]
	local args = {}

	for index = 2, #operands do
		args[#args + 1] = operands[index]
	end

	local expression

	if fn.k == "methodref" then
		if args[1] and args[1].selfarg then
			table.remove(args, 1)
		end

		expression = Expression.method(fn.obj, fn.name, args)
	else
		expression = Expression.call(fn, args)
	end

	if C == 1 then
		self:Emit(Statement.Call(expression))
	elseif C == 2 then
		self:Define(i, A, expression)
	elseif C == 0 then
		self:Define(i, A, expression)

		if self.Regs[A] then
			self.Regs[A].Open = true
		end
	else
		self:DefineMulti(i, A, C - 1, expression)
	end
end

function Function:Return(i, instruction)
	local A, B = instruction.A, instruction.B
	local registers = {}

	if B == 0 then
		local open = self:FindOpen(A)
		local last = open and open.Register - 1 or A - 1

		for register = A, last do
			registers[#registers + 1] = register
		end

		if open then
			registers[#registers + 1] = open.Register
		end
	else
		for register = A, A + B - 2 do
			registers[#registers + 1] = register
		end
	end

	self:Emit(Statement.Return(self:Take(i, registers, true)))
end

function Function:VarArgs(i, instruction)
	local A, B = instruction.A, instruction.B

	if B == 0 then
		self:Define(i, A, Expression.vararg())

		if self.Regs[A] then
			self.Regs[A].Open = true
		end
	elseif B == 2 then
		self:Define(i, A, Expression.vararg())
	elseif B > 2 then
		self:DefineMulti(i, A, B - 1, Expression.vararg())
	end
end

function Function:BuildChild(proto, captures)
	local child = Function.new(proto, {
		Deserialized = self.Context.Deserialized,
		Names = self.Names,
		Captures = captures,
	})

	child:Build()

	return child:AsExpression()
end

function Function:NewClosure(i, instruction)
	local child = self.Proto.Protos[instruction.D + 1]
	local count = child.UpvalueCount
	local names = {}

	for offset = 1, count do
		local capture = self.Info.List[i + offset]

		if capture.A < 2 then
			self:ResolveMulti(capture.B)

			if self.Regs[capture.B] then
				self:Materialize(capture.B)
			end

			names[offset] = self:Name(capture.B, nil)
		else
			names[offset] = self:UpvalueName(capture.B)
		end
	end

	self:Define(i, instruction.A, self:BuildChild(child, names))

	return count
end

function Function:DupClosure(i, instruction)
	local constant = self.Constants:Raw(instruction.D)
	local child = self.Context.Deserialized.Protos[constant.Value + 1]

	self:Define(i, instruction.A, self:BuildChild(child, {}))
end

function Function:AsExpression()
	local head = "function(" .. table.concat(self.ParamList, ", ") .. ")"
	local block = self.Body

	return Expression.func(head, function(level)
		return Statement.Render(block, level)
	end, self.CaptureList)
end

function Function:Render()
	return Statement.Render(self.Body, 0)
end

function Function:Snapshot()
	local regs = {}
	local bound = {}
	local owner = {}

	for register, entry in pairs(self.Regs) do
		regs[register] = entry
	end

	for register, name in pairs(self.Bound) do
		bound[register] = name
	end

	for register, value in pairs(self.MultiOwner) do
		owner[register] = value
	end

	return {
		Regs = regs,
		Bound = bound,
		Owner = owner,
		Seq = self.Seq,
		Count = #self.Current.Statements,
		Block = self.Current,
		Names = self.Names:Snapshot(),
	}
end

function Function:Restore(snapshot)
	self.Regs = snapshot.Regs
	self.Bound = snapshot.Bound
	self.MultiOwner = snapshot.Owner
	self.Seq = snapshot.Seq
	self.Current = snapshot.Block

	while #snapshot.Block.Statements > snapshot.Count do
		table.remove(snapshot.Block.Statements)
	end

	self.Names:Restore(snapshot.Names)
end

function Function:Exec(index)
	local instruction = self.Info.List[index]
	local handler = instructions.Handlers[instruction.OpCodeInfo.Index]
	local skip = nil

	if handler then
		skip = handler(self, index, instruction)
	end

	return index + 1 + (skip or 0)
end

function Function:Merge(last, stop, skip, target, first_target, first)
	local info = self.Info
	local n = last + 1

	while n < stop and info.Kind[n] == "fall" and not info.IsLabel[n] do
		n = n + 1
	end

	if n >= stop or info.Kind[n] ~= "cond" or info.IsLabel[n] or not info.Target[n] then
		return nil
	end

	local snapshot = self:Snapshot()
	local cursor = last + 1

	while cursor < n do
		cursor = self:Exec(cursor)
	end

	local other = instructions.Condition(self, n, info.List[n])
	local candidate = info.Target[n]

	if #self.Current.Statements == snapshot.Count then
		if first and first_target == n + 1 and candidate > n then
			return Expression.binop("and", Expression.negate(skip), other), candidate, n
		elseif candidate == target then
			return Expression.binop("or", skip, other), target, n
		end
	end

	self:Restore(snapshot)

	return nil
end

function Function:Cond(i, stop, context)
	local info = self.Info
	local skip = instructions.Condition(self, i, info.List[i])
	local target = info.Target[i]
	local first_target = target
	local last = i
	local first = true

	if not target then
		self:Emit(Statement.Comment("unresolved jump"))
		return i + 1
	end

	while true do
		local merged_skip, merged_target, merged_last = self:Merge(last, stop, skip, target, first_target, first)

		if not merged_skip then
			break
		end

		skip, target, last = merged_skip, merged_target, merged_last
		first = false
	end

	self:FlushAll(info.LiveOut[last])

	local then_start = last + 1

	if target > stop or target <= last then
		local loop = context.Loop
		local body = Statement.Block.new()

		if loop and target == loop.Exit then
			body:Add(Statement.Break())
		elseif loop and (target == loop.Continue or target == loop.Continue2) then
			body:Add(Statement.Continue())
		else
			local landing = info.List[target]

			body:Add(Statement.Comment("goto " .. (landing and landing.Pc or "?")))
		end

		self:Emit(Statement.If(skip, body))

		return then_start
	end

	local enter = Expression.negate(skip)
	local final = target - 1
	local final_kind = info.Kind[final]
	local then_end = target
	local else_end = nil

	if final >= then_start and info.Target[final] and info.Target[final] > target and info.Target[final] <= stop then
		if final_kind == "jump" then
			then_end = final
			else_end = info.Target[final]
		elseif final_kind == "loadb_skip" then
			then_end = target
			else_end = info.Target[final]
		end
	end

	if else_end and final_kind == "loadb_skip" and final == then_start and else_end == target + 1 then
		local first_load = info.List[final]
		local second_load = info.List[target]

		if second_load.OpCodeInfo.Index == op.LOP_LOADB.Index and second_load.C == 0 and second_load.A == first_load.A and second_load.B ~= first_load.B then
			local expression = enter

			if first_load.B ~= 1 then
				expression = Expression.negate(enter)
			end

			self:Define(target, first_load.A, expression)

			if info.Incoming[else_end] == 1 then
				self.Resolved[else_end] = true
			end

			return else_end
		end
	end

	local then_block = Statement.Block.new()

	self:Descend(then_block, function()
		self:Lift(then_start, then_end, context, else_end or target)
	end)

	local else_block = nil

	if else_end then
		else_block = Statement.Block.new()

		self:Descend(else_block, function()
			self:Lift(target, else_end, context, else_end)
		end)
	end

	self:Emit(Statement.If(enter, then_block, else_block))

	return else_end or target
end

function Function:Jump(i, stop, context)
	local info = self.Info
	local target = info.Target[i]
	local loop = context.Loop

	self:FlushAll(info.LiveOut[i])

	if loop and target == loop.Exit then
		self:Emit(Statement.Break())
	elseif loop and (target == loop.Continue or target == loop.Continue2) then
		self:Emit(Statement.Continue())
	elseif target and target ~= stop then
		local landing = info.List[target]

		self:Emit(Statement.Comment("goto " .. (landing and landing.Pc or "?")))
	end

	return i + 1
end

function Function:WhileCondition(body)
	local conditions = {}

	while true do
		local first = body.Statements[1]

		if first and first.Kind == "if" and not first.Else and #first.Then.Statements == 1 and first.Then.Statements[1].Kind == "break" then
			conditions[#conditions + 1] = Expression.negate(first.Condition)
			table.remove(body.Statements, 1)
		else
			break
		end
	end

	if #conditions == 0 then
		return Expression.const("true")
	end

	local result = conditions[1]

	for index = 2, #conditions do
		result = Expression.binop("and", result, conditions[index])
	end

	return result
end

function Function:While(i, last, context)
	local body = Statement.Block.new()
	local inner = { Header = i, Loop = { Exit = last + 1, Continue = i, Continue2 = last }, Parent = context }

	self:Descend(body, function()
		self:Lift(i, last, inner, i)
	end)

	local condition = self:WhileCondition(body)
	local tail = body.Statements[#body.Statements]

	if condition.k == "const" and condition.text == "true" and tail and tail.Kind == "if" and not tail.Else and #tail.Then.Statements == 1 and tail.Then.Statements[1].Kind == "break" then
		table.remove(body.Statements)
		self:Emit(Statement.Repeat(body, tail.Condition))

		return last + 1
	end

	self:Emit(Statement.While(condition, body))

	return last + 1
end

function Function:Repeat(i, last, context)
	local info = self.Info
	local body = Statement.Block.new()
	local inner = { Header = i, Loop = { Exit = last + 1, Continue = last, Continue2 = last }, Parent = context }
	local condition = nil

	self:Descend(body, function()
		self:Lift(i, last, inner, false)
		condition = instructions.Condition(self, last, info.List[last])
		self:FlushAll(info.LiveOut[last])
	end)

	self:Emit(Statement.Repeat(body, Expression.negate(condition)))

	return last + 1
end

function Function:Loop(i, stop, context, sources)
	local info = self.Info
	local last_jump = nil
	local last_cond = nil

	for _, source in ipairs(sources) do
		if source < stop then
			local kind = info.Kind[source]

			if kind == "jump" and (not last_jump or source > last_jump) then
				last_jump = source
			elseif kind == "cond" and (not last_cond or source > last_cond) then
				last_cond = source
			end
		end
	end

	if last_jump then
		return self:While(i, last_jump, context)
	elseif last_cond then
		return self:Repeat(i, last_cond, context)
	end

	return nil
end

function Function:NumericFor(i, stop, context)
	local info = self.Info
	local instruction = info.List[i]
	local A = instruction.A
	local exit = info.Target[i]
	local loop_end = exit - 1
	local operands = self:Take(i, { A + 2, A, A + 1 }, true, true)
	local step = operands[3]

	if step.k == "const" and step.text == "1" then
		step = nil
	end

	local name = self:Declare(A + 2)

	self.Bound[A + 2] = name
	self.Regs[A + 2] = nil

	self:FlushAll(info.LiveOut[i])

	local body = Statement.Block.new()
	local inner = { Loop = { Exit = exit, Continue = loop_end, Continue2 = loop_end }, Parent = context }

	self:Descend(body, function()
		self:Lift(i + 1, loop_end, inner, loop_end)
	end)

	self:Emit(Statement.NumericFor(name, operands[1], operands[2], step, body))

	self.Bound[A + 2] = nil

	return exit
end

function Function:GenericFor(i, stop, context)
	local info = self.Info
	local instruction = info.List[i]
	local A = instruction.A
	local loop_index = info.Target[i]
	local count = bit32.band(instructions.AuxValue(info.List[loop_index]), 0xFF)
	local entry = self.Regs[A]
	local values

	if entry and entry.Multi then
		self:FlushBelow(entry.Seq)
		self.Regs[A] = nil

		for offset = 0, entry.Multi - 1 do
			self.MultiOwner[A + offset] = nil
		end

		values = { entry.Expression }
	else
		values = self:Take(i, { A, A + 1, A + 2 }, true, true)

		while #values > 1 and values[#values].k == "const" and values[#values].text == "nil" do
			table.remove(values)
		end
	end

	local names = {}

	for offset = 1, count do
		local name = self:Declare(A + 2 + offset)

		names[offset] = name
		self.Bound[A + 2 + offset] = name
		self.Regs[A + 2 + offset] = nil
	end

	self:FlushAll(info.LiveOut[i])

	local body = Statement.Block.new()
	local inner = { Loop = { Exit = loop_index + 1, Continue = loop_index, Continue2 = loop_index }, Parent = context }

	self:Descend(body, function()
		self:Lift(i + 1, loop_index, inner, loop_index)
	end)

	self:Emit(Statement.GenericFor(names, values, body))

	for offset = 1, count do
		self.Bound[A + 2 + offset] = nil
	end

	return loop_index + 1
end

function Function:Step(i, stop, context)
	local info = self.Info
	local instruction = info.List[i]

	self.Pc = instruction.Pc

	if info.IsLabel[i] and not self.Resolved[i] then
		self:FlushAll(info.LiveIn[i])
	end

	local sources = info.BackEdges[i]

	if sources and context.Header ~= i then
		local result = self:Loop(i, stop, context, sources)

		if result then
			return result
		end
	end

	local kind = info.Kind[i]

	if kind == "cond" then
		return self:Cond(i, stop, context)
	elseif kind == "jump" then
		return self:Jump(i, stop, context)
	elseif kind == "return" then
		self:Return(i, instruction)

		return i + 1
	elseif kind == "forprep" then
		return self:NumericFor(i, stop, context)
	elseif kind == "forgprep" then
		return self:GenericFor(i, stop, context)
	elseif kind == "loadb_skip" then
		self:Define(i, instruction.A, Expression.const(instruction.B == 1 and "true" or "false"))

		return i + 1
	elseif kind == "forloop" or kind == "forgloop" then
		return i + 1
	end

	local handler = instructions.Handlers[instruction.OpCodeInfo.Index]

	if handler then
		local skip = handler(self, i, instruction)

		return i + 1 + (skip or 0)
	end

	self:Emit(Statement.Comment("unhandled " .. instruction.OpCodeInfo.Name))

	return i + 1
end

function Function:Lift(first, stop, context, join)
	local index = first

	while index < stop do
		index = self:Step(index, stop, context)
	end

	if join ~= false then
		self:FlushAll(self.Info.LiveIn[join or stop] or {})
	end
end

function Function:Build()
	local proto = self.Proto

	for register = 0, proto.ParameterCount - 1 do
		local name = self:Declare(register)

		self.Bound[register] = name
		self.ParamList[#self.ParamList + 1] = name
	end

	if proto.IsVararg then
		self.ParamList[#self.ParamList + 1] = "..."
	end

	for _, name in ipairs(self.Captures) do
		self.CaptureList[#self.CaptureList + 1] = name
	end

	self:Lift(1, self.Info.Count + 1, {}, self.Info.Count + 1)

	local last = self.Body.Statements[#self.Body.Statements]

	if last and last.Kind == "return" and #last.Values == 0 then
		table.remove(self.Body.Statements)
	end

	local predeclared = {}

	for _, name in ipairs(self.ParamList) do
		predeclared[name] = true
	end

	for _, name in ipairs(self.Captures) do
		predeclared[name] = true
	end

	Statement.Finalize(self.Body, predeclared)
end

export type Function = typeof(Function.new(nil :: never, nil :: never))

return Function
