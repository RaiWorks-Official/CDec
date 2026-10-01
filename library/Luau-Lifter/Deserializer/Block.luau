local instructions = require("../instructions")

local Block = {}
Block.__type = "Block"
Block.__index = Block

local function union_into(target, source)
	local added = false

	for register in pairs(source) do
		if not target[register] then
			target[register] = true
			added = true
		end
	end

	return added
end

function Block.new(proto)
	local self = setmetatable({}, Block)

	self.MaxStack = proto.MaxStackSize
	self.List = {}
	self.IndexOfPc = {}
	self.Kind = {}
	self.Target = {}
	self.IsLabel = {}
	self.Incoming = {}
	self.BackEdges = {}
	self.Reads = {}
	self.Writes = {}
	self.LiveIn = {}
	self.LiveOut = {}
	self.Successors = {}

	local skip = false
	local total = #proto.Instructions

	for pc = 1, total do
		local instruction = proto.Instructions[pc]

		if skip then
			skip = false
		else
			self.List[#self.List + 1] = instruction
			self.IndexOfPc[instruction.Pc] = #self.List

			if instruction.OpCodeInfo.HasAux then
				skip = true
			end
		end
	end

	self.Count = #self.List

	for index, instruction in ipairs(self.List) do
		self.Kind[index] = instructions.Kind(instruction)

		local offset = instructions.JumpOffset(instruction)

		if offset then
			local target = self.IndexOfPc[instruction.Pc + offset + 1]

			if target then
				self.Target[index] = target
				self.IsLabel[target] = true
				self.Incoming[target] = (self.Incoming[target] or 0) + 1

				if target <= index then
					self.BackEdges[target] = self.BackEdges[target] or {}
					table.insert(self.BackEdges[target], index)
				end
			end
		end

		local previous = nil

		for back = index - 1, math.max(1, index - 8), -1 do
			local candidate = self.List[back]

			if instructions.IsOpener(candidate) and candidate.A >= instruction.A then
				previous = candidate
				break
			end

			if self.Kind[back] ~= "fall" then
				break
			end
		end

		local reads, writes = instructions.Access(instruction, self.MaxStack, previous)

		self.Reads[index] = reads
		self.Writes[index] = writes
		self.LiveIn[index] = {}
		self.LiveOut[index] = {}
	end

	for index = 1, self.Count do
		local kind = self.Kind[index]
		local target = self.Target[index]
		local successors = {}

		if kind == "jump" or kind == "loadb_skip" or kind == "forgprep" then
			successors[#successors + 1] = target
		elseif kind == "return" then
		elseif kind == "cond" or kind == "forprep" then
			successors[#successors + 1] = index + 1
			successors[#successors + 1] = target
		elseif kind == "forloop" or kind == "forgloop" then
			successors[#successors + 1] = target
			successors[#successors + 1] = index + 1
		else
			successors[#successors + 1] = index + 1
		end

		local valid = {}

		for _, successor in ipairs(successors) do
			if successor and successor <= self.Count then
				valid[#valid + 1] = successor
			end
		end

		self.Successors[index] = valid
	end

	local changed = true

	while changed do
		changed = false

		for index = self.Count, 1, -1 do
			local out = self.LiveOut[index]

			for _, successor in ipairs(self.Successors[index]) do
				if union_into(out, self.LiveIn[successor]) then
					changed = true
				end
			end

			local live_in = {}

			for register in pairs(out) do
				live_in[register] = true
			end

			for _, register in ipairs(self.Writes[index]) do
				live_in[register] = nil
			end

			for _, register in ipairs(self.Reads[index]) do
				live_in[register] = true
			end

			if union_into(self.LiveIn[index], live_in) then
				changed = true
			end
		end
	end

	return self
end

function Block:LiveInAt(index)
	return self.LiveIn[index] or {}
end

export type Block = typeof(Block.new(nil :: never))

return Block
