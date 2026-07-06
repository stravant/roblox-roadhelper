--[[
	EndpointMoveHandles: Axis arrow handles for moving the selected road
	endpoint. Compact adaptation of Redupe's MoveHandles: dragging an arrow
	moves the endpoint along that axis of its nominal frame; the session
	resizes/repositions the affected segment(s) to follow.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)

local Colors = require(DraggerFramework.Utility.Colors)
local Math = require(DraggerFramework.Utility.Math)
local computeDraggedDistance = require(DraggerFramework.Utility.computeDraggedDistance)

local MoveHandleView = require(script.Parent.Parent.Dragger.MoveHandleView)

local RoadMath = require(script.Parent.Parent.RoadMath)

local DraggerService = game:GetService("DraggerService")

local ALWAYS_ON_TOP = true
local OUTSET = 0.5
local FREE_HANDLE_ID = "FreeDrag"
local FREE_RADIUS = 1.1
local FREE_HIT_RADIUS = 1.5
local FREE_COLOR = Color3.fromRGB(245, 245, 245)
local RAY_LENGTH = 10000

local MoveHandleDefinitions = {
	MinusZ = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0)),
		Color = Colors.Z_AXIS,
	},
	PlusZ = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(1, 0, 0), Vector3.new(0, -1, 0)),
		Color = Colors.Z_AXIS,
	},
	MinusY = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0)),
		Color = Colors.Y_AXIS,
	},
	PlusY = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0)),
		Color = Colors.Y_AXIS,
	},
	MinusX = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1)),
		Color = Colors.X_AXIS,
	},
	PlusX = {
		Offset = CFrame.fromMatrix(Vector3.new(), Vector3.new(0, 1, 0), Vector3.new(0, 0, -1)),
		Color = Colors.X_AXIS,
	},
}

local EndpointMoveHandles = {}
EndpointMoveHandles.__index = EndpointMoveHandles

export type Props = {
	GetEndpointCFrame: () -> CFrame?,
	-- Instances the free-drag raycast should pass through (the segments
	-- being moved by the drag)
	GetDragExclusions: () -> { Instance },
	StartMove: () -> (),
	ApplyMove: (newWorldPosition: Vector3) -> (),
	EndMove: () -> (),
}

function EndpointMoveHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, EndpointMoveHandles)
end

function EndpointMoveHandles:update(draggerToolModel, selectionInfo)
	if not self._draggingHandleId then
		self._frame = self._props.GetEndpointCFrame()
	end
	self:_updateHandles()
end

function EndpointMoveHandles:shouldBiasTowardsObjects()
	return false
end

function EndpointMoveHandles:_updateHandles()
	local frame = self._frame
	if not frame then
		self._handles = {}
		return
	end
	local scale = self._draggerContext:getHandleScale(frame.Position)
	local handles = {}
	for handleId, handleDef in MoveHandleDefinitions do
		handles[handleId] = {
			Axis = frame * handleDef.Offset,
			Color = handleDef.Color,
			Scale = scale,
			Outset = OUTSET,
			FixedOutset = 0,
			AlwaysOnTop = ALWAYS_ON_TOP,
		}
	end
	self._handles = handles
end

function EndpointMoveHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestHandleDistance = nil, math.huge
	for handleId, handleProps in self._handles do
		local distance = MoveHandleView.hitTest(handleProps, mouseRay)
		if distance and distance < closestHandleDistance then
			closestHandleDistance = distance
			closestHandleId = handleId
		end
	end
	-- The central free-drag sphere
	local frame = self._frame
	if frame then
		local scale = self._draggerContext:getHandleScale(frame.Position)
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit,
			frame.Position, FREE_HIT_RADIUS * scale)
		if hit and distance and distance < closestHandleDistance then
			closestHandleDistance = distance
			closestHandleId = FREE_HANDLE_ID
		end
	end
	return closestHandleId, closestHandleDistance, ALWAYS_ON_TOP
end

function EndpointMoveHandles:_renderFreeHandle(children, hovered: boolean)
	local frame = self._frame
	if not frame then
		return
	end
	local scale = self._draggerContext:getHandleScale(frame.Position)
	children[FREE_HANDLE_ID] = Roact.createElement("SphereHandleAdornment", {
		Adornee = workspace.Terrain,
		CFrame = CFrame.new(frame.Position),
		Radius = FREE_RADIUS * scale * (if hovered then 1.2 else 1),
		Color3 = FREE_COLOR,
		Transparency = if hovered then 0 else 0.25,
		AlwaysOnTop = false,
		AdornShading = Enum.AdornShading.XRay,
		ZIndex = 0,
	})
end

function EndpointMoveHandles:render(hoveredHandleId)
	local children = {}
	if self._draggingHandleId == FREE_HANDLE_ID then
		self:_renderFreeHandle(children, true)
		return Roact.createElement("Folder", {}, children)
	end
	if self._draggingHandleId and self._handles[self._draggingHandleId] then
		local handleProps = self._handles[self._draggingHandleId]
		children[self._draggingHandleId] = Roact.createElement(MoveHandleView, {
			Axis = handleProps.Axis,
			Outset = handleProps.Outset,
			FixedOutset = 0,
			Color = handleProps.Color,
			Scale = handleProps.Scale,
			AlwaysOnTop = ALWAYS_ON_TOP,
			Hovered = false,
		})
	else
		for handleId, handleProps in self._handles do
			local hovered = handleId == hoveredHandleId
			local color = handleProps.Color
			if not hovered then
				color = Colors.makeDimmed(color)
			end
			children[handleId] = Roact.createElement(MoveHandleView, {
				Axis = handleProps.Axis,
				Outset = handleProps.Outset,
				FixedOutset = 0,
				Color = color,
				Scale = handleProps.Scale,
				AlwaysOnTop = ALWAYS_ON_TOP,
				Hovered = hovered,
			})
		end
	end
	if not self._draggingHandleId then
		self:_renderFreeHandle(children, hoveredHandleId == FREE_HANDLE_ID)
	end
	return Roact.createElement("Folder", {}, children)
end

function EndpointMoveHandles:_getDistanceAlongAxis(mouseRay)
	return computeDraggedDistance(self._startPosition, self._axis, mouseRay)
end

local function snapToGrid(delta: number): number
	if DraggerService.LinearSnapEnabled then
		local snap = DraggerService.LinearSnapIncrement
		if snap > 0 then
			return math.floor(delta / snap + 0.5) * snap
		end
	end
	return delta
end

function EndpointMoveHandles:mouseDown(mouseRay, handleId)
	if not self._frame then
		return
	end
	if handleId == FREE_HANDLE_ID then
		self._draggingHandleId = FREE_HANDLE_ID
		self._startPosition = self._frame.Position
		self._dragExclusions = self._props.GetDragExclusions()
		self._props.StartMove()
		return
	end
	local handle = self._handles[handleId]
	if not handle then
		return
	end
	self._draggingHandleId = handleId
	self._axis = handle.Axis.LookVector
	self._startPosition = self._frame.Position
	local hasDistance, distance = self:_getDistanceAlongAxis(mouseRay)
	self._startDistance = if hasDistance then distance else 0
	self._props.StartMove()
end

function EndpointMoveHandles:_freeDragTarget(mouseRay): Vector3?
	-- Move the endpoint to whatever is under the cursor, letting the ray pass
	-- through the segments being moved.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = self._dragExclusions or {}
	local result = workspace:Raycast(mouseRay.Origin, mouseRay.Direction.Unit * RAY_LENGTH, params)
	if result then
		return result.Position
	end
	-- Nothing under the cursor: fall back to the horizontal plane through
	-- the position the drag started at.
	local direction = mouseRay.Direction.Unit
	if math.abs(direction.Y) < 1e-4 then
		return nil
	end
	local t = (self._startPosition.Y - mouseRay.Origin.Y) / direction.Y
	if t <= 0 then
		return nil
	end
	return mouseRay.Origin + direction * t
end

function EndpointMoveHandles:mouseDrag(mouseRay)
	if not self._draggingHandleId then
		return
	end
	if self._draggingHandleId == FREE_HANDLE_ID then
		local target = self:_freeDragTarget(mouseRay)
		if target then
			local delta = target - self._startPosition
			delta = Vector3.new(snapToGrid(delta.X), snapToGrid(delta.Y), snapToGrid(delta.Z))
			self._props.ApplyMove(self._startPosition + delta)
		end
		return
	end
	local hasDistance, distance = self:_getDistanceAlongAxis(mouseRay)
	if not hasDistance then
		return
	end
	local delta = snapToGrid(distance - self._startDistance)
	self._props.ApplyMove(self._startPosition + self._axis * delta)
end

function EndpointMoveHandles:mouseUp(mouseRay)
	if not self._draggingHandleId then
		return
	end
	self._draggingHandleId = nil
	self._props.EndMove()
end

return EndpointMoveHandles
