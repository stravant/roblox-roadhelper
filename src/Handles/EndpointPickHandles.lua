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
local PURPLE = Color3.fromRGB(170, 85, 255)
local HOVER_RECT_THICKNESS = 0.5
local HOVER_HANDLE_ID = "RoadEndpointHover"
local DESELECT_HANDLE_ID = "RoadEndpointDeselect"
local RAY_LENGTH = 10000

local EndpointPickHandles = {}
EndpointPickHandles.__index = EndpointPickHandles

export type Props = {
	GetSelectedEndpoint: () -> RoadMath.Endpoint?,
	GetPartner: (endpoint: RoadMath.Endpoint) -> RoadMath.Endpoint?,
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
		local partner = self._props.GetPartner(hover)
		if partner and isSameEndpoint(partner, selected) then
			-- The hovered end is the mate of the selected one: the joint is
			-- already selected, so offer no re-pick affordance for it.
			return Roact.createElement("Folder", {}, children)
		end
		local frame = hover.WorldCFrame
		local width = hover.Segment.Width
		local color = if hover.Id == "Blue" then BLUE else RED
		local intoSegment = true
		if partner then
			-- Closed joint: one purple marker centred on the join, looking
			-- identical whichever side is hovered (a box is symmetric under
			-- the 180 degree yaw between the two ends' frames).
			color = PURPLE
			width = math.max(width, partner.Segment.Width)
			frame = (frame - frame.Position)
				+ (frame.Position + partner.WorldCFrame.Position) / 2
			intoSegment = false
		end
		local depth = math.min(width * 0.25, 20)
		children.HoverRect = Roact.createElement("BoxHandleAdornment", {
			Adornee = workspace.Terrain,
			-- The frame's LookVector is the outward direction (-Z), so +Z in
			-- frame space points into the segment: an open end lays the
			-- rectangle over the last stretch of road before the end face,
			-- while a joint straddles it symmetrically.
			CFrame = frame * CFrame.new(0, 0, if intoSegment then depth / 2 else 0),
			Size = Vector3.new(width, HOVER_RECT_THICKNESS, depth),
			Color3 = color,
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
