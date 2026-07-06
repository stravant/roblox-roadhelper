--!strict
--[[
	createRoadSession: The active RoadHelper tool session.

	Mounts a DraggerFramework DraggerToolComponent with a custom handle list:
	- EndpointPickHandles: on-demand endpoint picking under the cursor
	- EndpointMoveHandles: move the selected endpoint (resizes segments)
	- EndpointRotateHandles: edit the Adjust dir/grade/bank angles
	- AddHandles: append segments off an open endpoint

	The session tracks the selected endpoint as a (model, endpoint id) pair and
	re-derives world frames from live instance state, so external edits and
	undo/redo stay consistent. All edits are wrapped in ChangeHistoryService
	recordings.
]]

local CoreGui = game:GetService("CoreGui")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")

local Packages = script.Parent.Parent.Packages

local DraggerFramework = require(Packages.DraggerFramework)
local DraggerSchemaCore = require(Packages.DraggerSchemaCore)
local Roact = require(Packages.Roact)
local Signal = require(Packages.Signal)

local DraggerContext_PluginImpl = (require :: any)(DraggerFramework.Implementation.DraggerContext_PluginImpl)
local DraggerToolComponent = (require :: any)(DraggerFramework.DraggerTools.DraggerToolComponent)

local RoadMath = require("./RoadMath")
local EndpointPickHandles = require("./Handles/EndpointPickHandles")
local EndpointMoveHandles = require("./Handles/EndpointMoveHandles")
local EndpointRotateHandles = require("./Handles/EndpointRotateHandles")
local AddHandles = require("./Handles/AddHandles")

local REFRESH_INTERVAL = 0.25
local JOINT_SEARCH_RADIUS = 10
local REBIND_SEARCH_RADIUS = 8
local REBIND_TOLERANCE = 2

local ADJUST_AXES: { RoadMath.AdjustAxis } = { "Dir", "Grade", "Bank" }

export type EndpointRef = {
	Model: Model,
	Id: RoadMath.EndpointId,
}

export type SelectionState = {
	Kind: "none",
} | {
	Kind: "open" | "closed",
	SegmentKind: RoadMath.SegmentKind,
	EndpointId: RoadMath.EndpointId,
	OtherSegmentKind: RoadMath.SegmentKind?,
	Dir: number,
	Grade: number,
	Bank: number,
}

local function createFixedSelection(onCleared: () -> ())
	local selectionChangedSignal = Signal.new()
	return {
		Get = function()
			return {}
		end,
		Set = function(newSelection, _hint)
			-- The dragger framework clicking on empty space clears the
			-- selection: treat that as deselecting the endpoint.
			if #newSelection == 0 then
				onCleared()
			end
			task.defer(function()
				selectionChangedSignal:Fire()
			end)
		end,
		SelectionChanged = selectionChangedSignal,
	}
end

local function createRoadSchema(getFocusCFrame: () -> CFrame)
	local schema = table.clone(DraggerSchemaCore)
	schema.getMouseTarget = function()
		-- Clicks which don't hit one of our handles hit nothing
		return nil
	end
	schema.addUndoWaypoint = function()
		-- We manage undo with explicit recordings instead
	end
	schema.SelectionInfo = {
		new = function(context, selection)
			return {
				isEmpty = function(self)
					return false
				end,
				getBoundingBox = function(self)
					return getFocusCFrame(), Vector3.zero, Vector3.zero
				end,
				getAllAttachments = function(self)
					return {}
				end,
				getObjectsToTransform = function(self)
					return {}, {}, {}
				end,
				getBasisObject = function(self)
					return nil
				end,
				getOriginalCFrameMap = function(self)
					return {}
				end,
				getTransformedCopy = function(self, globalTransform)
					return self
				end,
			}
		end,
	} :: any
	return schema
end

-- Attributes describing segment geometry rather than appearance; these are
-- not copied onto newly added segments.
local GEOMETRY_ATTRIBUTES = {
	Flip = true,
	AdjustBlueDir = true,
	AdjustBlueGrade = true,
	AdjustBlueBank = true,
	AdjustRedDir = true,
	AdjustRedGrade = true,
	AdjustRedBank = true,
}

local function createRoadSession(plugin: Plugin)
	local session = {}
	local changeSignal = Signal.new()

	--------------------------------------------------------------------------
	-- State
	--------------------------------------------------------------------------

	local selectedRef: EndpointRef? = nil
	local activeRecording: string? = nil

	-- Last successfully resolved state of the selection, used to re-bind it
	-- when undo/redo destroys and recreates the selected segment's instance.
	local lastKnownPosition: Vector3? = nil
	local lastKnownKind: RoadMath.SegmentKind? = nil

	-- Resolve an endpoint ref against live instance state
	local function resolveEndpoint(ref: EndpointRef?): RoadMath.Endpoint?
		if not ref then
			return nil
		end
		if not ref.Model.Parent then
			return nil
		end
		local info = RoadMath.getSegmentInfo(ref.Model)
		if not info then
			return nil
		end
		return RoadMath.getEndpoint(info, ref.Id)
	end

	-- Find an endpoint of the given end color (and optionally segment kind)
	-- close to a world position. Used to re-bind the selection after undo and
	-- redo destroy and recreate segment instances.
	local function findEndpointNear(position: Vector3, kind: RoadMath.SegmentKind?, id: RoadMath.EndpointId): RoadMath.Endpoint?
		local parts = workspace:GetPartBoundsInRadius(position, REBIND_SEARCH_RADIUS)
		local best: RoadMath.Endpoint? = nil
		local bestDistance = REBIND_TOLERANCE
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] then
				seen[segment.Model] = true
				if kind and segment.Kind ~= kind then
					continue
				end
				local endpoint = RoadMath.getEndpoint(segment, id)
				local distance = (endpoint.WorldCFrame.Position - position).Magnitude
				if distance <= bestDistance then
					bestDistance = distance
					best = endpoint
				end
			end
		end
		return best
	end

	local function tryRebindSelection(): RoadMath.Endpoint?
		local ref = selectedRef
		local position = lastKnownPosition
		if not ref or not position then
			return nil
		end
		return findEndpointNear(position, lastKnownKind, ref.Id)
	end

	local function getSelectedEndpoint(): RoadMath.Endpoint?
		local endpoint = resolveEndpoint(selectedRef)
		if not endpoint and selectedRef then
			-- The selection is sticky: don't clear it just because the
			-- instance can't currently be resolved (mid-undo, or destroyed
			-- and about to be recreated by redo); try to re-bind instead and
			-- otherwise keep waiting.
			endpoint = tryRebindSelection()
			if endpoint then
				selectedRef = { Model = endpoint.Segment.Model, Id = endpoint.Id }
			end
		end
		if endpoint then
			lastKnownPosition = endpoint.WorldCFrame.Position
			lastKnownKind = endpoint.Segment.Kind
		end
		return endpoint
	end

	type SelectionSnapshot = {
		Position: Vector3,
		Kind: RoadMath.SegmentKind,
		Id: RoadMath.EndpointId,
	}?

	local function snapshotSelection(): SelectionSnapshot
		local endpoint = resolveEndpoint(selectedRef)
		if not endpoint then
			return nil
		end
		return {
			Position = endpoint.WorldCFrame.Position,
			Kind = endpoint.Segment.Kind,
			Id = endpoint.Id,
		}
	end

	local function restoreSelection(snapshot: SelectionSnapshot)
		if not snapshot then
			selectedRef = nil
			lastKnownPosition = nil
			lastKnownKind = nil
			return
		end
		lastKnownPosition = snapshot.Position
		lastKnownKind = snapshot.Kind
		local endpoint = findEndpointNear(snapshot.Position, snapshot.Kind, snapshot.Id)
		if endpoint then
			selectedRef = { Model = endpoint.Segment.Model, Id = endpoint.Id }
		else
			-- Leave a stale placeholder ref so the sticky re-bind machinery
			-- keeps looking for an endpoint at this position (e.g. redo may
			-- not have recreated the instance quite yet).
			selectedRef = { Model = Instance.new("Model"), Id = snapshot.Id }
		end
	end

	-- Selection history synchronized with the undo stack: operations which
	-- change the selection (the adds) record what was selected before and
	-- after, keyed by their undo waypoint name, so undoing an add brings the
	-- previous selection back and redoing reselects the added segment's end.
	type SelectionHistoryEntry = {
		Name: string,
		Before: SelectionSnapshot,
		After: SelectionSnapshot,
	}
	local undoSelectionStack: { SelectionHistoryEntry } = {}
	local redoSelectionStack: { SelectionHistoryEntry } = {}

	local function pushSelectionHistory(name: string, before: SelectionSnapshot, after: SelectionSnapshot)
		table.insert(undoSelectionStack, { Name = name, Before = before, After = after })
		table.clear(redoSelectionStack)
	end

	-- Find the mated partner of the selected endpoint with an on-demand
	-- spatial query around the endpoint, so we never have to eagerly inspect
	-- the whole place.
	local function getPartnerEndpoint(): RoadMath.Endpoint?
		local selected = getSelectedEndpoint()
		if not selected then
			return nil
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { selected.Segment.Model }
		local parts = workspace:GetPartBoundsInRadius(
			selected.WorldCFrame.Position, JOINT_SEARCH_RADIUS, params)
		local candidates: { RoadMath.SegmentInfo } = {}
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] then
				seen[segment.Model] = true
				table.insert(candidates, segment)
			end
		end
		return RoadMath.findJoint(selected, candidates)
	end

	--------------------------------------------------------------------------
	-- Dragger context and schema
	--------------------------------------------------------------------------

	local function clearSelection()
		if not selectedRef then
			return
		end
		selectedRef = nil
		lastKnownPosition = nil
		lastKnownKind = nil
		changeSignal:Fire()
	end

	local fixedSelection = createFixedSelection(clearSelection)

	local draggerContext = DraggerContext_PluginImpl.new(
		plugin,
		game,
		settings(),
		fixedSelection
	)

	local schema = createRoadSchema(function()
		local endpoint = getSelectedEndpoint()
		return if endpoint then endpoint.WorldCFrame else CFrame.identity
	end)

	-- Whether a handle drag gesture (move/rotate/add) is in progress
	local gestureActive = false

	-- Nudge the dragger framework to re-read state. NEVER do this during an
	-- active gesture: the framework responds to selection changes by
	-- cancelling and re-initializing the current handle drag (re-invoking
	-- mouseDown!), which restarts the gesture and can recurse infinitely when
	-- fired from inside a handle callback. Deferred + coalesced for safety
	-- against any other synchronous re-entrance.
	local updateQueued = false
	local function updateDragger()
		if gestureActive or updateQueued then
			return
		end
		updateQueued = true
		task.defer(function()
			updateQueued = false
			if not gestureActive then
				fixedSelection.SelectionChanged:Fire()
			end
		end)
	end

	--------------------------------------------------------------------------
	-- Undo recordings
	--------------------------------------------------------------------------

	local activeRecordingName: string? = nil
	local function beginRecording(name: string)
		if activeRecording then
			return
		end
		activeRecordingName = "RoadHelper " .. name
		local recording = ChangeHistoryService:TryBeginRecording("RoadHelper " .. name)
		if not recording then
			-- Without a recording every individual property change gets auto
			-- committed as its own undo waypoint, fragmenting undo. This
			-- happens when some other plugin (or a previous error) left a
			-- recording dangling; nothing we can do but flag it clearly.
			warn("RoadHelper: Couldn't begin an undo recording (another recording is in progress). " ..
				"Undo will be fragmented for this gesture. If this persists, restarting Studio clears stuck recordings.")
		end
		activeRecording = recording :: any
	end

	local function finishRecording()
		if activeRecording then
			ChangeHistoryService:FinishRecording(activeRecording, Enum.FinishRecordingOperation.Commit)
			activeRecording = nil
		end
	end

	--------------------------------------------------------------------------
	-- Edit operations
	--------------------------------------------------------------------------

	local function applySolution(model: Model, solution: RoadMath.MoveSolution)
		local wasFlipped = model:GetAttribute("Flip") == true
		if solution.SwapEnds then
			-- The segment was rotated 180 degrees and its ends traded roles:
			-- move the adjust values to follow their geographic ends.
			local swapped = RoadMath.swappedAdjustValues(function(name: string)
				local value = model:GetAttribute(name)
				return if typeof(value) == "number" then value else 0
			end)
			for name, value in swapped do
				model:SetAttribute(name, value)
			end
		end
		if wasFlipped ~= solution.Flip then
			-- Flipping changes the world meaning of some adjust attributes
			-- (curve grades scale with the climb sign; straight dirs mirror
			-- with the path): negate those so each face's actual world
			-- geometry is preserved through the flip.
			local info = RoadMath.getSegmentInfo(model)
			if info then
				local names = if info.Kind == "Curve"
					then { "AdjustBlueGrade", "AdjustRedGrade" }
					else { "AdjustBlueDir", "AdjustRedDir" }
				for _, name in names do
					local value = model:GetAttribute(name)
					if typeof(value) == "number" and value ~= 0 then
						model:SetAttribute(name, -value)
					end
				end
			end
		end
		(model :: any).Size = solution.Size
		model:SetAttribute("Flip", solution.Flip)
		model:PivotTo(solution.Pivot)
	end

	-- Apply a move solution and keep endpoint references coherent: a SwapEnds
	-- solution re-colors the segment's ends, so any refs we hold pointing at
	-- them (the drag target itself and possibly the selection) must flip too.
	local function applySolutionToRef(ref: EndpointRef, solution: RoadMath.MoveSolution)
		applySolution(ref.Model, solution)
		if solution.SwapEnds then
			local newId: RoadMath.EndpointId = if ref.Id == "Blue" then "Red" else "Blue"
			local selected = selectedRef
			if selected and selected ~= ref and selected.Model == ref.Model and selected.Id == ref.Id then
				selected.Id = newId
			end
			ref.Id = newId
			changeSignal:Fire()
		end
	end

	-- Move targets are captured at drag start: the selected end plus the mated
	-- partner end if the endpoint is closed.
	local moveTargets: { EndpointRef } = {}

	local function startMove()
		moveTargets = {}
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		table.insert(moveTargets, { Model = selected.Segment.Model, Id = selected.Id })
		local partner = getPartnerEndpoint()
		if partner then
			table.insert(moveTargets, { Model = partner.Segment.Model, Id = partner.Id })
		end
		gestureActive = true
		beginRecording("Move Endpoint")
	end

	local function applyMove(newWorldPosition: Vector3)
		for _, target in moveTargets do
			local info = RoadMath.getSegmentInfo(target.Model)
			if info then
				local ok, err = pcall(function()
					applySolutionToRef(target, RoadMath.solveMove(info, target.Id, newWorldPosition))
				end)
				if not ok then
					warn("RoadHelper: Endpoint move failed: " .. tostring(err))
				end
			end
		end
		changeSignal:Fire()
	end

	local function endMove()
		moveTargets = {}
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- Rotation: capture the attached ends and their starting attribute values,
	-- then apply cumulative deltas with per-end sign mapping.
	type RotateTarget = {
		Ref: EndpointRef,
		Signs: { [RoadMath.AdjustAxis]: number },
		StartValues: { [RoadMath.AdjustAxis]: number },
	}
	local rotateTargets: { RotateTarget } = {}

	local function captureRotateTarget(selected: RoadMath.Endpoint, endpoint: RoadMath.Endpoint): RotateTarget
		local signs = {}
		local startValues = {}
		for _, axis in ADJUST_AXES do
			signs[axis] = RoadMath.adjustDeltaSign(selected, endpoint, axis)
			startValues[axis] = RoadMath.getAdjustValue(endpoint, axis)
		end
		return {
			Ref = { Model = endpoint.Segment.Model, Id = endpoint.Id },
			Signs = signs,
			StartValues = startValues,
		}
	end

	local function startRotate()
		rotateTargets = {}
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		table.insert(rotateTargets, captureRotateTarget(selected, selected))
		local partner = getPartnerEndpoint()
		if partner then
			table.insert(rotateTargets, captureRotateTarget(selected, partner))
		end
		gestureActive = true
		beginRecording("Rotate Endpoint")
	end

	local function applyRotate(axis: RoadMath.AdjustAxis, deltaDegrees: number)
		for _, target in rotateTargets do
			local name = RoadMath.adjustAttributeName(target.Ref.Id, axis)
			local newValue = target.StartValues[axis] + target.Signs[axis] * deltaDegrees
			-- Keep the stored angles tidy
			newValue = math.round(newValue * 1000) / 1000
			local ok, err = pcall(function()
				target.Ref.Model:SetAttribute(name, newValue)
			end)
			if not ok then
				warn("RoadHelper: Angle change failed: " .. tostring(err))
			end
		end
		changeSignal:Fire()
	end

	local function endRotate()
		rotateTargets = {}
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Adding segments
	--------------------------------------------------------------------------

	-- Scan for a template on demand: this only happens on add clicks, never
	-- per-frame, so a full workspace scan is acceptable.
	local function findTemplate(kind: RoadMath.SegmentKind, near: Vector3?): RoadMath.SegmentInfo?
		local best: RoadMath.SegmentInfo? = nil
		local bestDistance = math.huge
		for _, segment in RoadMath.findSegments(workspace) do
			if segment.Kind == kind then
				local distance = if near then (segment.Pivot.Position - near).Magnitude else 0
				if distance < bestDistance then
					bestDistance = distance
					best = segment
				end
			end
		end
		return best
	end

	-- Create a new segment joined to `openEnd`, cloned from a template of the
	-- right kind with appearance attributes copied from the segment being
	-- extended. Returns the new model and its far (still open) endpoint id.
	local function createJoinedSegment(openEnd: RoadMath.Endpoint, turn: RoadMath.TurnDirection): (Model?, RoadMath.EndpointId?)
		local sourceModel = openEnd.Segment.Model
		local width = openEnd.Segment.Width
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, turn, width)

		local template = if openEnd.Segment.Kind == kind
			then openEnd.Segment
			else findTemplate(kind, openEnd.WorldCFrame.Position)
		if not template then
			warn(`RoadHelper: No {kind} road segment found in the place to use as a template.`)
			return nil, nil
		end

		local newModel = template.Model:Clone()
		-- Drop the stale generated geometry; it regenerates for the new size
		local generated = newModel:FindFirstChild("Generated")
		if generated then
			generated:Destroy()
		end

		-- Appearance follows the segment being extended
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		newModel:SetAttribute("Flip", false)
		for _, axis in ADJUST_AXES do
			newModel:SetAttribute(RoadMath.adjustAttributeName("Blue", axis), 0)
			newModel:SetAttribute(RoadMath.adjustAttributeName("Red", axis), 0)
		end
		-- The joining end must mate with the open end's grade/bank
		local matching = RoadMath.matchingAdjust(openEnd, joinId)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Grade"), matching.Grade)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Bank"), matching.Bank);

		(newModel :: any).Size = size
		newModel:PivotTo(pivot)
		newModel.Parent = sourceModel.Parent

		local farId: RoadMath.EndpointId = if joinId == "Blue" then "Red" else "Blue"
		return newModel, farId
	end

	-- Add-drag state (from AddHandles)
	local addDragRef: EndpointRef? = nil
	local addBeforeSelection: SelectionSnapshot = nil

	local function startAdd(turn: RoadMath.TurnDirection): number?
		local selected = getSelectedEndpoint()
		if not selected then
			return nil
		end
		gestureActive = true
		addBeforeSelection = snapshotSelection()
		beginRecording("Add Segment")
		local newModel, farId = createJoinedSegment(selected, turn)
		if not newModel or not farId then
			finishRecording()
			gestureActive = false
			return nil
		end
		addDragRef = { Model = newModel, Id = farId }
		selectedRef = addDragRef
		changeSignal:Fire()
		local farEndpoint = resolveEndpoint(addDragRef)
		return if farEndpoint then farEndpoint.WorldCFrame.Position.Y else 0
	end

	local function applyAddDrag(worldPosition: Vector3)
		local ref = addDragRef
		if not ref then
			return
		end
		local info = RoadMath.getSegmentInfo(ref.Model)
		if info then
			local ok, err = pcall(function()
				applySolutionToRef(ref, RoadMath.solveMove(info, ref.Id, worldPosition))
			end)
			if not ok then
				warn("RoadHelper: Segment placement failed: " .. tostring(err))
			end
		end
		changeSignal:Fire()
	end

	local function endAdd()
		addDragRef = nil
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, addBeforeSelection, snapshotSelection())
		end
		addBeforeSelection = nil
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- Add a free-standing segment in front of the camera (UI buttons)
	local function addInFrontOfCamera(kind: RoadMath.SegmentKind)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local template = findTemplate(kind, camera.CFrame.Position)
		if not template then
			warn(`RoadHelper: No {kind} road segment found in the place to use as a template.`)
			return
		end
		local width = template.Width

		-- Aim at what the camera is looking at, or a point ahead of the camera
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = {}
		local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 500, raycastParams)
		local target = if result
			then result.Position
			else camera.CFrame.Position + camera.CFrame.LookVector * 200

		local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
		local yaw = math.atan2(look.X, look.Z)
		local rotation = CFrame.Angles(0, yaw, 0)

		local size = if kind == "Straight"
			then Vector3.new(width, 0, math.max(2 * width, RoadMath.MIN_LENGTH))
			else Vector3.new(2 * width, 0, 2 * width)

		local beforeSelection = snapshotSelection()
		beginRecording("Add Segment")
		local newModel = template.Model:Clone()
		local generated = newModel:FindFirstChild("Generated")
		if generated then
			generated:Destroy()
		end
		newModel:SetAttribute("Flip", false)
		for _, axis in ADJUST_AXES do
			newModel:SetAttribute(RoadMath.adjustAttributeName("Blue", axis), 0)
			newModel:SetAttribute(RoadMath.adjustAttributeName("Red", axis), 0)
		end

		-- Place the blue end nearest the camera, road extending away
		local blueLocal = RoadMath.localEndpointFrame(kind, size, width, false, "Blue");
		(newModel :: any).Size = size
		newModel:PivotTo(rotation + (target - rotation:VectorToWorldSpace(blueLocal.Position)))
		newModel.Parent = template.Model.Parent

		selectedRef = { Model = newModel, Id = "Red" }
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Handles
	--------------------------------------------------------------------------

	local handlesList = {
		EndpointMoveHandles.new(draggerContext, {
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				return if endpoint then endpoint.WorldCFrame else nil
			end,
			GetDragExclusions = function(): { Instance }
				local exclusions: { Instance } = {}
				local selected = getSelectedEndpoint()
				if selected then
					table.insert(exclusions, selected.Segment.Model)
					local partner = getPartnerEndpoint()
					if partner then
						table.insert(exclusions, partner.Segment.Model)
					end
				end
				return exclusions
			end,
			StartMove = startMove,
			ApplyMove = applyMove,
			EndMove = endMove,
		}),
		EndpointRotateHandles.new(draggerContext, {
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				return if endpoint then endpoint.WorldCFrame else nil
			end,
			StartRotate = startRotate,
			ApplyRotate = applyRotate,
			EndRotate = endRotate,
		}),
		AddHandles.new(draggerContext, {
			GetOpenEndpoint = function()
				local endpoint = getSelectedEndpoint()
				if not endpoint then
					return nil
				end
				if getPartnerEndpoint() then
					return nil -- Closed endpoints can't be extended
				end
				return endpoint
			end,
			StartAdd = startAdd,
			ApplyAddDrag = applyAddDrag,
			EndAdd = endAdd,
		}),
		EndpointPickHandles.new(draggerContext, {
			GetSelectedEndpoint = getSelectedEndpoint,
			Select = function(endpoint: RoadMath.Endpoint)
				-- Must be a no-op when re-selecting the same endpoint: the
				-- framework responds to our selection-changed nudge by
				-- re-initializing the click (calling mouseDown -> Select
				-- again), so notifying unconditionally would loop forever.
				local ref = selectedRef
				if ref and ref.Model == endpoint.Segment.Model and ref.Id == endpoint.Id then
					return
				end
				selectedRef = { Model = endpoint.Segment.Model, Id = endpoint.Id }
				updateDragger()
				changeSignal:Fire()
			end,
			Deselect = function()
				-- Idempotent for the same reason Select must be: the
				-- framework re-initializes the click on selection changes.
				if not selectedRef then
					return
				end
				clearSelection()
				updateDragger()
			end,
		}),
	}

	local rootElement = Roact.createElement(DraggerToolComponent, {
		Mouse = plugin:GetMouse(),
		DraggerContext = draggerContext,
		DraggerSchema = schema,
		DraggerSettings = {
			AllowDragSelect = false,
			AnalyticsName = "RoadHelper",
			HandlesList = handlesList,
		},
	})
	local draggerHandle = Roact.mount(rootElement)

	--------------------------------------------------------------------------
	-- Refresh loop
	--------------------------------------------------------------------------

	-- Nudge the dragger periodically so the selected endpoint's handles track
	-- external edits (manual property changes etc.); this reads only the
	-- selected segment's live state, no scanning involved.
	local refreshAccumulator = 0
	local heartbeatCn = RunService.Heartbeat:Connect(function(dt: number)
		refreshAccumulator += dt
		if refreshAccumulator < REFRESH_INTERVAL then
			return
		end
		refreshAccumulator = 0
		updateDragger()
	end)

	-- HACK: Studio selects the instances affected by an undo/redo, which
	-- during a road session means a pile of (regenerated) road parts gets
	-- highlighted. Clear any road-related Studio selection shortly after; a
	-- selection of non-road instances is left alone.
	local sessionAlive = true
	local function clearStudioSelectionAfterHistory()
		local function clearIfRoadRelated()
			if not sessionAlive then
				return
			end
			for _, instance in Selection:Get() do
				if RoadMath.segmentFromDescendant(instance) then
					Selection:Set({})
					return
				end
			end
		end
		-- Once right after the history operation settles, and once the next
		-- frame in case Studio applies its selection late.
		task.defer(clearIfRoadRelated)
		task.delay(0, clearIfRoadRelated)
	end

	local undoCn = ChangeHistoryService.OnUndo:Connect(function(waypointName: string)
		clearStudioSelectionAfterHistory()
		local top = undoSelectionStack[#undoSelectionStack]
		if top and top.Name == waypointName then
			table.remove(undoSelectionStack)
			table.insert(redoSelectionStack, top)
			restoreSelection(top.Before)
		end
		updateDragger()
		changeSignal:Fire()
	end)
	local redoCn = ChangeHistoryService.OnRedo:Connect(function(waypointName: string)
		clearStudioSelectionAfterHistory()
		local top = redoSelectionStack[#redoSelectionStack]
		if top and top.Name == waypointName then
			table.remove(redoSelectionStack)
			table.insert(undoSelectionStack, top)
			restoreSelection(top.After)
		end
		updateDragger()
		changeSignal:Fire()
	end)

	--------------------------------------------------------------------------
	-- Public API
	--------------------------------------------------------------------------

	session.ChangeSignal = changeSignal

	function session.GetSelectionState(): SelectionState
		local selected = getSelectedEndpoint()
		if not selected then
			return { Kind = "none" :: "none" }
		end
		local partner = getPartnerEndpoint()
		return {
			Kind = if partner then "closed" else "open",
			SegmentKind = selected.Segment.Kind,
			EndpointId = selected.Id,
			OtherSegmentKind = if partner then partner.Segment.Kind else nil,
			Dir = RoadMath.getAdjustValue(selected, "Dir"),
			Grade = RoadMath.getAdjustValue(selected, "Grade"),
			Bank = RoadMath.getAdjustValue(selected, "Bank"),
		} :: any
	end

	-- Set an absolute Adjust value on the selected end (from the UI), applying
	-- the equivalent delta to the mated partner end to keep the joint sealed.
	function session.SetAdjustValue(axis: RoadMath.AdjustAxis, value: number)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		local delta = value - RoadMath.getAdjustValue(selected, axis)
		beginRecording("Set Angle")
		local function applyTo(endpoint: RoadMath.Endpoint)
			local sign = RoadMath.adjustDeltaSign(selected, endpoint, axis)
			local name = RoadMath.adjustAttributeName(endpoint.Id, axis)
			endpoint.Segment.Model:SetAttribute(name, RoadMath.getAdjustValue(endpoint, axis) + sign * delta)
		end
		applyTo(selected)
		local partner = getPartnerEndpoint()
		if partner then
			applyTo(partner)
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	session.AddInFrontOfCamera = addInFrontOfCamera

	function session.Destroy()
		sessionAlive = false
		heartbeatCn:Disconnect()
		undoCn:Disconnect()
		redoCn:Disconnect()
		finishRecording()
		Roact.unmount(draggerHandle)
	end

	return session
end

export type RoadSession = typeof(createRoadSession(...))

return createRoadSession
