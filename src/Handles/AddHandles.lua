--[[
	AddHandles: Three clickable markers hovering in front of an open selected
	endpoint: add a left turn, straight, or right turn segment extending the
	road. Clicking adds a default-size segment; click-dragging places the new
	segment's far endpoint following the cursor on the XZ plane.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)
local Math = require(DraggerFramework.Utility.Math)

local RoadMath = require(script.Parent.Parent.RoadMath)

local MARKER_SIZE = 2.4
local HIT_RADIUS = 2.2
local AHEAD = 8
local ASIDE = 6
local DRAG_START_THRESHOLD = 3

local STRAIGHT_COLOR = Color3.fromRGB(240, 240, 240)
local TURN_COLOR = Color3.fromRGB(255, 200, 60)

local AddHandleDefinitions: { [string]: { Turn: RoadMath.TurnDirection, Ahead: number, Aside: number, Color: Color3 } } = {
	AddLeft = { Turn = "Left", Ahead = AHEAD * 0.75, Aside = -ASIDE, Color = TURN_COLOR },
	AddStraight = { Turn = "Straight", Ahead = AHEAD, Aside = 0, Color = STRAIGHT_COLOR },
	AddRight = { Turn = "Right", Ahead = AHEAD * 0.75, Aside = ASIDE, Color = TURN_COLOR },
}

local AddHandles = {}
AddHandles.__index = AddHandles

export type Props = {
	-- The selected endpoint if it is open, else nil
	GetOpenEndpoint: () -> RoadMath.Endpoint?,
	-- Create the new segment; returns the plane height for dragging, or nil on failure
	StartAdd: (turn: RoadMath.TurnDirection) -> number?,
	-- Move the new segment's far endpoint to a world position
	ApplyAddDrag: (worldPosition: Vector3) -> (),
	EndAdd: () -> (),
}

function AddHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, AddHandles)
end

function AddHandles:update(draggerToolModel, selectionInfo)
	if self._draggingHandleId then
		return
	end
	local endpoint = self._props.GetOpenEndpoint()
	if not endpoint then
		self._handles = {}
		return
	end
	local frame = endpoint.WorldCFrame
	-- Place the markers off the *actual* (Adjust-rotated) face direction so
	-- they line up with where the added segment will go.
	local outward = RoadMath.actualOutwardDirection(endpoint)
	local up = frame.UpVector
	local aside = outward:Cross(up) -- points to the face's right in plan view... (see below)
	-- outward x up: for outward = +Z, up = +Y: (0,0,1)x(0,1,0) = (-1, 0, 0),
	-- which is the LEFT side when looking along outward from above. So a
	-- negative Aside must mean the right side; flip to keep Aside positive =
	-- right of travel.
	local right = -aside
	local scale = self._draggerContext:getHandleScale(frame.Position)
	local handles = {}
	for handleId, def in AddHandleDefinitions do
		local position = frame.Position
			+ outward * (def.Ahead * scale)
			+ right * (def.Aside * scale)
		handles[handleId] = {
			Turn = def.Turn,
			Position = position,
			Color = def.Color,
			Scale = scale,
			Outward = outward,
			Right = right,
		}
	end
	self._handles = handles
end

function AddHandles:shouldBiasTowardsObjects()
	return false
end

function AddHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestDistance = nil, math.huge
	for handleId, handle in self._handles do
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit,
			handle.Position, HIT_RADIUS * handle.Scale)
		if hit and distance and distance < closestDistance then
			closestDistance = distance
			closestHandleId = handleId
		end
	end
	return closestHandleId, closestDistance, true
end

function AddHandles:render(hoveredHandleId)
	local children = {}
	-- While drag-placing the new segment the add handles are stale (they
	-- belong to the endpoint being extended): hide them until the drag ends.
	if self._draggingHandleId then
		return Roact.createElement("Folder", {}, children)
	end
	for handleId, handle in self._handles do
		local hovered = handleId == hoveredHandleId or handleId == self._draggingHandleId
		local size = MARKER_SIZE * handle.Scale * (if hovered then 1.25 else 1)
		local look: Vector3
		if handle.Turn == "Straight" then
			look = handle.Outward
		elseif handle.Turn == "Right" then
			look = (handle.Outward + handle.Right).Unit
		else
			look = (handle.Outward - handle.Right).Unit
		end
		-- An arrow-ish cone pointing the direction the added road will head
		children[handleId] = Roact.createElement("ConeHandleAdornment", {
			Adornee = workspace.Terrain,
			CFrame = CFrame.lookAlong(handle.Position - look * (size * 0.75), look),
			Height = size * 1.5,
			Radius = size * 0.45,
			Color3 = handle.Color,
			Transparency = if hovered then 0 else 0.25,
			AlwaysOnTop = false,
			ZIndex = 0,
		})
	end
	return Roact.createElement("Folder", {}, children)
end

function AddHandles:mouseDown(mouseRay, handleId)
	local handle = self._handles[handleId]
	if not handle then
		return
	end
	local planeHeight = self._props.StartAdd(handle.Turn)
	if planeHeight == nil then
		return
	end
	self._draggingHandleId = handleId
	self._planeHeight = planeHeight
	self._dragStartRay = mouseRay
	self._didDrag = false
end

function AddHandles:mouseDrag(mouseRay)
	if not self._draggingHandleId then
		return
	end
	-- Require a small movement before starting to drag-place, so a plain
	-- click keeps the default segment size.
	if not self._didDrag then
		local moved = (mouseRay.Direction.Unit - self._dragStartRay.Direction.Unit).Magnitude
			* (self._dragStartRay.Origin - workspace.CurrentCamera.CFrame.Position).Magnitude
		local screenMoved = (mouseRay.Direction.Unit - self._dragStartRay.Direction.Unit).Magnitude * 1000
		if screenMoved < DRAG_START_THRESHOLD and moved < DRAG_START_THRESHOLD then
			return
		end
		self._didDrag = true
	end
	-- Intersect the mouse ray with the horizontal plane at the join height
	local direction = mouseRay.Direction.Unit
	if math.abs(direction.Y) < 1e-4 then
		return
	end
	local t = (self._planeHeight - mouseRay.Origin.Y) / direction.Y
	if t <= 0 then
		return
	end
	local hit = mouseRay.Origin + direction * t
	self._props.ApplyAddDrag(hit)
end

function AddHandles:mouseUp(mouseRay)
	if not self._draggingHandleId then
		return
	end
	self._draggingHandleId = nil
	self._props.EndAdd()
end

return AddHandles
