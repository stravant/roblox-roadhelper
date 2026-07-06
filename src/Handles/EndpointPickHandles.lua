--[[
	EndpointPickHandles: On-demand endpoint picking. Instead of eagerly showing
	markers for every endpoint in the place, hovering over road geometry
	raycasts under the cursor, finds the segment it belongs to, and offers that
	segment's nearer endpoint as a click target (shown as a hover marker).
	The selected endpoint always shows its marker.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)

local RoadMath = require(script.Parent.Parent.RoadMath)

local BLUE = Color3.fromRGB(70, 130, 255)
local RED = Color3.fromRGB(255, 70, 70)
local HOVER_RECT_THICKNESS = 0.5
local HOVER_HANDLE_ID = "RoadEndpointHover"
local DESELECT_HANDLE_ID = "RoadEndpointDeselect"
local RAY_LENGTH = 10000

local EndpointPickHandles = {}
EndpointPickHandles.__index = EndpointPickHandles

export type Props = {
	GetSelectedEndpoint: () -> RoadMath.Endpoint?,
	Select: (endpoint: RoadMath.Endpoint) -> (),
	Deselect: () -> (),
}

function EndpointPickHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._hoverEndpoint = nil
	return setmetatable(self, EndpointPickHandles)
end

function EndpointPickHandles:update(draggerToolModel, selectionInfo)
end

function EndpointPickHandles:shouldBiasTowardsObjects()
	return false
end

function EndpointPickHandles:hitTest(mouseRay, ignoreExtraThreshold)
	self._hoverEndpoint = nil
	local result = workspace:Raycast(mouseRay.Origin, mouseRay.Direction.Unit * RAY_LENGTH)
	if result then
		local segment = RoadMath.segmentFromDescendant(result.Instance)
		if segment then
			local blue, red = RoadMath.getEndpoints(segment)
			local blueDistance = (blue.WorldCFrame.Position - result.Position).Magnitude
			local redDistance = (red.WorldCFrame.Position - result.Position).Magnitude
			self._hoverEndpoint = if blueDistance <= redDistance then blue else red
			return HOVER_HANDLE_ID, result.Distance, false
		end
	end
	-- Clicking anything which isn't a road segment (including the sky)
	-- deselects, so the user can clear the handles away to inspect results.
	local distance = if result then result.Distance else RAY_LENGTH
	return DESELECT_HANDLE_ID, distance, false
end

local function isSameEndpoint(a: RoadMath.Endpoint?, b: RoadMath.Endpoint?): boolean
	return a ~= nil and b ~= nil and a.Segment.Model == b.Segment.Model and a.Id == b.Id
end

function EndpointPickHandles:render(hoveredHandleId)
	local children = {}
	-- No selection visual: the move/rotate handles sitting at the endpoint
	-- already communicate what is selected. Hovering shows an always-on-top
	-- rectangle laid over the end of the segment about to be picked.
	local selected = self._props.GetSelectedEndpoint()
	local hover = self._hoverEndpoint
	if hoveredHandleId == HOVER_HANDLE_ID and hover and not isSameEndpoint(hover, selected) then
		local frame = hover.WorldCFrame
		local width = hover.Segment.Width
		local depth = math.min(width * 0.25, 20)
		children.HoverRect = Roact.createElement("BoxHandleAdornment", {
			Adornee = workspace.Terrain,
			-- The frame's LookVector is the outward direction (-Z), so +Z in
			-- frame space points into the segment: lay the rectangle over the
			-- last stretch of road before the end face.
			CFrame = frame * CFrame.new(0, 0, depth / 2),
			Size = Vector3.new(width, HOVER_RECT_THICKNESS, depth),
			Color3 = if hover.Id == "Blue" then BLUE else RED,
			Transparency = 0.5,
			AlwaysOnTop = true,
			ZIndex = 0,
		})
	end
	return Roact.createElement("Folder", {}, children)
end

function EndpointPickHandles:mouseDown(mouseRay, handleId)
	if handleId == HOVER_HANDLE_ID and self._hoverEndpoint then
		self._props.Select(self._hoverEndpoint)
	elseif handleId == DESELECT_HANDLE_ID then
		self._props.Deselect()
	end
end

function EndpointPickHandles:mouseDrag(mouseRay)
end

function EndpointPickHandles:mouseUp(mouseRay)
end

return EndpointPickHandles
