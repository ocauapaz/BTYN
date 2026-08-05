--!strict
--[[
	Minimal stand-ins for the Roblox value types, so the generated codecs can be
	round-tripped headlessly.

	These implement exactly the surface the emitted code uses and nothing more —
	they are a test fixture, not a Roblox reimplementation.
]]

local shim = {}

shim.source = [==[
local Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

local Color3 = {}
Color3.__index = Color3
function Color3.fromRGB(r, g, b)
	return setmetatable({ R = r / 255, G = g / 255, B = b / 255 }, Color3)
end
function Color3.new(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, Color3)
end

local CFrame = {}
CFrame.__index = CFrame
function CFrame.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, rx = 0, ry = 0, rz = 0 }, CFrame)
end
function CFrame.fromEulerAnglesXYZ(rx, ry, rz)
	return setmetatable({ X = 0, Y = 0, Z = 0, rx = rx, ry = ry, rz = rz }, CFrame)
end
function CFrame.ToEulerAnglesXYZ(self)
	return self.rx, self.ry, self.rz
end
-- Only ever used as `CFrame.new(pos) * CFrame.fromEulerAnglesXYZ(rot)`, which
-- is the one shape the emitter produces.
CFrame.__mul = function(a, b)
	return setmetatable({
		X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z,
		rx = a.rx + b.rx, ry = a.ry + b.ry, rz = a.rz + b.rz,
	}, CFrame)
end

]==]

function shim.Vector3(x: number, y: number, z: number): any
	return { X = x, Y = y, Z = z }
end

function shim.Color3(r: number, g: number, b: number): any
	return { R = r, G = g, B = b }
end

function shim.CFrame(x: number, y: number, z: number, rx: number, ry: number, rz: number): any
	return {
		X = x,
		Y = y,
		Z = z,
		rx = rx,
		ry = ry,
		rz = rz,
		-- The emitted writer calls this on the value it is given, so the method
		-- has to live on the instance the test builds, not only on the shim
		-- class inside the generated chunk.
		ToEulerAnglesXYZ = function(self): (number, number, number)
			return self.rx, self.ry, self.rz
		end,
	}
end

return shim
