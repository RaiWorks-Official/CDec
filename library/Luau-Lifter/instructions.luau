local LuauSpec = require("@root/Luau/Spec")
local Expression = require("./Expression")
local Statement = require("./Statement")

local op = LuauSpec.LuauOpcode

local instructions = {}

local Access = {}
local Handlers = {}
local Kinds = {}

local function range(from, to)
	local list = {}

	for register = from, to do
		list[#list + 1] = register
	end

	return list
end

local function aux_value(instruction)
	if instruction.AuxValue then
		return instruction.AuxValue.Value
	end

	return 0
end

local function access(name, callback)
	Access[op[name].Index] = callback
end

local function handler(name, callback)
	Handlers[op[name].Index] = callback
end

local none = {}

local function open_top(previous, max_stack)
	if previous then
		local index = previous.OpCodeInfo.Index

		if (index == op.LOP_CALL.Index or index == op.LOP_CALLFB.Index) and previous.C == 0 then
			return previous.A
		elseif index == op.LOP_GETVARARGS.Index and previous.B == 0 then
			return previous.A
		end
	end

	return max_stack
end

for _, name in ipairs({ "LOP_NOP", "LOP_BREAK", "LOP_COVERAGE", "LOP_PREPVARARGS", "LOP_CLOSEUPVALS", "LOP_NATIVECALL", "LOP_JUMP", "LOP_JUMPBACK", "LOP_JUMPX", "LOP_FASTCALL", "LOP_FASTCALL1", "LOP_FASTCALL2", "LOP_FASTCALL2K", "LOP_FASTCALL3", "LOP__COUNT" }) do
	if op[name] then
		access(name, function()
			return none, none
		end)
	end
end

for _, name in ipairs({ "LOP_LOADNIL", "LOP_LOADB", "LOP_LOADN", "LOP_LOADK", "LOP_LOADKX", "LOP_GETGLOBAL", "LOP_GETUPVAL", "LOP_GETIMPORT", "LOP_NEWTABLE", "LOP_DUPTABLE", "LOP_NEWCLOSURE", "LOP_DUPCLOSURE" }) do
	access(name, function(instruction)
		return none, { instruction.A }
	end)
end

for _, name in ipairs({ "LOP_SETGLOBAL", "LOP_SETUPVAL", "LOP_JUMPIF", "LOP_JUMPIFNOT", "LOP_JUMPXEQKNIL", "LOP_JUMPXEQKB", "LOP_JUMPXEQKN", "LOP_JUMPXEQKS" }) do
	access(name, function(instruction)
		return { instruction.A }, none
	end)
end

for _, name in ipairs({ "LOP_JUMPIFEQ", "LOP_JUMPIFLE", "LOP_JUMPIFLT", "LOP_JUMPIFNOTEQ", "LOP_JUMPIFNOTLE", "LOP_JUMPIFNOTLT" }) do
	access(name, function(instruction)
		return { instruction.A, aux_value(instruction) }, none
	end)
end

for _, name in ipairs({ "LOP_MOVE", "LOP_GETTABLEKS", "LOP_GETTABLEN", "LOP_GETUDATAKS", "LOP_NOT", "LOP_MINUS", "LOP_LENGTH", "LOP_ADDK", "LOP_SUBK", "LOP_MULK", "LOP_DIVK", "LOP_MODK", "LOP_POWK", "LOP_IDIVK", "LOP_ANDK", "LOP_ORK" }) do
	access(name, function(instruction)
		return { instruction.B }, { instruction.A }
	end)
end

for _, name in ipairs({ "LOP_SETTABLEKS", "LOP_SETTABLEN", "LOP_SETUDATAKS" }) do
	access(name, function(instruction)
		return { instruction.A, instruction.B }, none
	end)
end

for _, name in ipairs({ "LOP_GETTABLE", "LOP_ADD", "LOP_SUB", "LOP_MUL", "LOP_DIV", "LOP_MOD", "LOP_POW", "LOP_IDIV", "LOP_AND", "LOP_OR" }) do
	access(name, function(instruction)
		return { instruction.B, instruction.C }, { instruction.A }
	end)
end

for _, name in ipairs({ "LOP_SUBRK", "LOP_DIVRK" }) do
	access(name, function(instruction)
		return { instruction.C }, { instruction.A }
	end)
end

access("LOP_SETTABLE", function(instruction)
	return { instruction.A, instruction.B, instruction.C }, none
end)

for _, name in ipairs({ "LOP_NAMECALL", "LOP_NAMECALLUDATA" }) do
	access(name, function(instruction)
		return { instruction.B }, { instruction.A, instruction.A + 1 }
	end)
end

for _, name in ipairs({ "LOP_CALL", "LOP_CALLFB" }) do
	access(name, function(instruction, max_stack, previous)
		local reads
		local writes = none

		if instruction.B == 0 then
			reads = range(instruction.A, open_top(previous, max_stack))
		else
			reads = range(instruction.A, instruction.A + instruction.B - 1)
		end

		if instruction.C > 1 then
			writes = range(instruction.A, instruction.A + instruction.C - 2)
		elseif instruction.C == 0 then
			writes = { instruction.A }
		end

		return reads, writes
	end)
end

access("LOP_RETURN", function(instruction, max_stack, previous)
	if instruction.B == 0 then
		return range(instruction.A, open_top(previous, max_stack)), none
	end

	return range(instruction.A, instruction.A + instruction.B - 2), none
end)

access("LOP_CONCAT", function(instruction)
	return range(instruction.B, instruction.C), { instruction.A }
end)

access("LOP_SETLIST", function(instruction, max_stack, previous)
	local reads = { instruction.A }

	if instruction.C == 0 then
		for _, register in ipairs(range(instruction.B, open_top(previous, max_stack))) do
			reads[#reads + 1] = register
		end
	else
		for _, register in ipairs(range(instruction.B, instruction.B + instruction.C - 2)) do
			reads[#reads + 1] = register
		end
	end

	return reads, none
end)

access("LOP_FORNPREP", function(instruction)
	return { instruction.A, instruction.A + 1, instruction.A + 2 }, { instruction.A + 2 }
end)

access("LOP_FORNLOOP", function(instruction)
	return { instruction.A, instruction.A + 1, instruction.A + 2 }, { instruction.A + 2 }
end)

for _, name in ipairs({ "LOP_FORGPREP", "LOP_FORGPREP_INEXT", "LOP_FORGPREP_NEXT" }) do
	access(name, function(instruction)
		return { instruction.A, instruction.A + 1, instruction.A + 2 }, none
	end)
end

access("LOP_FORGLOOP", function(instruction)
	local count = bit32.band(aux_value(instruction), 0xFF)
	local writes = { instruction.A + 2 }

	for register = instruction.A + 3, instruction.A + 2 + count do
		writes[#writes + 1] = register
	end

	return { instruction.A, instruction.A + 1, instruction.A + 2 }, writes
end)

access("LOP_GETVARARGS", function(instruction)
	if instruction.B > 1 then
		return none, range(instruction.A, instruction.A + instruction.B - 2)
	elseif instruction.B == 0 then
		return none, { instruction.A }
	end

	return none, none
end)

access("LOP_CAPTURE", function(instruction)
	if instruction.A < 2 then
		return { instruction.B }, none
	end

	return none, none
end)

access("LOP_NEWCLASSMEMBER", function(instruction)
	return { instruction.A, instruction.C }, none
end)

function instructions.IsOpener(instruction)
	local index = instruction.OpCodeInfo.Index

	if (index == op.LOP_CALL.Index or index == op.LOP_CALLFB.Index) and instruction.C == 0 then
		return true
	end

	return index == op.LOP_GETVARARGS.Index and instruction.B == 0
end

function instructions.Access(instruction, max_stack, previous)
	local callback = Access[instruction.OpCodeInfo.Index]

	if not callback then
		return none, none
	end

	return callback(instruction, max_stack, previous)
end

for _, name in ipairs({ "LOP_JUMP", "LOP_JUMPBACK", "LOP_JUMPX" }) do
	Kinds[op[name].Index] = "jump"
end

for _, name in ipairs({ "LOP_JUMPIF", "LOP_JUMPIFNOT", "LOP_JUMPIFEQ", "LOP_JUMPIFLE", "LOP_JUMPIFLT", "LOP_JUMPIFNOTEQ", "LOP_JUMPIFNOTLE", "LOP_JUMPIFNOTLT", "LOP_JUMPXEQKNIL", "LOP_JUMPXEQKB", "LOP_JUMPXEQKN", "LOP_JUMPXEQKS" }) do
	Kinds[op[name].Index] = "cond"
end

Kinds[op.LOP_RETURN.Index] = "return"
Kinds[op.LOP_FORNPREP.Index] = "forprep"
Kinds[op.LOP_FORNLOOP.Index] = "forloop"
Kinds[op.LOP_FORGPREP.Index] = "forgprep"
Kinds[op.LOP_FORGPREP_INEXT.Index] = "forgprep"
Kinds[op.LOP_FORGPREP_NEXT.Index] = "forgprep"
Kinds[op.LOP_FORGLOOP.Index] = "forgloop"

function instructions.Kind(instruction)
	local index = instruction.OpCodeInfo.Index

	if index == op.LOP_LOADB.Index and instruction.C ~= 0 then
		return "loadb_skip"
	end

	return Kinds[index] or "fall"
end

local d_jumps = {}

for _, name in ipairs({ "LOP_JUMP", "LOP_JUMPBACK", "LOP_JUMPIF", "LOP_JUMPIFNOT", "LOP_JUMPIFEQ", "LOP_JUMPIFLE", "LOP_JUMPIFLT", "LOP_JUMPIFNOTEQ", "LOP_JUMPIFNOTLE", "LOP_JUMPIFNOTLT", "LOP_FORNPREP", "LOP_FORNLOOP", "LOP_FORGLOOP", "LOP_FORGPREP", "LOP_FORGPREP_INEXT", "LOP_FORGPREP_NEXT", "LOP_JUMPXEQKNIL", "LOP_JUMPXEQKB", "LOP_JUMPXEQKN", "LOP_JUMPXEQKS" }) do
	d_jumps[op[name].Index] = true
end

function instructions.JumpOffset(instruction)
	local index = instruction.OpCodeInfo.Index

	if index == op.LOP_JUMPX.Index then
		return instruction.E
	elseif d_jumps[index] then
		return instruction.D
	elseif index == op.LOP_LOADB.Index and instruction.C ~= 0 then
		return instruction.C
	end

	return nil
end

function instructions.Condition(F, i, instruction)
	local index = instruction.OpCodeInfo.Index
	local aux = aux_value(instruction)

	if index == op.LOP_JUMPIF.Index then
		return F:Take(i, { instruction.A }, true)[1]
	elseif index == op.LOP_JUMPIFNOT.Index then
		return Expression.negate(F:Take(i, { instruction.A }, true)[1])
	end

	local comparison = {
		[op.LOP_JUMPIFEQ.Index] = { "==", false },
		[op.LOP_JUMPIFNOTEQ.Index] = { "~=", false },
		[op.LOP_JUMPIFLE.Index] = { "<=", false },
		[op.LOP_JUMPIFLT.Index] = { "<", false },
		[op.LOP_JUMPIFNOTLE.Index] = { "<=", true },
		[op.LOP_JUMPIFNOTLT.Index] = { "<", true },
	}

	local entry = comparison[index]

	if entry then
		local operands = F:Take(i, { instruction.A, aux }, true)
		local expression = Expression.cmp(entry[1], operands[1], operands[2])

		if entry[2] then
			return Expression.unop("not", expression)
		end

		return expression
	end

	local operand = F:Take(i, { instruction.A }, true)[1]
	local flipped = bit32.btest(aux, 0x80000000)
	local symbol = flipped and "~=" or "=="

	if index == op.LOP_JUMPXEQKNIL.Index then
		return Expression.cmp(symbol, operand, Expression.const("nil"))
	elseif index == op.LOP_JUMPXEQKB.Index then
		return Expression.cmp(symbol, operand, Expression.const(bit32.band(aux, 1) == 1 and "true" or "false"))
	end

	return Expression.cmp(symbol, operand, F:Constant(bit32.band(aux, 0xFFFFFF)))
end

handler("LOP_LOADNIL", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.const("nil"))
end)

handler("LOP_LOADB", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.const(instruction.B == 1 and "true" or "false"))
end)

handler("LOP_LOADN", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.number(tostring(instruction.D)))
end)

handler("LOP_LOADK", function(F, i, instruction)
	F:Define(i, instruction.A, F:Constant(instruction.D))
end)

handler("LOP_LOADKX", function(F, i, instruction)
	F:Define(i, instruction.A, F:Constant(aux_value(instruction)))
end)

handler("LOP_MOVE", function(F, i, instruction)
	F:Define(i, instruction.A, F:Take(i, { instruction.B })[1])
end)

handler("LOP_GETGLOBAL", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.global(F:ConstantString(aux_value(instruction))))
end)

handler("LOP_SETGLOBAL", function(F, i, instruction)
	local value = F:Take(i, { instruction.A }, true)[1]

	F:Emit(Statement.Assign({ Expression.global(F:ConstantString(aux_value(instruction))) }, { value }))
end)

handler("LOP_GETUPVAL", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.upvalue(F:UpvalueName(instruction.B)))
end)

handler("LOP_SETUPVAL", function(F, i, instruction)
	local value = F:Take(i, { instruction.A }, true)[1]

	F:Emit(Statement.Assign({ Expression.upvalue(F:UpvalueName(instruction.B)) }, { value }))
end)

handler("LOP_GETIMPORT", function(F, i, instruction)
	F:Define(i, instruction.A, F:Constant(instruction.D))
end)

handler("LOP_GETTABLE", function(F, i, instruction)
	local operands = F:Take(i, { instruction.B, instruction.C })

	F:Define(i, instruction.A, Expression.index(operands[1], operands[2]))
end)

handler("LOP_GETTABLEKS", function(F, i, instruction)
	local operands = F:Take(i, { instruction.B })
	local name = F:ConstantString(aux_value(instruction))

	F:Define(i, instruction.A, Expression.index(operands[1], Expression.string(name, string.format("%q", name))))
end)

handler("LOP_GETUDATAKS", function(F, i, instruction)
	local operands = F:Take(i, { instruction.B })
	local name = F:ConstantString(bit32.band(aux_value(instruction), 0xFFFF))

	F:Define(i, instruction.A, Expression.index(operands[1], Expression.string(name, string.format("%q", name))))
end)

handler("LOP_GETTABLEN", function(F, i, instruction)
	local operands = F:Take(i, { instruction.B })

	F:Define(i, instruction.A, Expression.index(operands[1], Expression.number(tostring(instruction.C + 1))))
end)

handler("LOP_SETTABLE", function(F, i, instruction)
	F:Store(i, instruction.B, instruction.A, instruction.C, nil)
end)

handler("LOP_SETTABLEKS", function(F, i, instruction)
	local name = F:ConstantString(aux_value(instruction))

	F:Store(i, instruction.B, instruction.A, nil, Expression.string(name, string.format("%q", name)))
end)

handler("LOP_SETUDATAKS", function(F, i, instruction)
	local name = F:ConstantString(bit32.band(aux_value(instruction), 0xFFFF))

	F:Store(i, instruction.B, instruction.A, nil, Expression.string(name, string.format("%q", name)))
end)

handler("LOP_SETTABLEN", function(F, i, instruction)
	F:Store(i, instruction.B, instruction.A, nil, Expression.number(tostring(instruction.C + 1)))
end)

local function namecall(F, i, instruction, name)
	local operands = F:Take(i, { instruction.B })

	F:Define(i, instruction.A, Expression.methodref(operands[1], name))
	F:Define(i, instruction.A + 1, Expression.selfarg())
end

handler("LOP_NAMECALL", function(F, i, instruction)
	namecall(F, i, instruction, F:ConstantString(aux_value(instruction)))
end)

handler("LOP_NAMECALLUDATA", function(F, i, instruction)
	namecall(F, i, instruction, F:ConstantString(bit32.band(aux_value(instruction), 0xFFFF)))
end)

handler("LOP_CALL", function(F, i, instruction)
	F:Call(i, instruction)
end)

handler("LOP_CALLFB", function(F, i, instruction)
	F:Call(i, instruction)
end)

handler("LOP_RETURN", function(F, i, instruction)
	F:Return(i, instruction)
end)

local binary = {
	LOP_ADD = "+",
	LOP_SUB = "-",
	LOP_MUL = "*",
	LOP_DIV = "/",
	LOP_MOD = "%",
	LOP_POW = "^",
	LOP_IDIV = "//",
	LOP_AND = "and",
	LOP_OR = "or",
}

for name, symbol in pairs(binary) do
	handler(name, function(F, i, instruction)
		local operands = F:Take(i, { instruction.B, instruction.C })

		F:Define(i, instruction.A, Expression.binop(symbol, operands[1], operands[2]))
	end)
end

local binary_k = {
	LOP_ADDK = "+",
	LOP_SUBK = "-",
	LOP_MULK = "*",
	LOP_DIVK = "/",
	LOP_MODK = "%",
	LOP_POWK = "^",
	LOP_IDIVK = "//",
	LOP_ANDK = "and",
	LOP_ORK = "or",
}

for name, symbol in pairs(binary_k) do
	handler(name, function(F, i, instruction)
		local operands = F:Take(i, { instruction.B })

		F:Define(i, instruction.A, Expression.binop(symbol, operands[1], F:Constant(instruction.C)))
	end)
end

handler("LOP_SUBRK", function(F, i, instruction)
	local operands = F:Take(i, { instruction.C })

	F:Define(i, instruction.A, Expression.binop("-", F:Constant(instruction.B), operands[1]))
end)

handler("LOP_DIVRK", function(F, i, instruction)
	local operands = F:Take(i, { instruction.C })

	F:Define(i, instruction.A, Expression.binop("/", F:Constant(instruction.B), operands[1]))
end)

handler("LOP_CONCAT", function(F, i, instruction)
	local operands = F:Take(i, range(instruction.B, instruction.C))
	local parts = {}

	for _, operand in ipairs(operands) do
		if operand.k == "concat" then
			for _, part in ipairs(operand.parts) do
				parts[#parts + 1] = part
			end
		else
			parts[#parts + 1] = operand
		end
	end

	F:Define(i, instruction.A, Expression.concat(parts))
end)

handler("LOP_NOT", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.negate(F:Take(i, { instruction.B })[1]))
end)

handler("LOP_MINUS", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.unop("-", F:Take(i, { instruction.B })[1]))
end)

handler("LOP_LENGTH", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.unop("#", F:Take(i, { instruction.B })[1]))
end)

handler("LOP_NEWTABLE", function(F, i, instruction)
	F:Define(i, instruction.A, Expression.table({}, {}))
end)

handler("LOP_DUPTABLE", function(F, i, instruction)
	F:Define(i, instruction.A, F:Constant(instruction.D))
end)

handler("LOP_SETLIST", function(F, i, instruction)
	F:SetList(i, instruction)
end)

handler("LOP_GETVARARGS", function(F, i, instruction)
	F:VarArgs(i, instruction)
end)

handler("LOP_NEWCLOSURE", function(F, i, instruction)
	return F:NewClosure(i, instruction)
end)

handler("LOP_DUPCLOSURE", function(F, i, instruction)
	F:DupClosure(i, instruction)
end)

handler("LOP_NEWCLASSMEMBER", function(F, i, instruction)
	F:Emit(Statement.Comment("class member " .. F:ConstantString(aux_value(instruction))))
end)

for _, name in ipairs({ "LOP_NOP", "LOP_BREAK", "LOP_COVERAGE", "LOP_PREPVARARGS", "LOP_CLOSEUPVALS", "LOP_NATIVECALL", "LOP_FASTCALL", "LOP_FASTCALL1", "LOP_FASTCALL2", "LOP_FASTCALL2K", "LOP_FASTCALL3", "LOP_CAPTURE" }) do
	handler(name, function() end)
end

instructions.Handlers = Handlers
instructions.AuxValue = aux_value

return instructions
