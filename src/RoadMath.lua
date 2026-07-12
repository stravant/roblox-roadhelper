--!strict
--[[
	RoadMath: Pure math for working with procedural road segments.

	A road segment is a ProceduralModel with a StraightRoadGenerator or
	CurveRoadGenerator ModuleScript child. Each segment has two endpoints:
	"Blue" (the start/entry end, matching the AdjustBlue* attributes) and
	"Red" (the end/exit end, matching AdjustRed*).

	Endpoint frames are the segments' *nominal* snap frames: positioned at the
	end edge centre (which is invariant under all the Adjust angle attributes),
	with LookVector pointing outward along the un-adjusted travel direction and
	UpVector equal to the model's up.

	Conventions used throughout (matching the generators):
	- width = LaneCount*LaneWidth + 2*SidewalkWidth
	- Straight: blue at local (-fs*sway, -Y/2, -Z/2) facing -Z, red at
	  (fs*sway, +Y/2, +Z/2) facing +Z, fs = Flip and -1 or 1,
	  sway = max((X - width)/2, 0). The road always climbs blue -> red.
	- Curve: blue at (-X/2 + w, blueY, -Z/2) facing -Z, red at
	  (X/2, redY, Z/2 - w) facing +X, w = width/2. Flip swaps which end is
	  at the top of the box vertically (blue is the top when Flip).
	- AdjustDir attributes are clockwise-positive in plan view, which matches
	  right-handed rotation about +Y with Roblox's CFrame.Angles.
]]

local RoadMath = {}

export type SegmentKind = "Straight" | "Curve" | "Intersection"
-- Roads have a Blue and a Red end; intersections have one id per stub
export type EndpointId = "Blue" | "Red" | "ZPlus" | "ZMinus" | "XPlus" | "XMinus"

export type SegmentInfo = {
	Model: Model, -- Actually a ProceduralModel
	Kind: SegmentKind,
	Width: number,
	Size: Vector3,
	Pivot: CFrame,
	Flip: boolean,
	-- Intersection-only fields: the X road's width, its angle from the Z
	-- road (radians), and whether the -X stub exists
	WidthX: number?,
	Angle: number?,
	ThroughRoad: boolean?,
}

export type Endpoint = {
	Segment: SegmentInfo,
	Id: EndpointId,
	WorldCFrame: CFrame,
}

export type MoveSolution = {
	Size: Vector3,
	Pivot: CFrame,
	Flip: boolean,
	-- True when the segment was rotated 180 degrees so its blue/red ends
	-- swap geographic places. The caller must also swap the segment's
	-- AdjustBlue*/AdjustRed* attributes (negating grades and banks) and
	-- re-color any endpoint references it holds.
	SwapEnds: boolean,
}

-- Shortest allowed segment (along the travel direction for straights)
RoadMath.MIN_LENGTH = 8

-- How close two endpoint centres must be to be considered joined
RoadMath.JOINT_TOLERANCE = 1

local GENERATOR_KINDS: { [string]: SegmentKind } = {
	StraightRoadGenerator = "Straight",
	CurveRoadGenerator = "Curve",
	RoadIntersectionGenerator = "Intersection",
}

--------------------------------------------------------------------------------
-- Segment discovery
--------------------------------------------------------------------------------

local function getNumberAttribute(model: Instance, name: string, default: number): number
	local value = model:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return default
end

function RoadMath.getSegmentInfo(instance: Instance): SegmentInfo?
	if instance.ClassName ~= "ProceduralModel" then
		return nil
	end
	local kind: SegmentKind? = nil
	for _, child in instance:GetChildren() do
		local foundKind = GENERATOR_KINDS[child.Name]
		if foundKind and child:IsA("ModuleScript") then
			kind = foundKind
			break
		end
	end
	if not kind then
		return nil
	end
	local model = instance :: Model
	local sidewalkWidth = getNumberAttribute(model, "SidewalkWidth", 8)
	if kind == "Intersection" then
		return {
			Model = model,
			Kind = kind,
			Width = getNumberAttribute(model, "LaneCountZ", 2) * getNumberAttribute(model, "LaneWidthZ", 24)
				+ 2 * sidewalkWidth,
			WidthX = getNumberAttribute(model, "LaneCountX", 2) * getNumberAttribute(model, "LaneWidthX", 24)
				+ 2 * sidewalkWidth,
			Angle = math.rad(math.clamp(getNumberAttribute(model, "IntersectionAngle", 90), 25, 155)),
			ThroughRoad = model:GetAttribute("ThroughRoad") ~= false,
			Size = (model :: any).Size :: Vector3,
			Pivot = model:GetPivot(),
			Flip = false,
		}
	end
	local laneWidth = getNumberAttribute(model, "LaneWidth", 24)
	local laneCount = getNumberAttribute(model, "LaneCount", 2)
	return {
		Model = model,
		Kind = kind,
		Width = laneCount * laneWidth + 2 * sidewalkWidth,
		Size = (model :: any).Size :: Vector3,
		Pivot = model:GetPivot(),
		Flip = model:GetAttribute("Flip") == true,
	}
end

-- Walk up from (typically) a generated road part to the segment it belongs to
function RoadMath.segmentFromDescendant(instance: Instance?): SegmentInfo?
	local current = instance
	while current and current ~= workspace and current ~= game do
		local info = RoadMath.getSegmentInfo(current)
		if info then
			return info
		end
		current = current.Parent
	end
	return nil
end

function RoadMath.findSegments(root: Instance): { SegmentInfo }
	local segments = {}
	-- Recurse manually so we can prune: segments never contain other segments
	-- (their contents are just the generator and generated geometry), and
	-- BaseParts never contain them either. This keeps rescans cheap even in
	-- places with a lot of generated road geometry.
	local function visit(container: Instance)
		for _, child in container:GetChildren() do
			local info = RoadMath.getSegmentInfo(child)
			if info then
				table.insert(segments, info)
			elseif not child:IsA("BasePart") then
				visit(child)
			end
		end
	end
	visit(root)
	return segments
end

--------------------------------------------------------------------------------
-- Endpoint frames
--------------------------------------------------------------------------------

-- Endpoint frame in the segment's local (pivot) space
function RoadMath.localEndpointFrame(kind: SegmentKind, size: Vector3, width: number, flip: boolean, id: EndpointId): CFrame
	local halfY = size.Y / 2
	local halfZ = size.Z / 2
	if kind == "Straight" then
		local sway = math.max((size.X - width) / 2, 0)
		local fs = if flip then -1 else 1
		if id == "Blue" then
			return CFrame.lookAlong(Vector3.new(-fs * sway, -halfY, -halfZ), -Vector3.zAxis)
		else
			return CFrame.lookAlong(Vector3.new(fs * sway, halfY, halfZ), Vector3.zAxis)
		end
	else
		local w = width / 2
		local halfX = size.X / 2
		if id == "Blue" then
			local y = if flip then halfY else -halfY
			return CFrame.lookAlong(Vector3.new(-halfX + w, y, -halfZ), -Vector3.zAxis)
		else
			local y = if flip then -halfY else halfY
			return CFrame.lookAlong(Vector3.new(halfX, y, halfZ - w), Vector3.xAxis)
		end
	end
end

-- An intersection's ends sit at the box bottom: the Z road's ends centred on
-- the ±Z faces, and the (possibly angled) X road's squared ends at halfX
-- along its own direction
local function intersectionEndpointFrame(segment: SegmentInfo, id: EndpointId): CFrame
	local size = segment.Size
	local halfY = size.Y / 2
	if id == "ZPlus" then
		return CFrame.lookAlong(Vector3.new(0, -halfY, size.Z / 2), Vector3.zAxis)
	elseif id == "ZMinus" then
		return CFrame.lookAlong(Vector3.new(0, -halfY, -size.Z / 2), -Vector3.zAxis)
	end
	local angle = segment.Angle or math.pi / 2
	local uX = Vector3.new(math.sin(angle), 0, math.cos(angle))
	local s = if id == "XPlus" then 1 else -1
	local p = uX * (s * size.X / 2)
	return CFrame.lookAlong(Vector3.new(p.X, -halfY, p.Z), uX * s)
end

function RoadMath.getEndpoint(segment: SegmentInfo, id: EndpointId): Endpoint
	local localFrame
	if segment.Kind == "Intersection" then
		localFrame = intersectionEndpointFrame(segment, id)
	else
		localFrame = RoadMath.localEndpointFrame(segment.Kind, segment.Size, segment.Width, segment.Flip, id)
	end
	return {
		Segment = segment,
		Id = id,
		WorldCFrame = segment.Pivot * localFrame,
	}
end

function RoadMath.getEndpoints(segment: SegmentInfo): (Endpoint, Endpoint)
	return RoadMath.getEndpoint(segment, "Blue"), RoadMath.getEndpoint(segment, "Red")
end

-- The endpoint ids a segment has
function RoadMath.endpointIds(segment: SegmentInfo): { EndpointId }
	if segment.Kind == "Intersection" then
		local ids: { EndpointId } = { "ZPlus", "ZMinus", "XPlus" }
		if segment.ThroughRoad then
			table.insert(ids, "XMinus")
		end
		return ids
	end
	return { "Blue", "Red" }
end

function RoadMath.allEndpoints(segment: SegmentInfo): { Endpoint }
	local endpoints = {}
	for _, id in RoadMath.endpointIds(segment) do
		table.insert(endpoints, RoadMath.getEndpoint(segment, id))
	end
	return endpoints
end

-- The road width at an endpoint (an intersection's X road can be a
-- different width than its Z road)
function RoadMath.endpointWidth(endpoint: Endpoint): number
	if endpoint.Id == "XPlus" or endpoint.Id == "XMinus" then
		return endpoint.Segment.WidthX or endpoint.Segment.Width
	end
	return endpoint.Segment.Width
end

-- The endpoint frame rotated to the end's *actual* face: the effective Dir
-- yaw applied about the frame's up axis, position unchanged. Used to align
-- handles and hover UX with the face rather than the bounding box.
function RoadMath.actualEndpointFrame(endpoint: Endpoint): CFrame
	local dirName = if endpoint.Id == "Blue" then "AdjustBlueDir" else "AdjustRedDir"
	local dirAngle = math.rad(getNumberAttribute(endpoint.Segment.Model, dirName, 0))
	dirAngle *= RoadMath.flipFactor(endpoint.Segment, "Dir")
	local frame = endpoint.WorldCFrame
	if dirAngle == 0 then
		return frame
	end
	return CFrame.fromAxisAngle(frame.UpVector, dirAngle) * (frame - frame.Position) + frame.Position
end

-- The outward direction of the end's *actual* (Adjust-angle rotated) face, in
-- world space, horizontal component only. Used for placing new segments off an
-- open end so they align with the face rather than the nominal frame.
function RoadMath.actualOutwardDirection(endpoint: Endpoint): Vector3
	local dirName = if endpoint.Id == "Blue" then "AdjustBlueDir" else "AdjustRedDir"
	local dirAngle = math.rad(getNumberAttribute(endpoint.Segment.Model, dirName, 0))
	dirAngle *= RoadMath.flipFactor(endpoint.Segment, "Dir")
	local nominalOutward = endpoint.WorldCFrame.LookVector
	local up = endpoint.WorldCFrame.UpVector
	return CFrame.fromAxisAngle(up, dirAngle):VectorToWorldSpace(nominalOutward)
end

--------------------------------------------------------------------------------
-- Joints
--------------------------------------------------------------------------------

-- Find the endpoint of another segment which is joined to this one (a "closed"
-- endpoint), or nil if the endpoint is open.
function RoadMath.findJoint(endpoint: Endpoint, segments: { SegmentInfo }): Endpoint?
	local position = endpoint.WorldCFrame.Position
	local outward = endpoint.WorldCFrame.LookVector
	local bestEndpoint: Endpoint? = nil
	local bestDistance = RoadMath.JOINT_TOLERANCE
	for _, segment in segments do
		if segment.Model == endpoint.Segment.Model then
			continue
		end
		for _, id in RoadMath.endpointIds(segment) do
			local other = RoadMath.getEndpoint(segment, id)
			local distance = (other.WorldCFrame.Position - position).Magnitude
			-- Faces must roughly oppose to count as a joint
			if distance <= bestDistance and other.WorldCFrame.LookVector:Dot(outward) < -0.5 then
				bestDistance = distance
				bestEndpoint = other
			end
		end
	end
	return bestEndpoint
end

--------------------------------------------------------------------------------
-- Moving endpoints
--------------------------------------------------------------------------------

-- Solve the new Size / Pivot / Flip for a segment when one of its endpoints is
-- moved to a new world position while its other endpoint stays fixed. The
-- segment's rotation is unchanged. Clamps keep the segment valid, so the moved
-- endpoint may not exactly reach the requested position.
function RoadMath.solveMove(segment: SegmentInfo, movedId: EndpointId, newWorldPosition: Vector3): MoveSolution
	local fixedId: EndpointId = if movedId == "Blue" then "Red" else "Blue"
	local fixedWorld = RoadMath.getEndpoint(segment, fixedId).WorldCFrame.Position
	local rotation = segment.Pivot.Rotation

	-- Delta from the blue endpoint to the red endpoint, in local space
	local delta = rotation:VectorToObjectSpace(newWorldPosition - fixedWorld)
	if movedId == "Blue" then
		delta = -delta
	end

	local swapEnds = false
	if segment.Kind == "Straight" and delta.Y < 0 then
		-- Straight roads always climb blue -> red. To pull this end below the
		-- other one, rotate the segment 180 degrees about vertical so the ends
		-- swap roles: the S-bend has 180-degree rotational symmetry, so the
		-- worldly shape (and the sway and Flip values) are preserved, and the
		-- dragged geographic end becomes the (bottom) blue end.
		swapEnds = true
		rotation = rotation * CFrame.Angles(0, math.pi, 0)
		movedId, fixedId = fixedId, movedId
		-- blue->red delta in the rotated frame: X and Z negate twice (once
		-- from reversing the ends, once from the 180 rotation), Y negates once
		delta = Vector3.new(delta.X, -delta.Y, delta.Z)
	end

	local width = segment.Width
	local newSize: Vector3
	local newFlip: boolean
	if segment.Kind == "Straight" then
		-- Lateral offset becomes sway (and its side selects Flip)
		newFlip = delta.X < 0
		newSize = Vector3.new(
			width + math.abs(delta.X),
			delta.Y,
			math.max(delta.Z, RoadMath.MIN_LENGTH)
		)
	else
		-- The corner's entry/exit are on perpendicular faces; each in-plane
		-- delta axis maps to one size axis. Flip selects which end is the top.
		newFlip = delta.Y < 0
		local w = width / 2
		newSize = Vector3.new(
			math.max(delta.X, width - w) + w,
			math.abs(delta.Y),
			math.max(delta.Z, width - w) + w
		)
	end

	-- Position the pivot so that the fixed endpoint stays where it was
	local newLocalFixed = RoadMath.localEndpointFrame(segment.Kind, newSize, width, newFlip, fixedId)
	local pivotPosition = fixedWorld - rotation:VectorToWorldSpace(newLocalFixed.Position)
	return {
		Size = newSize,
		Pivot = rotation + pivotPosition,
		Flip = newFlip,
		SwapEnds = swapEnds,
	}
end

-- The attribute updates accompanying a SwapEnds solution: the blue and red
-- adjust values trade places, following their geographic ends. Dir carries
-- over unchanged (yaw angles are frame independent for upright models);
-- grade and bank negate because the travel direction through each geographic
-- end reverses, preserving each face's actual world geometry.
function RoadMath.swappedAdjustValues(get: (name: string) -> number): { [string]: number }
	return {
		AdjustBlueDir = get("AdjustRedDir"),
		AdjustBlueGrade = -get("AdjustRedGrade"),
		AdjustBlueBank = -get("AdjustRedBank"),
		AdjustRedDir = get("AdjustBlueDir"),
		AdjustRedGrade = -get("AdjustBlueGrade"),
		AdjustRedBank = -get("AdjustBlueBank"),
	}
end

--------------------------------------------------------------------------------
-- Adjust angle mapping
--------------------------------------------------------------------------------

export type AdjustAxis = "Dir" | "Grade" | "Bank"

function RoadMath.adjustAttributeName(id: EndpointId, axis: AdjustAxis): string
	return "Adjust" .. (if id == "Blue" then "Blue" else "Red") .. axis
end

function RoadMath.getAdjustValue(endpoint: Endpoint, axis: AdjustAxis): number
	return getNumberAttribute(endpoint.Segment.Model, RoadMath.adjustAttributeName(endpoint.Id, axis), 0)
end

--[[
	Sign mapping for rotating a joint. The rotation gesture is measured at the
	*selected* endpoint's frame:
	- Dir: right-handed angle about the up axis
	- Grade: right-handed angle about the lateral (right) axis, so positive
	  tips the selected end's outward direction upward
	- Bank: right-handed angle about the selected end's outward axis

	For each end attached to the joint, the attribute delta is sign * angle:
	- Dir: +1 for every end (attribute yaw convention matches CFrame yaw for
	  upright models, and all mated faces rotate together about up)
	- Grade/Bank: colorSign * facingSign, where colorSign is +1 for Red and
	  -1 for Blue (Red's travel direction is outward, Blue's is inward), and
	  facingSign is +1 when the end faces the same way as the selected end
	  (i.e. it IS the selected end) and -1 for the mated partner.
]]
--[[
	How a segment's Flip attribute changes the *world* meaning of each Adjust
	attribute (mirroring the corresponding generator math):
	- Curve grades are multiplied by the climb sign, which Flip negates.
	- Straight Flip mirrors the path horizontally, negating the effective yaw
	  of the Dir attributes.
	- Banks (and the remaining combinations) are unaffected.
]]
function RoadMath.flipFactor(segment: SegmentInfo, axis: AdjustAxis): number
	if not segment.Flip then
		return 1
	end
	if axis == "Grade" and segment.Kind == "Curve" then
		return -1
	end
	if axis == "Dir" and segment.Kind == "Straight" then
		return -1
	end
	return 1
end

function RoadMath.adjustDeltaSign(selected: Endpoint, target: Endpoint, axis: AdjustAxis): number
	local flipFactor = RoadMath.flipFactor(target.Segment, axis)
	if axis == "Dir" then
		return flipFactor
	end
	local colorSign = if target.Id == "Red" then 1 else -1
	local facing = target.WorldCFrame.LookVector:Dot(selected.WorldCFrame.LookVector)
	local facingSign = if facing >= 0 then 1 else -1
	return colorSign * facingSign * flipFactor
end

-- The frame new segments are placed against. Normally the endpoint's
-- nominal frame, but an intersection's angled X exits square their outward
-- direction to the intersection's own box axis: the new segment stays
-- box-aligned with the intersection, and its joining end's Dir adjust takes
-- up the skew instead (see matchingAdjust).
function RoadMath.placementFrame(endpoint: Endpoint): CFrame
	if endpoint.Segment.Kind == "Intersection" and (endpoint.Id == "XPlus" or endpoint.Id == "XMinus") then
		local s = if endpoint.Id == "XPlus" then 1 else -1
		local outward = endpoint.Segment.Pivot:VectorToWorldSpace(Vector3.new(s, 0, 0))
		return CFrame.lookAlong(endpoint.WorldCFrame.Position, outward)
	end
	return endpoint.WorldCFrame
end

-- The Adjust values a newly added segment's joining end must have to mate
-- flush with the given open end. The new model is placed aligned with the
-- open end's nominal frame (not its Dir-rotated face), so the joining end
-- needs the same effective world Dir yaw as the open end: rotating both
-- faces of a joint by the same world yaw keeps them flush. The world yaw of
-- any end is flipFactor("Dir") * attribute about +Y regardless of end color,
-- and the new segment is unflipped, so its attribute is the effective yaw
-- directly.
function RoadMath.matchingAdjust(openEnd: Endpoint, newEndId: EndpointId): { Dir: number, Grade: number, Bank: number }
	if openEnd.Segment.Kind == "Intersection" then
		-- Flat exits: no grade/bank. Dir takes up the yaw between the
		-- box-aligned placement frame and the actual exit direction (zero
		-- for the Z exits, the skew for angled X exits).
		local n = RoadMath.placementFrame(openEnd).LookVector
		local d = openEnd.WorldCFrame.LookVector
		local yaw = math.deg(math.atan2(n:Cross(d).Y, n:Dot(d)))
		return { Dir = math.round(yaw * 100) / 100, Grade = 0, Bank = 0 }
	end
	local openColorSign = if openEnd.Id == "Red" then 1 else -1
	local newColorSign = if newEndId == "Red" then 1 else -1
	local k = -openColorSign * newColorSign
	-- The new segment is created unflipped, but the open end's attribute
	-- values must be converted through its own flip factors to get their
	-- actual world meaning.
	return {
		Dir = RoadMath.flipFactor(openEnd.Segment, "Dir") * RoadMath.getAdjustValue(openEnd, "Dir"),
		Grade = k * RoadMath.flipFactor(openEnd.Segment, "Grade") * RoadMath.getAdjustValue(openEnd, "Grade"),
		Bank = k * RoadMath.getAdjustValue(openEnd, "Bank"),
	}
end

--------------------------------------------------------------------------------
-- New segment placement
--------------------------------------------------------------------------------

export type TurnDirection = "Left" | "Straight" | "Right" | "Intersection"

-- Plan-view angle of a direction vector, matching the clockwise-positive
-- convention: angle(v) increases when v is rotated by CFrame.Angles(0, a, 0)
-- with positive a.
local function yawAngleOf(direction: Vector3): number
	return math.atan2(direction.X, direction.Z)
end

--[[
	Compute the placement for a new segment extending the given open end.
	Returns the segment kind, which end of the new segment joins the open end,
	the new segment's pivot CFrame, and its size.

	- Straight extends with a StraightRoad joined at its Blue end.
	- Right turns join a CurveRoad at its Blue (entry) end: entering the curve
	  and exiting +X is a right turn.
	- Left turns join a CurveRoad at its Red (exit) end, traversed backwards.
]]
function RoadMath.placeNewSegment(
	openEnd: Endpoint,
	turn: TurnDirection,
	width: number,
	sizeOverride: Vector3?
): (SegmentKind, EndpointId, CFrame, Vector3)
	local kind: SegmentKind = if turn == "Straight" then "Straight" else "Curve"
	local joinId: EndpointId = if turn == "Left" then "Red" else "Blue"

	local size = sizeOverride
	if not size then
		if kind == "Straight" then
			size = Vector3.new(width, 0, math.max(2 * width, RoadMath.MIN_LENGTH))
		else
			size = Vector3.new(2 * width, 0, 2 * width)
		end
	end
	assert(size)

	-- Yaw the new model so its joining end's nominal outward direction opposes
	-- the open end's PLACEMENT frame: the new model stays aligned the same way
	-- as the segment it extends (box-aligned for an intersection's angled
	-- exits), and any rotation of the actual face is matched by a Dir on the
	-- joining end instead (see matchingAdjust), keeping the joint flush.
	local placement = RoadMath.placementFrame(openEnd)
	local outward = placement.LookVector
	local joinLocal = RoadMath.localEndpointFrame(kind, size, width, false, joinId)
	local targetYaw = yawAngleOf(-outward)
	local nominalYaw = yawAngleOf(joinLocal.LookVector)
	local rotation = CFrame.Angles(0, targetYaw - nominalYaw, 0)

	local pivotPosition = placement.Position - rotation:VectorToWorldSpace(joinLocal.Position)
	return kind, joinId, rotation + pivotPosition, size
end

--------------------------------------------------------------------------------
-- Lane layout changes
--------------------------------------------------------------------------------

--[[
	Compensate the bounds (and pivot) for a road width change so that BOTH
	endpoint positions stay exactly where they are (keeping any joints sealed).

	Straight: endpoints sit at (±sway, ·, ±Z/2) with sway = (X - width)/2, so
	growing X by the width delta keeps sway (and both endpoints) unchanged.

	Curve: blue sits at (-X/2 + w/2, ·, -Z/2) and red at (X/2, ·, Z/2 - w/2)
	in pivot space. Solving both fixed under a delta d gives X' = X + d/2,
	Z' = Z + d/2, with the pivot (box centre) shifted by (-d/4, 0, d/4).
]]
function RoadMath.solveWidthChange(segment: SegmentInfo, newWidth: number): { Size: Vector3, Pivot: CFrame }
	local delta = newWidth - segment.Width
	local size = segment.Size
	if segment.Kind == "Straight" then
		return {
			Size = Vector3.new(math.max(size.X + delta, newWidth), size.Y, size.Z),
			Pivot = segment.Pivot,
		}
	else
		return {
			Size = Vector3.new(size.X + delta / 2, size.Y, size.Z + delta / 2),
			Pivot = segment.Pivot * CFrame.new(-delta / 4, 0, delta / 4),
		}
	end
end

return RoadMath
