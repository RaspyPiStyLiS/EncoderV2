-- This is a rough draft
-- Performance can probably be improved a lot
-- But for occasional player data, it is probably not so bad.

local Base64Converter = require("./Base64Converter")
local EncoderFuncs = require("./EncoderFuncs")
local Deduplicator = require("./Deduplicator")
local BitBuffer = require("./BitBuffer")

local Encoder = {}
Encoder.__index = Encoder

function Encoder.new()
	local self = setmetatable({}, Encoder)

	-- this is for data
	self._writer = BitBuffer.Writer.new()
	self._writer:writeFib(1) -- version

	return self
end


-- we will need to have a way to point to the original object

function Encoder:encode(value)
	self:_collectValues(value)
	self:_deduplicateValues()
	self:_createValueLeaves()
	self:_createValueTree()

	self:_collectTypes()
	self:_createTypeLeaves()
	self:_createTypeTree()

	self:_encodeTypeTree(self._typeTree.root)
	self:_encodeValueTree(self._valueTree.root)
	self:_encodeValue(value)
end

function Encoder:dumpToBuffer()
	return self._writer:dump()
end

function Encoder:dumpToString64()
	return Base64Converter.fromBuffer256(self._writer:dump())
end

function Encoder:_deduplicateValues()
	self._deduplicator = Deduplicator.new()

	-- just remove/combine nodes for duplicate values
	for value, node in self._valueToNode do
		local ident = self._deduplicator:index(value, self._literalDataBuff, node.orig, node.cost)
		if rawequal(ident, value) then
			-- yeah we good
		else
			self._valueToNode[value] = nil
			self._valueToNode[ident].freq += node.freq
		end
	end
end

-- eventually this can deduplicate actually
function Encoder:_collectValues(value)

	local writer = BitBuffer.Writer.new()

	local valueToNode = {}
	local function recurse(value)
		if valueToNode[value] then
			valueToNode[value].freq += 1
			return
		end

		local type = EncoderFuncs.subtypeof(writer, value)

		local node = {
			type = type;
			value = value;
			freq = 1;
			cost = nil;
		}
		valueToNode[value] = node

		if type == "table" then
			local listCount = 0
			local hashCount = 0

			local nextIndex = 1
			for i, v in value do
				if i == nextIndex then
					nextIndex += 1
					listCount += 1
					recurse(v)
				else
					nextIndex = nil
					hashCount += 1
					recurse(i)
					recurse(v)
				end
			end

			node.listCount = listCount
			node.hashCount = hashCount
		else
			-- this is getting cached for later
			node.orig = writer:getHead()
			EncoderFuncs.encode(writer, type, value)
			node.cost = writer:getHead() - node.orig
		end
	end

	recurse(value)

	self._literalDataBuff = writer:dump()
	self._valueToNode = valueToNode
end

local ln2 = math.log(2)
local function partialEntropy(x)
	if x == 0 then return 0 end
	return x*math.log(x)/ln2
end

-- cost of going from literal to reference (hopefully negative)
local function litToRefCost(typeFreq, freq, cost)
	return
		- partialEntropy(typeFreq - freq) -- adding the new type cost
		- partialEntropy(freq) -- adding the new cost of encoding a reference 
		+ cost -- adding the one time encoding cost
		+ 2 -- extra encoding cost

		+ partialEntropy(typeFreq) -- removing the old type cost
		- freq*cost -- removing the multi-time encoding cost
end

function Encoder:_createValueLeaves()
	local literalToNode = {}
	local valueLeaves = {}
	local nodes = {}

	-- first, build literal types
	for value, node in self._valueToNode do
		local type = node.type
		local freq = node.freq
		assert(type, "leaves must have a type!")

		local literalNode = literalToNode[type]
		if not literalNode then
			literalNode = {
				type = "_type";
				value = type;
				freq = 0;
				cost = nil;
			}

			literalToNode[type] = literalNode
			table.insert(valueLeaves, literalNode)
		end

		literalNode.freq += freq
	end

	-- make a new table for leaves that we can pluck from
	for value, node in self._valueToNode do
		table.insert(nodes, node)
	end

	repeat
		local changed = false
		for i = #nodes, 1, -1 do
			local node = nodes[i]
			local freq = node.freq
			local type = node.type

			local literalNode = literalToNode[type]

			if
				type == "table" and freq > 1 or
				type ~= "table" and litToRefCost(literalNode.freq, freq, node.cost) < 0
			then
				local n = #nodes
				nodes[i] = nodes[n]
				nodes[n] = nil

				table.insert(valueLeaves, node)
				literalNode.freq -= freq

				changed = true
			end
		end
	until not changed

	self._literalToNode = literalToNode
	self._valueLeaves = valueLeaves
end

function Encoder:_collectTypes()
	local typeToNode = {}

	local function countType(type)
		local typeNode = typeToNode[type]
		if not typeNode then
			typeNode = {
				value = type;
				freq = 0;
			}
			typeToNode[type] = typeNode
		end

		typeNode.freq += 1
	end

	local function recurse(node)
		if node.node0 then
			recurse(node.node0)
			recurse(node.node1)
		else
			countType(node.type)
			if node.type == "_type" then
				countType(node.value)
			end
		end
	end

	recurse(self._valueTree.root)

	self._typeToNode = typeToNode
end

-- we are going to create a tree for names of things.
function Encoder:_createTypeLeaves()
	local typeLeaves = {}

	for type, node in self._typeToNode do
		table.insert(typeLeaves, node)
	end

	self._typeLeaves = typeLeaves
end

local function compareNodes(nodeA, nodeB)
	return nodeA.freq > nodeB.freq
end

local function buildTree(leaves)
	local nodes = table.clone(leaves)
	table.sort(nodes, compareNodes)

	local n = #nodes
	for i = n - 1, 1, -1 do
		local node1 = table.remove(nodes)
		local node0 = table.remove(nodes)

		local freq = node0.freq + node1.freq
		local node = {
			freq = freq;
			node0 = node0;
			node1 = node1;
		}

		local pos = i
		for k, nodeK in next, nodes do
			if not compareNodes(nodeK, node) then
				pos = k
				break
			end
		end

		table.insert(nodes, pos, node)
	end

	local root = nodes[1]
	local leafToBits = {}
	local leafToCode = {}

	local function recurse(node, bits, code, c)
		if node.node0 then
			recurse(node.node0, bits + 1, code + 0*c, 2*c)
			recurse(node.node1, bits + 1, code + 1*c, 2*c)
		else
			leafToBits[node] = bits
			leafToCode[node] = code
		end
	end

	recurse(root, 0, 0, 1)

	return {
		root = root;
		leafToBits = leafToBits;
		leafToCode = leafToCode;
	}
end

function Encoder:_createValueTree()
	self._valueTree = buildTree(self._valueLeaves)
end

function Encoder:_createTypeTree()
	self._typeTree = buildTree(self._typeLeaves)
end

-- yeah maybe this is fine
function Encoder:_encodeTypeTree(node)
	if node.node0 then -- it's a branch
		self._writer:write(1, 0)
		self:_encodeTypeTree(node.node0)
		self:_encodeTypeTree(node.node1)
	else
		self._writer:write(1, 1)
		self._writer:writeFib(#node.value)
		self._writer:writeString(node.value)
		--encodeNode(self, node)
	end
end

function Encoder:_encodeValueTree(node)--, code)
	--code = code or ""
	if node.node0 then
		self._writer:write(1, 0)
		self:_encodeValueTree(node.node0)--, code .. "0")
		self:_encodeValueTree(node.node1)--, code .. "1")
	else
		self._writer:write(1, 1)
		local type = node.type
		local value = node.value
		local typeNode = self._typeToNode[type]
		local success = self._writer:writeCode(self._typeTree, typeNode)
		if type == "_type" then
			local literalNode = self._typeToNode[value]
			local success = self._writer:writeCode(self._typeTree, literalNode)
		elseif type == "table" then
			-- nothing
		else
			self._writer:writeBufferBits(self._literalDataBuff, node.orig, node.cost)
		end
	end
end

--[[
	if we have a reference
		encode the referenceCode
		if it's a table and we are encountering it for the first time, encode the table
	else, it's a literal
		encode the literalCode
		if it's a table and we are encountering it for the first time, encode the table

]]

function Encoder:_encodeValue(value)
	-- this converts the value into its identity value
	value = self._deduplicator:index(value)

	local valueNode = self._valueToNode[value]
	local written = self._writer:writeCode(self._valueTree, valueNode)
	local type = valueNode.type

	if written then
		if type == "table" then
			self:_encodeTable(valueNode)
		end
	else
		local value = valueNode.value
		local literalNode = self._literalToNode[type]
		self._writer:writeCode(self._valueTree, literalNode)
		if type == "table" then
			self:_encodeTable(valueNode)
		else
			self._writer:writeBufferBits(self._literalDataBuff, valueNode.orig, valueNode.cost)
			--EncoderFuncs.encode(self, type, value)
		end
	end
end

function Encoder:_encodeTable(tabNode)
	if tabNode.encoded then
		return
	end
	
	tabNode.encoded = true

	self._writer:writeFib(tabNode.listCount + 1)
	self._writer:writeFib(tabNode.hashCount + 1)

	-- now encode for real
	local nextIndex = 1
	for i, v in tabNode.value do
		if i == nextIndex then
			nextIndex += 1
			self:_encodeValue(v)
		else
			nextIndex = nil
			self:_encodeValue(i)
			self:_encodeValue(v)
		end
	end
end

return Encoder