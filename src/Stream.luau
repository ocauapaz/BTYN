--!strict
--!native
--[[
	A growable write cursor over a buffer.

	One of these exists per player per reliability channel, plus a scratch one
	for broadcasts. They are reused across frames and never shrink: a session
	settles at its own peak size within seconds, and reallocating every frame
	would cost more than the memory ever does.

	Instances cannot live inside a buffer, so anything of that type writes an
	index here and rides alongside the payload in `refs`.
]]

local Stream = {}

export type Stream = {
	buf: buffer,
	cursor: number,
	refs: { Instance },
}

local INITIAL_CAPACITY = 256

function Stream.new(capacity: number?): Stream
	return {
		buf = buffer.create(capacity or INITIAL_CAPACITY),
		cursor = 0,
		refs = {},
	}
end

--[[
	Ensures room for `bytes` more and returns the buffer and the offset to write
	at. One capacity check per packet, not per field.
]]
function Stream.begin(stream: Stream, bytes: number): (buffer, number)
	local cursor = stream.cursor
	local required = cursor + bytes
	local capacity = buffer.len(stream.buf)

	if required > capacity then
		local grown = capacity
		repeat
			grown *= 2
		until grown >= required

		local replacement = buffer.create(grown)
		buffer.copy(replacement, 0, stream.buf, 0, cursor)
		stream.buf = replacement
	end

	return stream.buf, cursor
end

--[[
	Commits `bytes` actually written. A fixed packet always commits what it
	reserved; a dynamic one usually commits less.
]]
function Stream.finish(stream: Stream, bytes: number)
	stream.cursor += bytes
end

function Stream.isEmpty(stream: Stream): boolean
	return stream.cursor == 0
end

function Stream.reset(stream: Stream)
	stream.cursor = 0
	if next(stream.refs) ~= nil then
		table.clear(stream.refs)
	end
end

--[[
	Produces the exactly-sized buffer to put on the wire, then resets.

	This is the only allocation on the send path, and there is one per flush
	rather than one per packet.
]]
function Stream.take(stream: Stream): (buffer, { Instance }?)
	local payload = buffer.create(stream.cursor)
	buffer.copy(payload, 0, stream.buf, 0, stream.cursor)

	local refs: { Instance }? = nil
	if next(stream.refs) ~= nil then
		refs = table.clone(stream.refs)
	end

	Stream.reset(stream)
	return payload, refs
end

--[[
	Appends another stream's bytes verbatim.

	This is what makes a filtered broadcast cheap: serialise once into a scratch
	stream, then memcpy it into each recipient's batch. Most libraries either
	re-serialise per recipient or lean on FireAllClients, which cannot do
	interest filtering at all.

	Only valid for packets with no Instance fields. Instance indices are
	relative to the batch that holds them, so splicing bytes into a batch that
	already has refs would silently resolve them to the wrong objects. The
	compiler knows which packets carry an Instance and emits a per-recipient
	loop for those instead, so this guard should never fire in generated code.
]]
function Stream.append(target: Stream, source: Stream)
	local length = source.cursor
	if length == 0 then
		return
	end

	if next(source.refs) ~= nil then
		error("btyn: cannot splice a packet that carries Instance references", 0)
	end

	local buf, offset = Stream.begin(target, length)
	buffer.copy(buf, offset, source.buf, 0, length)
	target.cursor += length
end

return Stream
