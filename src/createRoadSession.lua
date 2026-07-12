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
local DeleteExitHandles = require("./Handles/DeleteExitHandles")
local PartialRotateHandleView = require("./Dragger/PartialRotateHandleView")
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
	Blend: boolean,
	TextureLaneMarkings: boolean,
	MaxAngle: number,
	LaneCount: number,
	LaneWidth: number,
	SidewalkWidth: number,
	IntersectionAngle: number,
	-- Nominal corner curve radius of an intersection (half the bounding box
	-- size in excess of the roads' widths; exact at 90 degrees)
	CornerRadius: number,
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

local GENERATOR_MODULE_NAMES: { [RoadMath.SegmentKind]: string } = {
	Straight = "StraightRoadGenerator",
	Curve = "CurveRoadGenerator",
	Intersection = "RoadIntersectionGenerator",
}

-- Build a brand new segment from the generator templates packaged inside the
-- plugin, so RoadHelper works even in a place with no road segments yet.
local Templates = script.Parent.Templates
local function createFallbackSegmentModel(kind: RoadMath.SegmentKind): Model?
	local ok, model = pcall(function()
		return Instance.new("ProceduralModel" :: any) :: any
	end)
	if not ok or not model then
		warn("RoadHelper: This Studio version doesn't support creating ProceduralModels.")
		return nil
	end
	model.Name = if kind == "Straight"
		then "StraightRoad"
		elseif kind == "Curve" then "CurveRoad"
		else "RoadIntersection"
	local generator = Templates:FindFirstChild(GENERATOR_MODULE_NAMES[kind])
	if generator then
		local generatorCopy = generator:Clone()
		generatorCopy.Parent = model
		-- The engine binds the model to its generator through this property;
		-- it does not discover the module by name.
		model.Generator = generatorCopy
	end
	return model :: Model
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
	-- Intersection lane layout (translated onto LaneCount/LaneWidth when
	-- extending an intersection end, not copied directly)
	LaneCountX = true,
	LaneCountZ = true,
	LaneWidthX = true,
	LaneWidthZ = true,
	IntersectionAngle = true,
	ThroughRoad = true,
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
				if not table.find(RoadMath.endpointIds(segment), id) then
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

	-- Find the mated partner of an endpoint with an on-demand spatial query
	-- around it, so we never have to eagerly inspect the whole place.
	local function partnerOfEndpoint(endpoint: RoadMath.Endpoint): RoadMath.Endpoint?
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { endpoint.Segment.Model }
		local parts = workspace:GetPartBoundsInRadius(
			endpoint.WorldCFrame.Position, JOINT_SEARCH_RADIUS, params)
		local candidates: { RoadMath.SegmentInfo } = {}
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] then
				seen[segment.Model] = true
				table.insert(candidates, segment)
			end
		end
		return RoadMath.findJoint(endpoint, candidates)
	end

	local function getPartnerEndpoint(): RoadMath.Endpoint?
		local selected = getSelectedEndpoint()
		return if selected then partnerOfEndpoint(selected) else nil
	end

	-- Endpoint snapping: while free-dragging an endpoint or drag-placing a new
	-- segment, pull the requested position onto a nearby open end of another
	-- segment so that ends mate exactly.
	local SNAP_DISTANCE = 12

	local function isEndpointOpen(endpoint: RoadMath.Endpoint, excludeSet: { [Model]: boolean }): boolean
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local exclusions: { Instance } = { endpoint.Segment.Model }
		for model in excludeSet do
			table.insert(exclusions, model)
		end
		params.FilterDescendantsInstances = exclusions
		local parts = workspace:GetPartBoundsInRadius(
			endpoint.WorldCFrame.Position, JOINT_SEARCH_RADIUS, params)
		local candidates: { RoadMath.SegmentInfo } = {}
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] and not excludeSet[segment.Model] then
				seen[segment.Model] = true
				table.insert(candidates, segment)
			end
		end
		return RoadMath.findJoint(endpoint, candidates) == nil
	end

	local function snapToOpenEndpoint(
		position: Vector3,
		movingModels: { Model },
		excludeEndpoint: EndpointRef?
	): (Vector3, RoadMath.Endpoint?)
		local excludeSet: { [Model]: boolean } = {}
		local exclusions: { Instance } = {}
		for _, model in movingModels do
			excludeSet[model] = true
			table.insert(exclusions, model)
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclusions
		-- Any segment whose end is within snap range has parts near the end,
		-- so a slightly padded part query is enough to find all candidates
		local parts = workspace:GetPartBoundsInRadius(position, SNAP_DISTANCE + 4, params)
		local best: RoadMath.Endpoint? = nil
		local bestDistance = SNAP_DISTANCE
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if not segment or seen[segment.Model] or excludeSet[segment.Model] then
				continue
			end
			seen[segment.Model] = true
			for _, id in RoadMath.endpointIds(segment) do
				if excludeEndpoint and excludeEndpoint.Model == segment.Model and excludeEndpoint.Id == id then
					continue
				end
				local endpoint = RoadMath.getEndpoint(segment, id)
				local distance = (endpoint.WorldCFrame.Position - position).Magnitude
				if distance <= bestDistance and isEndpointOpen(endpoint, excludeSet) then
					bestDistance = distance
					best = endpoint
				end
			end
		end
		if best then
			return best.WorldCFrame.Position, best
		end
		return position, nil
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

	local function setAdjustAttribute(model: Model, id: RoadMath.EndpointId, axis: RoadMath.AdjustAxis, value: number)
		local name = RoadMath.adjustAttributeName(id, axis)
		local current = model:GetAttribute(name)
		if current ~= value and not (current == nil and value == 0) then
			model:SetAttribute(name, value)
		end
	end

	local function captureAdjust(ref: EndpointRef): { [RoadMath.AdjustAxis]: number }
		local values = {}
		for _, axis in ADJUST_AXES do
			local value = ref.Model:GetAttribute(RoadMath.adjustAttributeName(ref.Id, axis))
			values[axis] = if typeof(value) == "number" then value else 0
		end
		return values
	end

	local function restoreAdjust(ref: EndpointRef, saved: { [RoadMath.AdjustAxis]: number })
		for axis, value in saved do
			setAdjustAttribute(ref.Model, ref.Id, axis :: RoadMath.AdjustAxis, value)
		end
	end

	-- When a dragged road end snaps onto another open end, rotate the road's
	-- end face to mate flush: its Dir adjust takes up the yaw between its
	-- nominal frame and the mate's actual face (however the two bounding
	-- boxes are aligned), and its grade/bank match the mate's (zero for the
	-- flat intersections).
	local function alignEndFaceToMate(ref: EndpointRef, mate: RoadMath.Endpoint)
		local info = RoadMath.getSegmentInfo(ref.Model)
		if not info or info.Kind == "Intersection" then
			return
		end
		local endpoint = RoadMath.getEndpoint(info, ref.Id)
		local up = endpoint.WorldCFrame.UpVector
		local nominal = endpoint.WorldCFrame.LookVector
		local desired = -RoadMath.actualOutwardDirection(mate)
		local n = nominal - up * nominal:Dot(up)
		local d = desired - up * desired:Dot(up)
		if n.Magnitude < 1e-4 or d.Magnitude < 1e-4 then
			return
		end
		n, d = n.Unit, d.Unit
		local angle = math.deg(math.atan2(n:Cross(d):Dot(up), n:Dot(d)))
		angle = math.round(angle * 100) / 100
		setAdjustAttribute(ref.Model, ref.Id, "Dir", angle / RoadMath.flipFactor(info, "Dir"))
		if mate.Segment.Kind == "Intersection" then
			setAdjustAttribute(ref.Model, ref.Id, "Grade", 0)
			setAdjustAttribute(ref.Model, ref.Id, "Bank", 0)
		else
			local matching = RoadMath.matchingAdjust(mate, ref.Id)
			setAdjustAttribute(ref.Model, ref.Id, "Grade", matching.Grade / RoadMath.flipFactor(info, "Grade"))
			setAdjustAttribute(ref.Model, ref.Id, "Bank", matching.Bank)
		end
	end

	-- A road end joined to one of an intersection's exits, and which exit
	type IntersectionConnection = {
		Ref: EndpointRef,
		EndId: RoadMath.EndpointId,
	}

	-- Re-seat each connected road end onto its (possibly moved) exit
	local function reseatConnectedEnds(model: Model, connected: { IntersectionConnection })
		local info = RoadMath.getSegmentInfo(model)
		if not info then
			return
		end
		for _, conn in connected do
			local exit = RoadMath.getEndpoint(info, conn.EndId)
			local roadInfo = RoadMath.getSegmentInfo(conn.Ref.Model)
			if roadInfo then
				local ok, err = pcall(function()
					applySolutionToRef(conn.Ref, RoadMath.solveMove(roadInfo, conn.Ref.Id, exit.WorldCFrame.Position))
				end)
				if not ok then
					warn("RoadHelper: Connected road follow failed: " .. tostring(err))
				end
				alignEndFaceToMate(conn.Ref, exit)
			end
		end
	end

	-- All road ends joined to an intersection's exits
	local function collectIntersectionConnections(segment: RoadMath.SegmentInfo): { IntersectionConnection }
		local connected: { IntersectionConnection } = {}
		for _, endpoint in RoadMath.allEndpoints(segment) do
			local partner = partnerOfEndpoint(endpoint)
			if partner and partner.Segment.Kind ~= "Intersection" then
				table.insert(connected, {
					Ref = { Model = partner.Segment.Model, Id = partner.Id },
					EndId = endpoint.Id,
				})
			end
		end
		return connected
	end

	-- Move targets are captured at drag start: the selected end plus the mated
	-- partner end if the endpoint is closed. A road end mated to an
	-- intersection instead carries the whole intersection along, and the
	-- intersection's other connected roads follow its exits.
	local moveTargets: { EndpointRef } = {}
	local moveOriginalAdjust: { [RoadMath.AdjustAxis]: number }? = nil
	local moveIntersection: {
		Model: Model,
		StartPivot: CFrame,
		ExitStart: Vector3,
		Connected: { IntersectionConnection },
	}? = nil

	local function startMove()
		moveTargets = {}
		moveOriginalAdjust = nil
		moveIntersection = nil
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		table.insert(moveTargets, { Model = selected.Segment.Model, Id = selected.Id })
		if selected.Segment.Kind ~= "Intersection" then
			moveOriginalAdjust = captureAdjust(moveTargets[1])
		end
		local partner = getPartnerEndpoint()
		if partner and partner.Segment.Kind == "Intersection" then
			-- Only carry the intersection along when the road end actually
			-- mates the exit flush (matching angle, no grade/bank). A
			-- mismatched end instead moves freely, so it can be free-dragged
			-- back onto the exit to re-snap without dragging the
			-- intersection around.
			local facing = RoadMath.actualOutwardDirection(selected):Dot(partner.WorldCFrame.LookVector)
			local flush = facing < -0.9994
				and math.abs(RoadMath.getAdjustValue(selected, "Grade")) < 0.25
				and math.abs(RoadMath.getAdjustValue(selected, "Bank")) < 0.25
			if flush then
				-- The intersection translates along with the dragged end, and
				-- its other connected roads' ends follow its exits
				local connected: { IntersectionConnection } = {}
				for _, endpoint in RoadMath.allEndpoints(partner.Segment) do
					if endpoint.Id ~= partner.Id then
						local mate = partnerOfEndpoint(endpoint)
						if mate
							and mate.Segment.Kind ~= "Intersection"
							and mate.Segment.Model ~= selected.Segment.Model
						then
							table.insert(connected, {
								Ref = { Model = mate.Segment.Model, Id = mate.Id },
								EndId = endpoint.Id,
							})
						end
					end
				end
				moveIntersection = {
					Model = partner.Segment.Model,
					StartPivot = partner.Segment.Model:GetPivot(),
					ExitStart = partner.WorldCFrame.Position,
					Connected = connected,
				}
			end
		elseif partner then
			table.insert(moveTargets, { Model = partner.Segment.Model, Id = partner.Id })
		end
		gestureActive = true
		beginRecording("Move Endpoint")
	end

	local function applyMove(newWorldPosition: Vector3, snapToEnds: boolean?)
		local snapMate: RoadMath.Endpoint? = nil
		-- With an attached intersection the dragged end stays mated to it, so
		-- snapping onto other open ends doesn't apply
		if snapToEnds and not moveIntersection then
			local movingModels = {}
			for _, target in moveTargets do
				table.insert(movingModels, target.Model)
			end
			newWorldPosition, snapMate = snapToOpenEndpoint(newWorldPosition, movingModels, nil)
		end
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
		local ix = moveIntersection
		if ix then
			ix.Model:PivotTo(ix.StartPivot + (newWorldPosition - ix.ExitStart))
			reseatConnectedEnds(ix.Model, ix.Connected)
		end
		local dragged = moveTargets[1]
		if dragged and moveOriginalAdjust and not moveIntersection then
			if snapMate then
				alignEndFaceToMate(dragged, snapMate)
			else
				restoreAdjust(dragged, moveOriginalAdjust)
			end
		end
		changeSignal:Fire()
	end

	local function endMove()
		moveTargets = {}
		moveOriginalAdjust = nil
		moveIntersection = nil
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
		-- Intersections have no adjust angles to keep in sync
		if partner and partner.Segment.Kind ~= "Intersection" then
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
		local width = RoadMath.endpointWidth(openEnd)
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, turn, width)

		local template = if openEnd.Segment.Kind == kind
			then openEnd.Segment
			else findTemplate(kind, openEnd.WorldCFrame.Position)

		local newModel: Model?
		if template then
			newModel = template.Model:Clone()
			-- Keep the cloned geometry rather than clearing it: the engine
			-- only regenerates on change events, so a clone whose parameters
			-- all end up identical to the template's would otherwise stay
			-- empty. When anything does change, regeneration replaces the
			-- folder contents anyway.
		else
			-- No segment of this kind anywhere: build one from the packaged
			-- generator templates
			newModel = createFallbackSegmentModel(kind)
		end
		if not newModel then
			warn(`RoadHelper: No {kind} road segment available to use as a template.`)
			return nil, nil
		end

		-- Appearance follows the segment being extended
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		if openEnd.Segment.Kind == "Intersection" then
			-- Translate the extended end's lane layout onto the road's
			-- lane attributes
			local axis = if openEnd.Id == "XPlus" or openEnd.Id == "XMinus" then "X" else "Z"
			newModel:SetAttribute("LaneCount", sourceModel:GetAttribute("LaneCount" .. axis) or 2)
			newModel:SetAttribute("LaneWidth", sourceModel:GetAttribute("LaneWidth" .. axis) or 24)
		end
		newModel:SetAttribute("Flip", false)
		for _, axis in ADJUST_AXES do
			newModel:SetAttribute(RoadMath.adjustAttributeName("Blue", axis), 0)
			newModel:SetAttribute(RoadMath.adjustAttributeName("Red", axis), 0)
		end
		-- The joining end must mate with the open end's dir/grade/bank
		local farId: RoadMath.EndpointId = if joinId == "Blue" then "Red" else "Blue"
		local matching = RoadMath.matchingAdjust(openEnd, joinId)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Dir"), matching.Dir)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Grade"), matching.Grade)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Bank"), matching.Bank)
		if kind == "Straight" then
			-- A straight added off an angled end continues at that angle: the
			-- far end carries the same yaw (same attribute = same effective
			-- world yaw on an unflipped straight), so the road doesn't bend
			-- back to the nominal axis and further adds keep the angle going.
			newModel:SetAttribute(RoadMath.adjustAttributeName(farId, "Dir"), matching.Dir)
		end

		(newModel :: any).Size = size
		newModel:PivotTo(pivot)
		newModel.Parent = sourceModel.Parent

		-- A plain click on the straight handle should jut straight out of the
		-- open end's ACTUAL face even when it is angled: both end Dirs already
		-- match the face's yaw, so aiming the far endpoint along the actual
		-- direction degenerates the path to a dead-straight diagonal within
		-- the box-aligned bounds. (A drag re-solves the far end anyway.)
		if kind == "Straight" and math.abs(matching.Dir) > 0.01 then
			local info = RoadMath.getSegmentInfo(newModel)
			if info then
				local target = openEnd.WorldCFrame.Position
					+ RoadMath.actualOutwardDirection(openEnd) * size.Z
				local ok, err = pcall(function()
					applySolution(newModel, RoadMath.solveMove(info, farId, target))
				end)
				if not ok then
					warn("RoadHelper: Straight extension failed: " .. tostring(err))
				end
			end
		end
		return newModel, farId
	end

	-- Create a new intersection joined to an open road end: its ZMinus exit
	-- mates the end's actual face, sized square at 3x the road width, lane
	-- layout matching the road on both of its axes.
	local function createJoinedIntersection(openEnd: RoadMath.Endpoint): Model?
		local sourceModel = openEnd.Segment.Model
		local template = findTemplate("Intersection", openEnd.WorldCFrame.Position)
		local newModel: Model?
		if template then
			newModel = template.Model:Clone()
			-- Keep the cloned geometry rather than clearing it: the engine
			-- only regenerates on change events, so a clone whose parameters
			-- all end up identical to the template's would otherwise stay
			-- empty. When anything does change, regeneration replaces the
			-- folder contents anyway.
		else
			-- No intersection anywhere: build one from the packaged template
			newModel = createFallbackSegmentModel("Intersection")
		end
		if not newModel then
			warn("RoadHelper: No RoadIntersection available to use as a template.")
			return nil
		end
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		local laneCount = sourceModel:GetAttribute("LaneCount")
		local laneWidth = sourceModel:GetAttribute("LaneWidth")
		newModel:SetAttribute("LaneCountZ", laneCount or 2)
		newModel:SetAttribute("LaneWidthZ", laneWidth or 24)
		newModel:SetAttribute("LaneCountX", laneCount or 2)
		newModel:SetAttribute("LaneWidthX", laneWidth or 24)
		newModel:SetAttribute("IntersectionAngle", 90)
		newModel:SetAttribute("ThroughRoad", true)

		-- Sized from the lane layout: the road width plus three extra lanes'
		-- worth of space for the corner turn radius
		local width = RoadMath.endpointWidth(openEnd)
		local boxSize = width + 3 * (if typeof(laneWidth) == "number" then laneWidth else 24)
		local size = Vector3.new(boxSize, 0, boxSize);
		(newModel :: any).Size = size
		-- ZMinus (local -Z) exit opposes the road end's actual face
		local outward = RoadMath.actualOutwardDirection(openEnd)
		local rotation = CFrame.lookAlong(Vector3.zero, -outward).Rotation
		local exitLocal = Vector3.new(0, -size.Y / 2, -boxSize / 2)
		newModel:PivotTo(rotation + (openEnd.WorldCFrame.Position - rotation:VectorToWorldSpace(exitLocal)))
		newModel.Parent = sourceModel.Parent
		return newModel
	end

	-- Add-drag state (from AddHandles)
	local addDragRef: EndpointRef? = nil
	local addSourceRef: EndpointRef? = nil
	local addDragOriginalAdjust: { [RoadMath.AdjustAxis]: number }? = nil
	local addBeforeSelection: SelectionSnapshot = nil
	-- Intersection adds can't resize on drag; the whole intersection (and the
	-- source road's end with it) moves instead
	local intersectionAdd: {
		Model: Model,
		StartPivot: CFrame,
		SourceRef: EndpointRef,
	}? = nil

	local function startAdd(turn: RoadMath.TurnDirection): number?
		local selected = getSelectedEndpoint()
		if not selected then
			return nil
		end
		gestureActive = true
		addBeforeSelection = snapshotSelection()
		if turn == "Intersection" then
			beginRecording("Add Intersection")
			local newModel = createJoinedIntersection(selected)
			if not newModel then
				finishRecording()
				gestureActive = false
				return nil
			end
			intersectionAdd = {
				Model = newModel,
				StartPivot = newModel:GetPivot(),
				SourceRef = { Model = selected.Segment.Model, Id = selected.Id },
			}
			-- Select the opposite exit, ready to keep extending
			selectedRef = { Model = newModel, Id = "ZPlus" }
			changeSignal:Fire()
			return selected.WorldCFrame.Position.Y
		end
		beginRecording("Add Segment")
		local newModel, farId = createJoinedSegment(selected, turn)
		if not newModel or not farId then
			finishRecording()
			gestureActive = false
			return nil
		end
		addDragRef = { Model = newModel, Id = farId }
		addDragOriginalAdjust = captureAdjust(addDragRef :: any)
		addSourceRef = { Model = selected.Segment.Model, Id = selected.Id }
		selectedRef = addDragRef
		changeSignal:Fire()
		local farEndpoint = resolveEndpoint(addDragRef)
		return if farEndpoint then farEndpoint.WorldCFrame.Position.Y else 0
	end

	local function applyAddDrag(worldPosition: Vector3)
		local ix = intersectionAdd
		if ix then
			-- Drag by the intersection's CENTRE: the cursor positions the
			-- middle of the box, and the extended road end follows the
			-- mating exit wherever it lands
			ix.Model:PivotTo(ix.StartPivot.Rotation + worldPosition)
			local ixInfo = RoadMath.getSegmentInfo(ix.Model)
			local roadInfo = RoadMath.getSegmentInfo(ix.SourceRef.Model)
			if ixInfo and roadInfo then
				local exit = RoadMath.getEndpoint(ixInfo, "ZMinus")
				local ok, err = pcall(function()
					applySolutionToRef(ix.SourceRef, RoadMath.solveMove(roadInfo, ix.SourceRef.Id, exit.WorldCFrame.Position))
				end)
				if not ok then
					warn("RoadHelper: Intersection placement failed: " .. tostring(err))
				end
			end
			changeSignal:Fire()
			return
		end
		local ref = addDragRef
		if not ref then
			return
		end
		-- Snap onto nearby open ends, but never back onto the endpoint this
		-- segment was just added to (that would make it degenerate)
		local snapMate: RoadMath.Endpoint? = nil
		worldPosition, snapMate = snapToOpenEndpoint(worldPosition, { ref.Model }, addSourceRef)
		local info = RoadMath.getSegmentInfo(ref.Model)
		if info then
			local ok, err = pcall(function()
				applySolutionToRef(ref, RoadMath.solveMove(info, ref.Id, worldPosition))
			end)
			if not ok then
				warn("RoadHelper: Segment placement failed: " .. tostring(err))
			end
		end
		if addDragOriginalAdjust then
			if snapMate then
				alignEndFaceToMate(ref, snapMate)
			else
				restoreAdjust(ref, addDragOriginalAdjust)
			end
		end
		changeSignal:Fire()
	end

	local function endAdd()
		addDragRef = nil
		addSourceRef = nil
		addDragOriginalAdjust = nil
		intersectionAdd = nil
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, addBeforeSelection, snapshotSelection())
		end
		addBeforeSelection = nil
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Whole-intersection transforms
	--------------------------------------------------------------------------

	-- Moving/rotating an intersection moves the model itself and drags every
	-- connected road end along so the joints stay sealed.
	local intersectionDrag: {
		Model: Model,
		StartPivot: CFrame,
		StartAngle: number,
		Connected: { IntersectionConnection },
	}? = nil

	local function startIntersectionTransform()
		local selected = getSelectedEndpoint()
		if not selected or selected.Segment.Kind ~= "Intersection" then
			return
		end
		local connected = collectIntersectionConnections(selected.Segment)
		local startAngle = selected.Segment.Model:GetAttribute("IntersectionAngle")
		intersectionDrag = {
			Model = selected.Segment.Model,
			StartPivot = selected.Segment.Model:GetPivot(),
			StartAngle = if typeof(startAngle) == "number" then startAngle else 90,
			Connected = connected,
		}
		gestureActive = true
		beginRecording("Move Intersection")
	end

	local function applyIntersectionTransform(pivot: CFrame)
		local state = intersectionDrag
		if not state then
			return
		end
		state.Model:PivotTo(pivot)
		reseatConnectedEnds(state.Model, state.Connected)
		changeSignal:Fire()
	end

	-- Removing an open exit of a 4-way intersection turns it into a T
	-- junction. The T generator always drops the -X stub, so the model is
	-- rotated by the right yaw (and the two roads' roles swapped when a Z
	-- exit is removed) such that the removed exit lands on -X. Every
	-- surviving exit keeps its exact world position and direction through
	-- the transform, so connected roads stay sealed untouched.
	local function getDeletableExits(): { RoadMath.Endpoint }
		local selected = getSelectedEndpoint()
		if not selected
			or selected.Segment.Kind ~= "Intersection"
			or selected.Segment.ThroughRoad == false
		then
			return {}
		end
		local exits = {}
		for _, endpoint in RoadMath.allEndpoints(selected.Segment) do
			if not partnerOfEndpoint(endpoint) then
				table.insert(exits, endpoint)
			end
		end
		return exits
	end

	local function deleteExit(exit: RoadMath.Endpoint)
		local model = exit.Segment.Model
		local selectedBefore = getSelectedEndpoint()
		local selectedPosition = if selectedBefore then selectedBefore.WorldCFrame.Position else nil
		local beforeSelection = snapshotSelection()
		gestureActive = true
		beginRecording("Make T Junction")
		local pivot = model:GetPivot()
		local size = (model :: any).Size :: Vector3
		local angleValue = model:GetAttribute("IntersectionAngle")
		local angleDeg = if typeof(angleValue) == "number" then angleValue else 90
		local yaw = 0
		if exit.Id == "XPlus" then
			yaw = 180
		elseif exit.Id == "ZPlus" then
			yaw = angleDeg
		elseif exit.Id == "ZMinus" then
			yaw = angleDeg - 180
		end
		if exit.Id == "ZPlus" or exit.Id == "ZMinus" then
			-- The X road becomes the (straight) crossbar and the Z road the
			-- angled stem: swap the per-road lane configs and box extents,
			-- and mirror the angle
			local countX = model:GetAttribute("LaneCountX")
			local countZ = model:GetAttribute("LaneCountZ")
			local widthX = model:GetAttribute("LaneWidthX")
			local widthZ = model:GetAttribute("LaneWidthZ")
			model:SetAttribute("LaneCountX", countZ or 2)
			model:SetAttribute("LaneCountZ", countX or 2)
			model:SetAttribute("LaneWidthX", widthZ or 24)
			model:SetAttribute("LaneWidthZ", widthX or 24)
			model:SetAttribute("IntersectionAngle", 180 - angleDeg);
			(model :: any).Size = Vector3.new(size.Z, size.Y, size.X)
		end
		model:SetAttribute("ThroughRoad", false)
		if yaw ~= 0 then
			model:PivotTo(CFrame.new(pivot.Position) * pivot.Rotation * CFrame.Angles(0, math.rad(yaw), 0))
		end
		-- Endpoint ids were reshuffled by the transform: re-select whichever
		-- surviving end is where the old selection was (or clear it if the
		-- selected exit is the one that was deleted)
		selectedRef = nil
		local newInfo = RoadMath.getSegmentInfo(model)
		if newInfo and selectedPosition then
			for _, endpoint in RoadMath.allEndpoints(newInfo) do
				if (endpoint.WorldCFrame.Position - selectedPosition).Magnitude < 1 then
					selectedRef = { Model = model, Id = endpoint.Id }
					break
				end
			end
		end
		-- Restore the selection through undo/redo like the add gestures do
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- The reverse: a T junction's missing exit can be restored, turning it
	-- back into a 4-way. Pure attribute toggle; nothing moves.
	local function getRestorableExit(): RoadMath.Endpoint?
		local selected = getSelectedEndpoint()
		if not selected
			or selected.Segment.Kind ~= "Intersection"
			or selected.Segment.ThroughRoad ~= false
		then
			return nil
		end
		return RoadMath.getEndpoint(selected.Segment, "XMinus")
	end

	local function restoreExit(exit: RoadMath.Endpoint)
		local beforeSelection = snapshotSelection()
		gestureActive = true
		beginRecording("Make Cross Intersection")
		exit.Segment.Model:SetAttribute("ThroughRoad", true)
		-- Select the freshly restored exit
		selectedRef = { Model = exit.Segment.Model, Id = "XMinus" }
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	local function endIntersectionTransform()
		intersectionDrag = nil
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- Add a free-standing segment in front of the camera (UI buttons). When
	-- presetAttributes is given the new segment takes that appearance instead
	-- of inheriting one from the selection or a nearby template.
	local function addInFrontOfCamera(
		kind: RoadMath.SegmentKind,
		alignToWorld: boolean?,
		presetAttributes: { [string]: any }?
	)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		-- Aim at what the camera is looking at, or a point ahead of the camera
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = {}
		local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 500, raycastParams)
		local target = if result
			then result.Position
			else camera.CFrame.Position + camera.CFrame.LookVector * 200

		-- Predictable template choice: the selected segment when there is one
		-- (its appearance is what the user is working with), otherwise the
		-- segment of the right kind closest to where the new one will spawn.
		local selected = getSelectedEndpoint()
		local template: RoadMath.SegmentInfo? = nil
		if selected and selected.Segment.Kind == kind then
			template = selected.Segment
		else
			template = findTemplate(kind, target)
		end
		local width = if presetAttributes
			then presetAttributes.LaneCount * presetAttributes.LaneWidth + 2 * presetAttributes.SidewalkWidth
			elseif template then template.Width
			elseif selected then RoadMath.endpointWidth(selected)
			else 64

		local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
		local yaw = math.atan2(look.X, look.Z)
		if alignToWorld then
			-- Snap the new segment to the nearest world axis
			yaw = math.round(yaw / (math.pi / 2)) * (math.pi / 2)
		end
		local rotation = CFrame.Angles(0, yaw, 0)

		local beforeSelection = snapshotSelection()
		beginRecording("Add Segment")
		local newModel: Model?
		if template then
			newModel = template.Model:Clone()
			-- Keep the cloned geometry rather than clearing it: the engine
			-- only regenerates on change events, so a clone whose parameters
			-- all end up identical to the template's would otherwise stay
			-- empty. When anything does change, regeneration replaces the
			-- folder contents anyway.
		else
			newModel = createFallbackSegmentModel(kind)
		end
		if not newModel then
			finishRecording()
			warn(`RoadHelper: No {kind} road segment available to use as a template.`)
			return
		end
		if presetAttributes then
			-- The preset decides the appearance outright
			for name, value in presetAttributes do
				newModel:SetAttribute(name, value)
			end
		elseif selected and (template == nil or selected.Segment.Model ~= template.Model) then
			-- With a selection, appearance follows the selected segment even
			-- when the template for the geometry kind is some other segment
			for name, value in selected.Segment.Model:GetAttributes() do
				if not GEOMETRY_ATTRIBUTES[name] then
					newModel:SetAttribute(name, value)
				end
			end
			if selected.Segment.Kind == "Intersection" then
				local axis = if selected.Id == "XPlus" or selected.Id == "XMinus" then "X" else "Z"
				newModel:SetAttribute("LaneCount", selected.Segment.Model:GetAttribute("LaneCount" .. axis) or 2)
				newModel:SetAttribute("LaneWidth", selected.Segment.Model:GetAttribute("LaneWidth" .. axis) or 24)
			end
			width = RoadMath.endpointWidth(selected)
		end
		newModel:SetAttribute("Flip", false)
		for _, axis in ADJUST_AXES do
			newModel:SetAttribute(RoadMath.adjustAttributeName("Blue", axis), 0)
			newModel:SetAttribute(RoadMath.adjustAttributeName("Red", axis), 0)
		end

		local size = if kind == "Straight"
			then Vector3.new(width, 0, math.max(2 * width, RoadMath.MIN_LENGTH))
			else Vector3.new(2 * width, 0, 2 * width)

		-- Center the segment on the point the camera is looking at (the pivot
		-- is the bounding box center), rather than having it extend away out
		-- of view
		;(newModel :: any).Size = size
		newModel:PivotTo(rotation + target)
		newModel.Parent = if template then template.Model.Parent else workspace

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
				-- Intersection ends can only be extended, not moved/rotated
				if not endpoint or endpoint.Segment.Kind == "Intersection" then
					return nil
				end
				-- Handles align with the end's actual face, not the box
				return RoadMath.actualEndpointFrame(endpoint)
			end,
			GetDragExclusions = function(): { Instance }
				local exclusions: { Instance } = {}
				local selected = getSelectedEndpoint()
				if selected then
					table.insert(exclusions, selected.Segment.Model)
					local partner = getPartnerEndpoint()
					if partner then
						table.insert(exclusions, partner.Segment.Model)
						if partner.Segment.Kind == "Intersection" then
							-- The intersection and everything joined to it
							-- move along with the drag
							for _, endpoint in RoadMath.allEndpoints(partner.Segment) do
								local mate = partnerOfEndpoint(endpoint)
								if mate then
									table.insert(exclusions, mate.Segment.Model)
								end
							end
						end
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
				-- Intersection ends can only be extended, not moved/rotated
				if not endpoint or endpoint.Segment.Kind == "Intersection" then
					return nil
				end
				-- Handles align with the end's actual face, not the box
				return RoadMath.actualEndpointFrame(endpoint)
			end,
			StartRotate = startRotate,
			ApplyRotate = applyRotate,
			EndRotate = endRotate,
		}),
		-- Whole-intersection move (arrows + free drag) and yaw ring, shown at
		-- the intersection's centre when one of its ends is selected
		EndpointMoveHandles.new(draggerContext, {
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and endpoint.Segment.Kind == "Intersection" then
					return endpoint.Segment.Model:GetPivot()
				end
				return nil
			end,
			GetDragExclusions = function(): { Instance }
				local exclusions: { Instance } = {}
				local selected = getSelectedEndpoint()
				if selected and selected.Segment.Kind == "Intersection" then
					table.insert(exclusions, selected.Segment.Model)
					local state = intersectionDrag
					if state then
						for _, conn in state.Connected do
							table.insert(exclusions, conn.Ref.Model)
						end
					else
						for _, endpoint in RoadMath.allEndpoints(selected.Segment) do
							local partner = partnerOfEndpoint(endpoint)
							if partner then
								table.insert(exclusions, partner.Segment.Model)
							end
						end
					end
				end
				return exclusions
			end,
			StartMove = startIntersectionTransform,
			ApplyMove = function(newWorldPosition: Vector3)
				local state = intersectionDrag
				if state then
					applyIntersectionTransform(state.StartPivot.Rotation + newWorldPosition)
				end
			end,
			EndMove = endIntersectionTransform,
		}),
		EndpointRotateHandles.new(draggerContext, {
			Axes = { "Dir" },
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and endpoint.Segment.Kind == "Intersection" then
					return endpoint.Segment.Model:GetPivot()
				end
				return nil
			end,
			StartRotate = startIntersectionTransform,
			ApplyRotate = function(axis: RoadMath.AdjustAxis, deltaDegrees: number)
				local state = intersectionDrag
				if not state then
					return
				end
				local position = state.StartPivot.Position
				local yaw = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(deltaDegrees))
				applyIntersectionTransform(CFrame.new(position) * yaw * state.StartPivot.Rotation)
			end,
			EndRotate = endIntersectionTransform,
		}),
		-- Partial ring adjusting the intersection's angle (how much the X
		-- road is skewed), with its grabber sitting over the X road
		EndpointRotateHandles.new(draggerContext, {
			Axes = { "Dir" },
			View = PartialRotateHandleView,
			-- Twice the main ring's radius so it reads separately
			RadiusOffset = 5.2,
			Color = Color3.fromRGB(255, 200, 40),
			GetAngleOffset = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and endpoint.Segment.Kind == "Intersection" then
					-- The view's offset runs opposite to the world yaw of the
					-- X road, mirrored about the resting 90 degree position
					return 3 * math.pi / 2 - (endpoint.Segment.Angle or math.pi / 2)
				end
				return 0
			end,
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and endpoint.Segment.Kind == "Intersection" then
					return endpoint.Segment.Model:GetPivot()
				end
				return nil
			end,
			StartRotate = startIntersectionTransform,
			ApplyRotate = function(axis: RoadMath.AdjustAxis, deltaDegrees: number)
				local state = intersectionDrag
				if not state then
					return
				end
				local newAngle = math.clamp(math.round((state.StartAngle + deltaDegrees) * 10) / 10, 25, 155)
				if state.Model:GetAttribute("IntersectionAngle") ~= newAngle then
					state.Model:SetAttribute("IntersectionAngle", newAngle)
					reseatConnectedEnds(state.Model, state.Connected)
				end
				changeSignal:Fire()
			end,
			EndRotate = endIntersectionTransform,
		}),
		DeleteExitHandles.new(draggerContext, {
			GetDeletableExits = getDeletableExits,
			DeleteExit = deleteExit,
			GetRestorableExit = getRestorableExit,
			RestoreExit = restoreExit,
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
			GetPartner = partnerOfEndpoint,
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
		local laneAxisSuffix = ""
		if selected.Segment.Kind == "Intersection" then
			laneAxisSuffix = if selected.Id == "XPlus" or selected.Id == "XMinus" then "X" else "Z"
		end
		return {
			Kind = if partner then "closed" else "open",
			SegmentKind = selected.Segment.Kind,
			EndpointId = selected.Id,
			OtherSegmentKind = if partner then partner.Segment.Kind else nil,
			Dir = RoadMath.getAdjustValue(selected, "Dir"),
			Grade = RoadMath.getAdjustValue(selected, "Grade"),
			Bank = RoadMath.getAdjustValue(selected, "Bank"),
			Blend = selected.Segment.Model:GetAttribute("Blend") == true,
			TextureLaneMarkings = selected.Segment.Model:GetAttribute("TextureLaneMarkings") == true,
			MaxAngle = (selected.Segment.Model:GetAttribute("MaxAngle") :: number?) or 10,
			-- For intersections, the lane layout of the selected end's road
			LaneCount = (selected.Segment.Model:GetAttribute("LaneCount" .. laneAxisSuffix) :: number?) or 2,
			LaneWidth = (selected.Segment.Model:GetAttribute("LaneWidth" .. laneAxisSuffix) :: number?) or 24,
			SidewalkWidth = (selected.Segment.Model:GetAttribute("SidewalkWidth") :: number?) or 8,
			IntersectionAngle = (selected.Segment.Model:GetAttribute("IntersectionAngle") :: number?) or 90,
			CornerRadius = math.round((selected.Segment.Size.X - selected.Segment.Width) * 50) / 100,
		} :: any
	end

	-- Set a plain attribute of the selected endpoint's segment (from the UI)
	function session.SetSegmentAttribute(name: string, value: any)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		local connections = if selected.Segment.Kind == "Intersection"
			then collectIntersectionConnections(selected.Segment)
			else nil
		beginRecording("Edit Road")
		selected.Segment.Model:SetAttribute(name, value)
		if connections then
			-- Geometry-affecting attributes (like the intersection angle)
			-- move the exits; keep the joined roads sealed
			reseatConnectedEnds(selected.Segment.Model, connections)
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- Change the lane layout (LaneCount/LaneWidth/SidewalkWidth), compensating
	-- the bounds and pivot so both endpoints stay exactly where they are and
	-- any joints stay sealed.
	function session.SetSizing(name: string, value: number)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		local model = selected.Segment.Model
		if selected.Segment.Kind == "Intersection" then
			-- Adjust the selected end's road on the intersection. The box
			-- grows/shrinks with the width so the corner turn space is kept,
			-- which moves the exits; the joined roads follow to make space.
			local axis = if selected.Id == "XPlus" or selected.Id == "XMinus" then "X" else "Z"
			local function roadWidths(): (number, number)
				local sw = (model:GetAttribute("SidewalkWidth") :: number?) or 8
				local wZ = ((model:GetAttribute("LaneCountZ") :: number?) or 2)
					* ((model:GetAttribute("LaneWidthZ") :: number?) or 24) + 2 * sw
				local wX = ((model:GetAttribute("LaneCountX") :: number?) or 2)
					* ((model:GetAttribute("LaneWidthX") :: number?) or 24) + 2 * sw
				return wZ, wX
			end
			local connections = collectIntersectionConnections(selected.Segment)
			beginRecording("Resize Intersection")
			if name == "CornerRadius" then
				-- The corner curve radius maps to box size: each side of a
				-- road gets one radius' worth of excess space, so the corner
				-- fillets come out at (about) the requested radius
				local margin = 2 * math.max(value, 0)
				local wZ, wX = roadWidths()
				local size = (model :: any).Size :: Vector3
				;(model :: any).Size = Vector3.new(wZ + margin, size.Y, wX + margin)
			else
				local attrName = if name == "SidewalkWidth" then "SidewalkWidth" else name .. axis
				local oldWZ, oldWX = roadWidths()
				model:SetAttribute(attrName, value)
				local newWZ, newWX = roadWidths()
				local size = (model :: any).Size :: Vector3
				-- The Z road spans across the box's X extent and vice versa
				;(model :: any).Size = Vector3.new(size.X + (newWZ - oldWZ), size.Y, size.Z + (newWX - oldWX))
			end
			reseatConnectedEnds(model, connections)
			finishRecording()
			updateDragger()
			changeSignal:Fire()
			return
		end
		local layout: { [string]: number } = {
			LaneCount = (model:GetAttribute("LaneCount") :: number?) or 2,
			LaneWidth = (model:GetAttribute("LaneWidth") :: number?) or 24,
			SidewalkWidth = (model:GetAttribute("SidewalkWidth") :: number?) or 8,
		}
		layout[name] = value
		local newWidth = layout.LaneCount * layout.LaneWidth + 2 * layout.SidewalkWidth
		beginRecording("Resize Road")
		model:SetAttribute(name, value)
		local solution = RoadMath.solveWidthChange(selected.Segment, newWidth);
		(model :: any).Size = solution.Size
		model:PivotTo(solution.Pivot)
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- Toggle the blend skirt of the selected endpoint's segment
	function session.SetBlend(value: boolean)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		beginRecording("Toggle Skirt")
		selected.Segment.Model:SetAttribute("Blend", value)
		finishRecording()
		changeSignal:Fire()
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
