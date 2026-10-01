local iridium = require("../library/iridium")
local lifter = require("../library/Luau-Lifter/Lifter")

local spec = iridium.LuauSpec
local op = spec.LuauOpcode
local builtins_by_index = spec.LuauBuiltinFunctionByIndex
local capture_types = spec.LuauCaptureTypeByIndex
local capture_type = spec.LuauCaptureType
local proto_flag = spec.LuauProtoFlag

local long_tab = string.rep(" ", 8)
local short_tab = string.rep(" ", 4)

local constant_tag = {
  Nil = "nil",
  Boolean = "bool",
  Number = "number",
  String = "string",
  Import = "import",
  Table = "table",
  Closure = "closure",
  Vector = "vector",
  TableWithConstants = "table+k",
  Integer = "integer",
  ClassShape = "class",
}

local d_jump_opcodes = {}
for _, name in {
  "LOP_JUMP", "LOP_JUMPBACK", "LOP_JUMPIF", "LOP_JUMPIFNOT", "LOP_JUMPIFEQ", "LOP_JUMPIFLE",
  "LOP_JUMPIFLT", "LOP_JUMPIFNOTEQ", "LOP_JUMPIFNOTLE", "LOP_JUMPIFNOTLT", "LOP_FORNPREP",
  "LOP_FORNLOOP", "LOP_FORGLOOP", "LOP_FORGPREP", "LOP_FORGPREP_INEXT", "LOP_FORGPREP_NEXT",
  "LOP_JUMPXEQKNIL", "LOP_JUMPXEQKB", "LOP_JUMPXEQKN", "LOP_JUMPXEQKS",
} do
  d_jump_opcodes[op[name].Index] = true
end

local fastcall_opcodes = {
  [op.LOP_FASTCALL.Index] = true,
  [op.LOP_FASTCALL1.Index] = true,
  [op.LOP_FASTCALL2.Index] = true,
  [op.LOP_FASTCALL2K.Index] = true,
  [op.LOP_FASTCALL3.Index] = true,
}

local arith_symbols = {
  [op.LOP_ADD.Index] = "+",
  [op.LOP_SUB.Index] = "-",
  [op.LOP_MUL.Index] = "*",
  [op.LOP_DIV.Index] = "/",
  [op.LOP_MOD.Index] = "%",
  [op.LOP_POW.Index] = "^",
  [op.LOP_IDIV.Index] = "//",
  [op.LOP_AND.Index] = "and",
  [op.LOP_OR.Index] = "or",
}

local compare_templates = {
  [op.LOP_JUMPIFEQ.Index] = "if R%d == R%d",
  [op.LOP_JUMPIFNOTEQ.Index] = "if R%d ~= R%d",
  [op.LOP_JUMPIFLE.Index] = "if R%d <= R%d",
  [op.LOP_JUMPIFLT.Index] = "if R%d < R%d",
  [op.LOP_JUMPIFNOTLE.Index] = "if not (R%d <= R%d)",
  [op.LOP_JUMPIFNOTLT.Index] = "if not (R%d < R%d)",
}

local arith_k_symbols = {
  [op.LOP_ADDK.Index] = "+",
  [op.LOP_SUBK.Index] = "-",
  [op.LOP_MULK.Index] = "*",
  [op.LOP_DIVK.Index] = "/",
  [op.LOP_MODK.Index] = "%",
  [op.LOP_POWK.Index] = "^",
  [op.LOP_IDIVK.Index] = "//",
}

local function jump_offset(instruction)
  local index = instruction.OpCodeInfo.Index

  if index == op.LOP_JUMPX.Index then
    return instruction.E
  elseif d_jump_opcodes[index] then
    return instruction.D
  elseif fastcall_opcodes[index] then
    return instruction.C
  elseif index == op.LOP_LOADB.Index and instruction.C ~= 0 then
    return instruction.C
  end

  return nil
end

local function has_flag(flags, flag)
  return flags ~= nil and bit32.band(flags, flag) == flag
end

local function raw_const(constant)
  if not constant then
    return "?"
  end
  if constant.__type == "String" then
    return buffer.tostring(constant.Value)
  end
  return tostring(constant)
end

local function val_const(constant)
  return if constant then tostring(constant) else "?"
end

local function multret_count(value)
  return if value == 0 then "MULTRET" else tostring(value - 1)
end

local function describe_type(type_info)
  return if type_info.IsOptional then `{type_info.Name}?` else type_info.Name
end

local function resolve_constants(proto, instruction)
  local index = instruction.OpCodeInfo.Index
  local a, b, c, d = instruction.A, instruction.B, instruction.C, instruction.D
  local aux = if instruction.AuxValue then instruction.AuxValue.Value else 0

  local function k(offset)
    return proto.Constants[offset + 1]
  end

  if arith_symbols[index] then
    return `R{a} = R{b} {arith_symbols[index]} R{c}`
  elseif compare_templates[index] then
    return string.format(compare_templates[index], a, aux)
  elseif index == op.LOP_MOVE.Index then
    return `R{a} = R{b}`
  elseif index == op.LOP_GETUPVAL.Index then
    return `R{a} = U{b}`
  elseif index == op.LOP_SETUPVAL.Index then
    return `U{b} = R{a}`
  elseif index == op.LOP_CLOSEUPVALS.Index then
    return `close upvalues >= R{a}`
  elseif index == op.LOP_GETTABLE.Index then
    return `R{a} = R{b}[R{c}]`
  elseif index == op.LOP_SETTABLE.Index then
    return `R{b}[R{c}] = R{a}`
  elseif index == op.LOP_CONCAT.Index then
    return `R{a} = concat(R{b}..R{c})`
  elseif index == op.LOP_NOT.Index then
    return `R{a} = not R{b}`
  elseif index == op.LOP_MINUS.Index then
    return `R{a} = -R{b}`
  elseif index == op.LOP_LENGTH.Index then
    return `R{a} = #R{b}`
  elseif index == op.LOP_JUMP.Index or index == op.LOP_JUMPBACK.Index or index == op.LOP_JUMPX.Index then
    return "jump"
  elseif index == op.LOP_JUMPIF.Index then
    return `if R{a}`
  elseif index == op.LOP_JUMPIFNOT.Index then
    return `if not R{a}`
  elseif index == op.LOP_FORNPREP.Index then
    return `numeric for prepare (limit R{a}, step R{a + 1}, index R{a + 2})`
  elseif index == op.LOP_FORNLOOP.Index then
    return `numeric for next (limit R{a}, step R{a + 1}, index R{a + 2})`
  elseif index == op.LOP_FORGPREP.Index or index == op.LOP_FORGPREP_INEXT.Index or index == op.LOP_FORGPREP_NEXT.Index then
    return `generic for prepare (R{a}, R{a + 1}, R{a + 2})`
  elseif index == op.LOP_PREPVARARGS.Index then
    return `fixed args: {a}`
  end

  if index == op.LOP_GETIMPORT.Index then
    return `R{a} = {raw_const(k(d))}`
  elseif index == op.LOP_GETGLOBAL.Index then
    return `R{a} = {raw_const(k(aux))}`
  elseif index == op.LOP_SETGLOBAL.Index then
    return `{raw_const(k(aux))} = R{a}`
  elseif index == op.LOP_GETTABLEKS.Index then
    return `R{a} = R{b}.{raw_const(k(aux))}`
  elseif index == op.LOP_SETTABLEKS.Index then
    return `R{b}.{raw_const(k(aux))} = R{a}`
  elseif index == op.LOP_NAMECALL.Index then
    return `R{a} = R{b}:{raw_const(k(aux))}()`
  elseif index == op.LOP_GETUDATAKS.Index then
    return `R{a} = R{b}.{raw_const(k(bit32.band(aux, 0xFFFF)))}`
  elseif index == op.LOP_SETUDATAKS.Index then
    return `R{b}.{raw_const(k(bit32.band(aux, 0xFFFF)))} = R{a}`
  elseif index == op.LOP_NAMECALLUDATA.Index then
    return `R{a} = R{b}:{raw_const(k(bit32.band(aux, 0xFFFF)))}()`
  elseif index == op.LOP_GETTABLEN.Index then
    return `R{a} = R{b}[{c + 1}]`
  elseif index == op.LOP_SETTABLEN.Index then
    return `R{b}[{c + 1}] = R{a}`
  elseif index == op.LOP_LOADK.Index then
    return `R{a} = {val_const(k(d))}`
  elseif index == op.LOP_LOADKX.Index then
    return `R{a} = {val_const(k(aux))}`
  elseif index == op.LOP_LOADN.Index then
    return `R{a} = {d}`
  elseif index == op.LOP_LOADB.Index then
    local skip_text = if c ~= 0 then ", skip " .. tostring(c) else ""
    return `R{a} = {b == 1}{skip_text}`
  elseif index == op.LOP_LOADNIL.Index then
    return `R{a} = nil`
  elseif index == op.LOP_DUPTABLE.Index or index == op.LOP_DUPCLOSURE.Index then
    return `R{a} = {val_const(k(d))}`
  elseif index == op.LOP_NEWCLOSURE.Index then
    return `R{a} = function()`
  elseif arith_k_symbols[index] then
    return `R{a} = R{b} {arith_k_symbols[index]} {raw_const(k(c))}`
  elseif index == op.LOP_ANDK.Index then
    return `R{a} = R{b} and {val_const(k(c))}`
  elseif index == op.LOP_ORK.Index then
    return `R{a} = R{b} or {val_const(k(c))}`
  elseif index == op.LOP_SUBRK.Index then
    return `R{a} = {raw_const(k(b))} - R{c}`
  elseif index == op.LOP_DIVRK.Index then
    return `R{a} = {raw_const(k(b))} / R{c}`
  elseif index == op.LOP_FASTCALL2K.Index then
    return `{builtins_by_index[a] or a}(R{b}, {val_const(k(aux))})`
  elseif index == op.LOP_NEWCLASSMEMBER.Index then
    return `.{raw_const(k(aux))} = R{c}`
  elseif index == op.LOP_JUMPXEQKNIL.Index then
    return `if R{a} {if bit32.btest(aux, 0x80000000) then "~=" else "=="} nil`
  elseif index == op.LOP_JUMPXEQKB.Index then
    return `if R{a} {if bit32.btest(aux, 0x80000000) then "~=" else "=="} {bit32.band(aux, 1) == 1}`
  elseif index == op.LOP_JUMPXEQKN.Index or index == op.LOP_JUMPXEQKS.Index then
    return `if R{a} {if bit32.btest(aux, 0x80000000) then "~=" else "=="} {val_const(k(bit32.band(aux, 0xFFFFFF)))}`
  elseif index == op.LOP_CALL.Index or index == op.LOP_CALLFB.Index then
    return `call R{a}, args={multret_count(b)}, results={multret_count(c)}`
  elseif index == op.LOP_RETURN.Index then
    return `return {multret_count(b)} value(s) from R{a}`
  elseif index == op.LOP_GETVARARGS.Index then
    return `R{a}.. = ... ({multret_count(b)})`
  elseif index == op.LOP_SETLIST.Index then
    return `R{a}[{aux}..] = R{b}.. ({multret_count(c)} value(s))`
  elseif index == op.LOP_NEWTABLE.Index then
    return `R{a} = table (array {aux}, hash {if b == 0 then 0 else 2 ^ (b - 1)})`
  elseif index == op.LOP_FORGLOOP.Index then
    return `for-in loop, {bit32.band(aux, 0xFF)} variable(s)`
  end

  return nil
end

local function semantic_note(instruction)
  local index = instruction.OpCodeInfo.Index

  if index == op.LOP_CAPTURE.Index then
    local kind = capture_types[instruction.A] or `?{instruction.A}`
    local source = if instruction.A == capture_type.LCT_UPVAL then `U{instruction.B}` else `R{instruction.B}`
    return `{kind} {source}`
  elseif fastcall_opcodes[index] then
    return builtins_by_index[instruction.A] or `LBF_?{instruction.A}`
  end

  return nil
end

local function render_proto(out, proto, proto_index, main_proto)
  local label = if proto == main_proto then "main" else (proto.Name or `anonymous{proto_index}`)
  local param_types = if proto.FunctionType then proto.FunctionType.ParameterTypes else nil
  local args = {}

  for arg_index = 1, proto.ParameterCount do
    local annotation = if param_types and param_types[arg_index] then `: {describe_type(param_types[arg_index])}` else ""
    table.insert(args, `arg{arg_index}{annotation}`)
  end

  if proto.IsVararg then
    table.insert(args, "...")
  end

  if has_flag(proto.Flags, proto_flag.LPF_NATIVE_FUNCTION) then
    table.insert(out, "@native")
  end

  local signature = `function {label}({table.concat(args, ", ")})`

  if proto.LineDefined ~= 0 then
    signature ..= `{short_tab}@ line {proto.LineDefined}`
  end

  if has_flag(proto.Flags, proto_flag.LPF_NATIVE_COLD) then
    signature ..= `{short_tab}(Not profitable to compile natively)`
  end

  table.insert(out, signature)
  table.insert(out, `{short_tab}-- frame: {proto.MaxStackSize} regs, {proto.ParameterCount} param(s), {proto.UpvalueCount} upvalue(s), {proto.ProtoCount} child proto(s)`)

  for upvalue_index, upvalue_type in proto.UpvalueTypes do
    table.insert(out, `{short_tab}-- U{upvalue_index - 1}: {describe_type(upvalue_type)}`)
  end

  for _, local_type in proto.LocalTypes do
    table.insert(out, `{short_tab}-- R{local_type.Register}: {describe_type(local_type)} (pc {local_type.StartPc}..{local_type.EndPc})`)
  end

  if proto.HasDebugInfo then
    for _, local_variable in proto.LocalVariables do
      table.insert(out, `{short_tab}-- local "{local_variable.Name}" -> R{local_variable.Register} (pc {local_variable.StartPc}..{local_variable.EndPc})`)
    end
    for upvalue_index, debug_upvalue in proto.Upvalues do
      table.insert(out, `{short_tab}-- upvalue U{upvalue_index - 1} = "{debug_upvalue.Name}"`)
    end
  end

  if proto.ConstantCount > 0 then
    table.insert(out, `{short_tab}-- constants ({proto.ConstantCount}):`)
    for constant_index, constant in proto.Constants do
      local name = `K{constant_index - 1}`
      local tag = constant_tag[constant.__type] or constant.__type
      table.insert(out, `{short_tab}{short_tab}{name}{string.rep(" ", math.max(1, 6 - #name))}{tag}{string.rep(" ", math.max(1, 9 - #tag))}{tostring(constant)}`)
    end
  end

  local real = {}
  local skip_next = false

  for _, instruction in proto.Instructions do
    if skip_next then
      skip_next = false
    else
      table.insert(real, instruction)
      if instruction.OpCodeInfo.HasAux then
        skip_next = true
      end
    end
  end

  local name_width = 0
  local regs_width = 0
  local regs_by_pc = {}

  for _, instruction in real do
    local regs = `A: {instruction.A}, B: {instruction.B}, C: {instruction.C}, D: {instruction.D}, E: {instruction.E}`
    regs_by_pc[instruction.Pc] = regs
    name_width = math.max(name_width, #instruction.OpCodeInfo.Name)
    regs_width = math.max(regs_width, #regs)
  end

  local jump_targets = {}
  local jump_of = {}

  for _, instruction in real do
    local offset = jump_offset(instruction)
    if offset then
      local target = instruction.Pc + offset + 1
      jump_targets[target] = true
      jump_of[instruction.Pc] = target
    end
  end

  for _, instruction in real do
    local pc = instruction.Pc

    if jump_targets[pc] then
      table.insert(out, `{short_tab}label_{pc}:`)
    end

    local name = instruction.OpCodeInfo.Name
    local line = `{long_tab}[{pc}]{short_tab}{name}{string.rep(" ", name_width - #name)}{short_tab}{regs_by_pc[pc]}`

    local resolved = resolve_constants(proto, instruction)
    local note = semantic_note(instruction)

    if resolved then
      line ..= `{short_tab}; {resolved}`
    elseif note then
      line ..= `{short_tab}; {note}`
    end

    if instruction.LineDefined ~= 0 then
      line ..= `{short_tab}{string.rep(" ", regs_width - #regs_by_pc[pc])}@ line {instruction.LineDefined}`
    end

    if jump_of[pc] then
      line ..= `{long_tab}goto label_{jump_of[pc]}`
    end

    if instruction.OpCodeInfo.HasAux then
      line ..= `{long_tab}AUX: {tostring(instruction.AuxValue)}`
    end

    table.insert(out, line)
  end

  table.insert(out, "")
end

local function build_source(shared, deserialized)
  local out = {}

  if deserialized.HasRobloxEnvelope then
    table.insert(out, `-- Roblox envelope detected (v{deserialized.RobloxTrailerVersion}, {deserialized.RobloxTrailerSize} bytes)`)
  end

  table.insert(out, `-- Bytecode v{deserialized.BytecodeVersion}, types v{deserialized.TypesVersion or "n/a"}, {deserialized.ProtoCount} proto(s)`)

  if next(deserialized.UserdataNames) then
    table.insert(out, "-- userdata types:")
    for index, name in deserialized.UserdataNames do
      table.insert(out, `--   [{index}] {name}`)
    end
  end

  table.insert(out, "")

  if has_flag(shared.mainproto.Flags, proto_flag.LPF_NATIVE_MODULE) then
    table.insert(out, "--!native")
    table.insert(out, "")
  end

  for proto_index, proto in shared.proto do
    render_proto(out, proto, proto_index, shared.mainproto)
  end

  return table.concat(out, "\n")
end

local function format_header(elapsed, version, face)
  return string.format(
    "-- Decompiled in %.4fs\n-- Bytecode V%s\n-- %s\n\n",
    elapsed,
    version and tostring(version) or "?",
    face
  )
end

return function(bytecode)
  local start_time = os.clock()
  local version = nil

  if type(bytecode) == "string" and #bytecode > 0 then
    version = string.byte(bytecode, 1)
  end

  local shared = {
    bytecode = bytecode,
    mainproto = nil,
    proto = nil,
    constants = nil,
  }

  local success, result = pcall(function()
    local deserialized = iridium:Deserialize(bytecode)

    version = deserialized.BytecodeVersion
    shared.proto = deserialized.Protos
    shared.mainproto = deserialized.Protos[deserialized.ProtoEntryPoint]
    shared.constants = shared.mainproto.Constants

    local lift_success, lifted = pcall(function()
      return lifter.new(deserialized):Lift()
    end)

    if lift_success and type(lifted) == "string" then
      return lifted
    end

    return "-- lifter failed: " .. tostring(lifted) .. "\n\n" .. build_source(shared, deserialized)
  end)

  local elapsed = os.clock() - start_time

  if success and type(result) == "string" then
    return format_header(elapsed, version, ":)") .. result
  end

  return format_header(elapsed, version, ":(") .. "-- Failed :<"
end
