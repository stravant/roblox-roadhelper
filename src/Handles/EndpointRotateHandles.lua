--[[
	EndpointRotateHandles: Arc handles at the selected road endpoint which edit
	the Adjust angle attributes rather than rotating geometry:
	- Dir (about the frame's up axis)
	- Grade (about the frame's lateral axis: positive tips the end's outward
	  direction upward)
	- Bank (about the frame's outward axis)

	The reported angles are right-handed about each axis; the session maps them
	onto attribute deltas for each segment end attached to the joint.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)

local Colors = require(DraggerFramework.Utility.Colors)
local Math = require(DraggerFramework.Utility.Math)
local RotateHandleView = require(DraggerFramework.Components.RotateHandleView)

local RoadMath = require(script.Parent.Parent.RoadMath)

export type AdjustAxis = RoadMath.AdjustAxis

-- Axis of rotation is the handle CFrame's right vector (RotateHandleView
-- convention). Offsets map the endpoint frame onto each rotation axis:
--   Dir: rotate about the frame's up vector
--   Grade: rotate about the frame's right (lateral) vector
--   Bank: rotate about the frame's outward (look) vector
local RotateHandleDefinitions: { [string]: { Offset: CFrame, Color: Color3, RadiusOffset: number } } = {
	Grade = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1)),
		Color = Colors.X_AXIS,
		RadiusOffset = 0.00,
	},
	Dir = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0)),
		Color = Colors.Y_AXIS,
		RadiusOffset = 0.01,
	},
	Bank = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 0, -1), Vector3.new(0, 1, 0), Vector3.new(1, 0, 0)),
		Color = Colors.Z_AXIS,
		RadiusOffset = 0.02,
	},
}

--[[
	Find the angle around the rotation axis where the mouse ray intersects the
	plane perpendicular to the rotation axis. (From Redupe's RotateHandles.)
]]
local function rotationAngleFromRay(cframe: CFrame, unitRay: Ray): number?
	local t = Math.intersectRayPlane(unitRay.Origin, unitRay.Direction, cframe.Position, cframe.RightVector)
	if t >= 0 then
		local mouseWorld = unitRay.Origin + unitRay.Direction * t
		local direction = (mouseWorld - cframe.Position).Unit
		local rx = cframe.LookVector:Dot(direction)
		local ry = cframe.UpVector:Dot(direction)
		local theta = math.atan2(ry, rx)
		if theta < 0 then
			return 2 * math.pi + theta
		else
			return theta
		end
	end
	return nil
end

local function snapToIncrement(angle: number, increment: number): number
	if increment > 0 then
		local angleIncrement = math.rad(increment)
		local snappedAngle = math.floor(angle / angleIncrement + 0.5) * angleIncrement
		if math.abs(angle - math.pi * 2) < math.abs(angle - snappedAngle) then
			return 0
		end
		return snappedAngle
	end
	return angle
end

local EndpointRotateHandles = {}
EndpointRotateHandles.__index = EndpointRotateHandles

export type Props = {
	GetEndpointCFrame: () -> CFrame?,
	-- Restrict to a subset of the Dir/Grade/Bank rings (default: all three)
	Axes: { AdjustAxis }?,
	StartRotate: () -> (),
	ApplyRotate: (axis: AdjustAxis, deltaDegrees: number) -> (),
	EndRotate: () -> (),
}

function EndpointRotateHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, EndpointRotateHandles)
end

function EndpointRotateHandles:update(draggerToolModel, selectionInfo)
	if not self._draggingHandleId then
		self._frame = self._props.GetEndpointCFrame()
	end
	self:_updateHandles()
end

function EndpointRotateHandles:shouldBiasTowardsObjects()
	return false
end

function EndpointRotateHandles:_updateHandles()
	local frame = self._frame
	if not frame then
		self._handles = {}
		return
	end
	local scale = self._draggerContext:getHandleScale(frame.Position)
	local handles = {}
	for handleId, handleDef in RotateHandleDefinitions do
		if self._props.Axes and not table.find(self._props.Axes, handleId :: any) then
			continue
		end
		handles[handleId] = {
			HandleCFrame = frame * handleDef.Offset,
			Color = handleDef.Color,
			RadiusOffset = handleDef.RadiusOffset,
			Scale = scale * 0.6,
		}
	end
	self._handles = handles
end

function EndpointRotateHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestHandleDistance = nil, math.huge
	for handleId, handleProps in self._handles do
		local distance = RotateHandleView.hitTest(handleProps, mouseRay)
		if distance and distance < closestHandleDistance then
			closestHandleDistance = distance
			closestHandleId = handleId
		end
	end
	return closestHandleId, closestHandleDistance, true
end

function EndpointRotateHandles:render(hoveredHandleId)
	local children = {}

	local increment = self._draggerContext:getRotateIncrement()
	local tickAngle
	if increment >= 5 then
		tickAngle = math.rad(increment)
	end

	if self._draggingHandleId and self._handles[self._draggingHandleId] then
		local handleProps = self._handles[self._draggingHandleId]
		local HALF_PI = math.pi / 2
		local snapStartAngle = math.floor(self._startAngle / HALF_PI + 0.5) * HALF_PI
		children[self._draggingHandleId] = Roact.createElement(RotateHandleView, {
			HandleCFrame = handleProps.HandleCFrame,
			Color = handleProps.Color,
			-- The view sweeps from StartAngle to EndAngle; our delta is the raw
			-- right-handed angle (Redupe stored it negated, hence + not -)
			StartAngle = snapStartAngle + self._draggingLastGoodDelta,
			EndAngle = snapStartAngle,
			Scale = handleProps.Scale,
			Hovered = false,
			RadiusOffset = handleProps.RadiusOffset,
			TickAngle = tickAngle,
		})
	else
		for handleId, handleProps in self._handles do
			local hovered = handleId == hoveredHandleId
			local color = handleProps.Color
			local tickAngleToUse
			if hovered then
				tickAngleToUse = tickAngle
			else
				color = Colors.makeDimmed(color)
			end
			children[handleId] = Roact.createElement(RotateHandleView, {
				HandleCFrame = handleProps.HandleCFrame,
				Color = color,
				Scale = handleProps.Scale,
				Hovered = hovered,
				RadiusOffset = handleProps.RadiusOffset,
				TickAngle = tickAngleToUse,
			})
		end
	end

	return Roact.createElement("Folder", {}, children)
end

function EndpointRotateHandles:mouseDown(mouseRay, handleId)
	local handle = self._handles[handleId]
	if not handle then
		return
	end
	local angle = rotationAngleFromRay(handle.HandleCFrame, mouseRay.Unit)
	if not angle then
		return
	end
	self._draggingHandleId = handleId
	self._handleCFrame = handle.HandleCFrame
	self._draggingLastGoodDelta = 0
	self._startAngle = snapToIncrement(angle, self._draggerContext:getRotateIncrement())
	self._props.StartRotate()
end

function EndpointRotateHandles:mouseDrag(mouseRay)
	if not self._draggingHandleId or not self._handles[self._draggingHandleId] then
		return
	end
	local angle = rotationAngleFromRay(self._handleCFrame, mouseRay.Unit)
	if not angle then
		return
	end
	local snappedAngle = snapToIncrement(angle, self._draggerContext:getRotateIncrement())
	local delta = snappedAngle - self._startAngle
	-- Remap to [-pi, pi] so crossing the wrap point doesn't jump 360 degrees
	if delta > math.pi then
		delta -= 2 * math.pi
	elseif delta < -math.pi then
		delta += 2 * math.pi
	end
	self._draggingLastGoodDelta = delta
	self._props.ApplyRotate(self._draggingHandleId :: any, math.deg(delta))
end

function EndpointRotateHandles:mouseUp(mouseRay)
	if not self._draggingHandleId then
		return
	end
	self._draggingHandleId = nil
	self._props.EndRotate()
end

return EndpointRotateHandles
