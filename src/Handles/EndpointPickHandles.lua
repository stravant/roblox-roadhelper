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
local MARKER_RADIUS = 1.2
local MARKER_INSET = 1.4
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

function EndpointPickHandles:_renderMarker(key: string, endpoint: RoadMath.Endpoint, isSelectedMarker: boolean, children)
	local frame = endpoint.WorldCFrame
	local scale = self._draggerContext:getHandleScale(frame.Position)
	local position = frame.Position - frame.LookVector * (MARKER_INSET * scale)
	local radius = MARKER_RADIUS * scale
	local color = if endpoint.Id == "Blue" then BLUE else RED
	if isSelectedMarker then
		radius *= 1.35
	end
	children[key] = Roact.createElement("SphereHandleAdornment", {
		Adornee = workspace.Terrain,
		CFrame = CFrame.new(position),
		Radius = radius,
		Color3 = color,
		Transparency = if isSelectedMarker then 0 else 0.4,
		AlwaysOnTop = false,
		ZIndex = 0,
	})
	if isSelectedMarker then
		children[key .. "Halo"] = Roact.createElement("SphereHandleAdornment", {
			Adornee = workspace.Terrain,
			CFrame = CFrame.new(position),
			Radius = radius * 1.25,
			Color3 = Color3.new(1, 1, 1),
			Transparency = 0.6,
			AlwaysOnTop = false,
			ZIndex = 0,
		})
	end
end

function EndpointPickHandles:render(hoveredHandleId)
	local children = {}
	local selected = self._props.GetSelectedEndpoint()
	if selected then
		self:_renderMarker("Selected", selected, true, children)
	end
	if hoveredHandleId == HOVER_HANDLE_ID and self._hoverEndpoint
		and not isSameEndpoint(self._hoverEndpoint, selected) then
		self:_renderMarker("Hover", self._hoverEndpoint, false, children)
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
