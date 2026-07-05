--[[
	EndpointPickHandles: Clickable sphere markers on every road segment endpoint.
	Clicking a marker selects that endpoint in the session. Markers are recessed
	slightly into their own segment so the two markers of a closed joint sit
	side by side instead of overlapping.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)
local Math = require(DraggerFramework.Utility.Math)

local RoadMath = require(script.Parent.Parent.RoadMath)

local BLUE = Color3.fromRGB(70, 130, 255)
local RED = Color3.fromRGB(255, 70, 70)
local MARKER_RADIUS = 1.2
local MARKER_INSET = 1.4

local EndpointPickHandles = {}
EndpointPickHandles.__index = EndpointPickHandles

export type Props = {
	GetEndpoints: () -> { RoadMath.Endpoint },
	IsSelected: (endpoint: RoadMath.Endpoint) -> boolean,
	Select: (endpoint: RoadMath.Endpoint) -> (),
}

function EndpointPickHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, EndpointPickHandles)
end

function EndpointPickHandles:update(draggerToolModel, selectionInfo)
	local handles = {}
	for index, endpoint in self._props.GetEndpoints() do
		local frame = endpoint.WorldCFrame
		local scale = self._draggerContext:getHandleScale(frame.Position)
		local position = frame.Position - frame.LookVector * (MARKER_INSET * scale)
		handles[index] = {
			Endpoint = endpoint,
			Position = position,
			Radius = MARKER_RADIUS * scale,
			Color = if endpoint.Id == "Blue" then BLUE else RED,
			Selected = self._props.IsSelected(endpoint),
		}
	end
	self._handles = handles
end

function EndpointPickHandles:shouldBiasTowardsObjects()
	return false
end

function EndpointPickHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestHandleId, closestDistance = nil, math.huge
	for handleId, handle in self._handles do
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit,
			handle.Position, handle.Radius * 1.5)
		if hit and distance and distance < closestDistance then
			closestDistance = distance
			closestHandleId = handleId
		end
	end
	-- Not always on top: markers should not steal clicks from the move and
	-- rotate handles of the selected endpoint.
	return closestHandleId, closestDistance, false
end

function EndpointPickHandles:render(hoveredHandleId)
	local children = {}
	for handleId, handle in self._handles do
		local hovered = handleId == hoveredHandleId
		local radius = handle.Radius
		local transparency = 0.35
		if handle.Selected then
			radius *= 1.35
			transparency = 0
		elseif hovered then
			radius *= 1.2
			transparency = 0
		end
		children["Marker" .. handleId] = Roact.createElement("SphereHandleAdornment", {
			Adornee = workspace.Terrain,
			CFrame = CFrame.new(handle.Position),
			Radius = radius,
			Color3 = handle.Color,
			Transparency = transparency,
			AlwaysOnTop = false,
			ZIndex = 0,
		})
		-- Selected marker gets a highlight halo
		if handle.Selected then
			children["Halo" .. handleId] = Roact.createElement("SphereHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.new(handle.Position),
				Radius = radius * 1.25,
				Color3 = Color3.new(1, 1, 1),
				Transparency = 0.6,
				AlwaysOnTop = false,
				ZIndex = 0,
			})
		end
	end
	return Roact.createElement("Folder", {}, children)
end

function EndpointPickHandles:mouseDown(mouseRay, handleId)
	local handle = self._handles[handleId]
	if handle then
		self._props.Select(handle.Endpoint)
	end
end

function EndpointPickHandles:mouseDrag(mouseRay)
end

function EndpointPickHandles:mouseUp(mouseRay)
end

return EndpointPickHandles
