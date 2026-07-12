--[[
	DeleteExitHandles: small red X markers over each open exit of a selected
	4-way intersection. Clicking one removes that exit, turning the crossing
	into a T junction (the session rotates the model and swaps road roles as
	needed so the through road points the appropriate way).
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)
local Math = require(DraggerFramework.Utility.Math)

local RoadMath = require(script.Parent.Parent.RoadMath)

local MARKER_AHEAD = 2.5
local MARKER_LIFT = 0.75
local BAR_LENGTH = 1.9
local BAR_GIRTH = 0.33
local HIT_RADIUS = 1.3

local COLOR = Color3.fromRGB(230, 60, 60)

local DeleteExitHandles = {}
DeleteExitHandles.__index = DeleteExitHandles

export type Props = {
	-- The open exits of the selected 4-way intersection (none otherwise)
	GetDeletableExits: () -> { RoadMath.Endpoint },
	DeleteExit: (exit: RoadMath.Endpoint) -> (),
}

function DeleteExitHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, DeleteExitHandles)
end

function DeleteExitHandles:update(draggerToolModel, selectionInfo)
	local handles = {}
	for _, exit in self._props.GetDeletableExits() do
		local frame = exit.WorldCFrame
		local scale = self._draggerContext:getHandleScale(frame.Position)
		handles[exit.Id] = {
			Exit = exit,
			Position = frame.Position
				+ frame.LookVector * (MARKER_AHEAD * scale)
				+ frame.UpVector * (MARKER_LIFT * scale),
			Frame = frame,
			Scale = scale,
		}
	end
	self._handles = handles
end

function DeleteExitHandles:shouldBiasTowardsObjects()
	return false
end

function DeleteExitHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestId, closestDistance = nil, math.huge
	for handleId, handle in self._handles do
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit,
			handle.Position, HIT_RADIUS * handle.Scale)
		if hit and distance and distance < closestDistance then
			closestDistance = distance
			closestId = handleId
		end
	end
	return closestId, closestDistance, true
end

function DeleteExitHandles:render(hoveredHandleId)
	local children = {}
	for handleId, handle in self._handles do
		local hovered = handleId == hoveredHandleId
		local scale = handle.Scale * (if hovered then 1.2 else 1)
		-- Two crossed bars forming an X, laid flat over the exit
		for i, yaw in { math.rad(45), math.rad(-45) } do
			children[handleId .. i] = Roact.createElement("BoxHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.lookAlong(handle.Position, handle.Frame.LookVector)
					* CFrame.Angles(0, yaw, 0),
				Size = Vector3.new(BAR_GIRTH, BAR_GIRTH, BAR_LENGTH) * scale,
				Color3 = COLOR,
				Transparency = if hovered then 0 else 0.25,
				AlwaysOnTop = false,
				Shading = Enum.AdornShading.XRay,
				ZIndex = 0,
			})
		end
	end
	return Roact.createElement("Folder", {}, children)
end

function DeleteExitHandles:mouseDown(mouseRay, handleId)
	local handle = self._handles[handleId]
	if handle then
		self._props.DeleteExit(handle.Exit)
	end
end

function DeleteExitHandles:mouseDrag(mouseRay)
end

function DeleteExitHandles:mouseUp(mouseRay)
end

return DeleteExitHandles
