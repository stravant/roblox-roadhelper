--!optimize 2
--!native
-- Packaged copy of the ProceduralCarts StraightRoad generator, used by
-- RoadHelper as a fallback template when a place has no road segments yet.

type GenerationFunctionParams<Attributes> = {
	Attributes: Attributes,
	Size: Vector3,
	Pause: (self: GenerationFunctionParams<Attributes>) -> (),
}
type GeneratorModuleDefinition<Attributes> = {
	Attributes: Attributes,
	OnGenerate: (parameters: GenerationFunctionParams<Attributes>, targetContainer: GeneratedFolder) -> (),
}

local defaultAttributes = {
	LaneWidth = 24,
	LaneCount = 2,
	SidewalkWidth = 8,
	MaxAngle = 10,
	AdjustBlueGrade = 0,
	AdjustBlueDir = 0,
	AdjustBlueBank = 0,
	AdjustRedGrade = 0,
	AdjustRedDir = 0,
	AdjustRedBank = 0,
	Flip = false,
	Blend = false,
	BlendColor = Color3.fromRGB(66, 102, 12),
	BlendMaterial = Enum.Material.Grass,
	BlendAngle = 30,
	AdjustShowSnappingHelper = false,
	TextureLaneMarkings = false,
	CenterlineColor = Color3.fromRGB(244, 205, 47),
	LaneMarkingColor = Color3.fromRGB(163, 161, 165),
	RoadColor = Color3.fromRGB(26, 42, 52),
	SidewalkColor = Color3.fromRGB(163, 162, 165),
}

local ROAD_MATERIAL = Enum.Material.Concrete
local ROAD_MATERIAL_VARIANT = ""

local SIDEWALK_MATERIAL = Enum.Material.Concrete
local SIDEWALK_MATERIAL_VARIANT = ""

local SAND = Enum.Material.Sand
local SMOOTH = Enum.SurfaceType.Smooth
local MIN_SEGMENTS = 8
local LUT_N = 128

local DOTTED_MARK_TILE_LENGTH = 80

local ROAD_THICKNESS = 0.2
local CURB_HEIGHT = 1
local MARK_WIDTH = 0.8
local MARK_THICKNESS = 0.04
local CENTER_OFFSET = 1
local EDGE_INSET = 2.6

local BLEND_LENGTH = 12
local BLEND_THICKNESS = 1

-- Maximum out-of-plane corner deviation allowed for a twisted asphalt strip
-- quad before the surface falls back to narrower strips, at the default
-- MaxAngle of 10. Scales proportionally with MaxAngle so that lowering
-- MaxAngle for more fidelity also tightens the surface tessellation.
local MAX_TWIST_DEVIATION = 0.3

local function createPart(name, color, material, size, cframe)
	local part = Instance.new("Part")
	part.Anchored = true
	part.TopSurface = SMOOTH
	part.BottomSurface = SMOOTH
	part.Name = name
	part.Color = color
	part.Material = material
	part.Size = size
	part.CFrame = cframe
	return part
end

local Generator: GeneratorModuleDefinition<typeof(defaultAttributes)> = {
	Attributes = defaultAttributes,
	OnGenerate = function(parameters, targetContainer)
		local attributes = parameters.Attributes
		local size = parameters.Size
		local bottom = -size.Y / 2

		-- Lane layout drives the geometry: the lane count sets everything, and Width is the
		-- lanes plus the two sidewalks. An odd lane count means a shared center lane.
		-- Lane markings are painted within the roadway, so they don't widen it.
		local laneWidth = attributes.LaneWidth
		local numLanes = attributes.LaneCount
		local isCenterLaneDrawn = numLanes % 2 ~= 0

		local sidewalkWidth = attributes.SidewalkWidth or 8
		local width = numLanes * laneWidth + (sidewalkWidth * 2)
		local halfWidth = width / 2

		local hRoadTop = ROAD_THICKNESS
		local hSideTop = ROAD_THICKNESS + CURB_HEIGHT
		local edgeLine = halfWidth - sidewalkWidth - EDGE_INSET
		-- Blue adjustments apply to the start end of the road (u = 0), red to the end
		-- end (u = 1) — matching the colors of the snapping helper cubes.
		local gradeStartSlope = math.tan(math.rad(attributes.AdjustBlueGrade or 0))
		local gradeEndSlope = math.tan(math.rad(attributes.AdjustRedGrade or 0))
		local bankStart = math.rad(attributes.AdjustBlueBank or 0)
		local bankEnd = math.rad(attributes.AdjustRedBank or 0)
		local hasVerticality = size.Y / 2 >= 0.01
			or gradeStartSlope ~= 0 or gradeEndSlope ~= 0
			or bankStart ~= 0 or bankEnd ~= 0

		local roadColor = attributes.RoadColor
		local sidewalkColor = attributes.SidewalkColor
		local centerlineColor = attributes.CenterlineColor
		local laneMarkingColor = attributes.LaneMarkingColor
		local textureLaneMarkings = attributes.TextureLaneMarkings

		-- Path: a biarc — two circular arcs sharing a common tangent at their
		-- junction — connecting the two end poses. With zero turns this reduces to
		-- the classic S-bend (or a straight line). AdjustBlueDir/AdjustRedDir yaw each end
		-- pose about the vertical axis through its end-edge centre point (the
		-- snapping helpers mark the nominal box-aligned corners). Flip mirrors
		-- everything horizontally.
		local length = size.Z
		local sway = math.max((size.X - width) / 2, 0)
		local flipSign = if attributes.Flip then -1 else 1
		local dirStart = math.rad(attributes.AdjustBlueDir or 0)
		local dirEnd = math.rad(attributes.AdjustRedDir or 0)

		-- 2D plan-view rotation on (x, z), clockwise-positive: heading (0, 1) = +Z
		-- rotated by a positive angle tips toward +X.
		local function rot2(x, z, angle)
			local c, s = math.cos(angle), math.sin(angle)
			return x * c + z * s, -x * s + z * c
		end

		local halfX = sway + halfWidth
		local halfZ = length / 2
		local p0x, p0z = -sway, -halfZ
		local t0x, t0z = rot2(0, 1, dirStart)
		local p1x, p1z = sway, halfZ
		local t1x, t1z = rot2(0, 1, dirEnd)

		-- Biarc junction: with equal tangent parameters d the junction is
		-- J = (P0 + P1 + d*(T0 - T1)) / 2, where d solves
		-- 2(1 - T0.T1)*d^2 + 2*V.(T0 + T1)*d - |V|^2 = 0, V = P1 - P0.
		local vx, vz = p1x - p0x, p1z - p0z
		local qa = 2 * (1 - (t0x * t1x + t0z * t1z))
		local qb = 2 * (vx * (t0x + t1x) + vz * (t0z + t1z))
		local qc = -(vx * vx + vz * vz)
		local d = if qa >= 1e-9
			then (-qb + math.sqrt(qb * qb - 4 * qa * qc)) / (2 * qa)
			else -qc / math.max(qb, 1e-6)
		local jx = (p0x + p1x + d * (t0x - t1x)) / 2
		local jz = (p0z + p1z + d * (t0z - t1z)) / 2
		-- tangent at the junction (unit by construction)
		local jtx = (vx - d * (t0x + t1x)) / (2 * d)
		local jtz = (vz - d * (t0z + t1z)) / (2 * d)

		-- One half of the biarc: a circular arc (or a straight run when the tangent
		-- already points down the chord) from P leaving along T, ending at Q.
		local function makeArc(px, pz, tx, tz, qx, qz)
			local cx, cz = qx - px, qz - pz
			local chord2 = cx * cx + cz * cz
			local crossTC = tx * cz - tz * cx
			if chord2 < 1e-12 or math.abs(crossTC) < 1e-9 * chord2 then
				return { straight = true, len = math.sqrt(chord2), px = px, pz = pz, tx = tx, tz = tz }
			end
			-- centre sits along the right-hand perpendicular of T at signed distance tc
			local nx, nz = tz, -tx
			local tc = chord2 / (2 * (nx * cx + nz * cz))
			local ox, oz = px + nx * tc, pz + nz * tc
			local radius = math.abs(tc)
			local sweep = math.atan2(qx - ox, qz - oz) - math.atan2(px - ox, pz - oz)
			if tc > 0 then
				sweep %= (2 * math.pi) -- centre on the right: clockwise arc
			else
				sweep = -((-sweep) % (2 * math.pi)) -- centre on the left: counterclockwise
			end
			return { len = radius * math.abs(sweep), px = px, pz = pz, tx = tx, tz = tz, ox = ox, oz = oz, sweep = sweep }
		end
		local function arcAt(arc, s)
			if arc.straight then
				return arc.px + arc.tx * s, arc.pz + arc.tz * s, arc.tx, arc.tz
			end
			local phi = arc.sweep * (s / arc.len)
			local rx, rz = rot2(arc.px - arc.ox, arc.pz - arc.oz, phi)
			local fx, fz = rot2(arc.tx, arc.tz, phi)
			return arc.ox + rx, arc.oz + rz, fx, fz
		end

		local arc1 = makeArc(p0x, p0z, t0x, t0z, jx, jz)
		local arc2 = makeArc(jx, jz, jtx, jtz, p1x, p1z)
		local totalLen = arc1.len + arc2.len

		-- Cubic Hermite vertical profile: anchored exactly to the bounding box bottom at
		-- the start and top at the end, with end slopes set by AdjustBlueGrade/AdjustRedGrade (the
		-- grade basis functions u(u-1)^2 and u^2(u-1) vanish at both ends, so the anchors
		-- hold for any grade). Zero grades reduce this to the old smoothstep, flat at both
		-- ends.
		local gradeStartM = gradeStartSlope * totalLen
		local gradeEndM = gradeEndSlope * totalLen
		local function climbY(u)
			return bottom
				+ size.Y * (u * u * (3 - 2 * u))
				+ gradeStartM * (u * (u - 1) * (u - 1))
				+ gradeEndM * (u * u * (u - 1))
		end
		local function climbDeriv(u)
			return (size.Y * (6 * u * (1 - u))
				+ gradeStartM * (3 * u * u - 4 * u + 1)
				+ gradeEndM * (3 * u * u - 2 * u)) / totalLen
		end

		-- centre-line (x, z) and horizontal forward (fx, fz) at arc length s
		local function pathAt(s)
			local x, z, fx, fz
			if s <= arc1.len then
				x, z, fx, fz = arcAt(arc1, s)
			else
				x, z, fx, fz = arcAt(arc2, math.min(s - arc1.len, arc2.len))
			end
			return flipSign * x, z, flipSign * fx, fz
		end

		-- Bank rolls the cross-section about the (pitched) tangent — i.e. it applies
		-- after dir and grade — blending from AdjustBlueBank (start) to AdjustRedBank (end) with a
		-- smoothstep so each end hits its configured bank exactly, with zero roll rate.
		local function bankAt(u)
			return bankStart + (bankEnd - bankStart) * (u * u * (3 - 2 * u))
		end
		local function pathSliceCFrameAt(s)
			local x, z, fx, fz = pathAt(s)
			local u       = s / totalLen
			local lateral = Vector3.new(fz, 0, -fx)
			local tangent = Vector3.new(fx, climbDeriv(u), fz).Unit
			local up      = tangent:Cross(lateral)
			local bank = bankAt(u)
			if bank ~= 0 then
				local roll = CFrame.fromAxisAngle(tangent, bank)
				lateral = roll * lateral
				up = roll * up
			end
			return CFrame.fromMatrix(Vector3.new(x, climbY(u), z), lateral, up)
		end

		-- cost LUT over arc length: segmentation driven by direction change (the
		-- horizontal turn plus any climb pitch, via the 3D tangent) plus twist (bank
		-- changing along the road), both measured vs MaxAngle.
		local maxAngle = math.rad(attributes.MaxAngle or 5)
		local costLut = {}
		costLut[1] = 0
		local _, _, p0fx, p0fz = pathAt(0)
		local prevTan = Vector3.new(p0fx, climbDeriv(0), p0fz).Unit
		for i = 2, LUT_N + 1 do
			local s = (i - 1) / LUT_N * totalLen
			local _, _, fx, fz = pathAt(s)
			local tan = Vector3.new(fx, climbDeriv(s / totalLen), fz).Unit
			local twist = math.abs(bankAt((i - 1) / LUT_N) - bankAt((i - 2) / LUT_N))
			costLut[i] = costLut[i - 1]
				+ math.acos(math.clamp(tan:Dot(prevTan), -1, 1)) / maxAngle
				+ twist / maxAngle
			prevTan = tan
		end
		local totalCost = costLut[LUT_N + 1]
		-- queries arrive in increasing cost order, so resume the scan where the last
		-- one left off instead of rescanning the LUT from the start each time
		local lutCursor = 2
		local function sForCost(c)
			for i = lutCursor, LUT_N + 1 do
				if costLut[i] >= c then
					lutCursor = i
					local seg = costLut[i] - costLut[i - 1]
					return ((i - 2) + (if seg > 0 then (c - costLut[i - 1]) / seg else 0)) / LUT_N * totalLen
				end
			end
			return totalLen
		end

		-- A path with no meaningful direction change (dead straight and flat) has
		-- nothing to subdivide for; skip the segment floor and emit minimal slices.
		local innerSliceCount = if totalCost < 0.01
			then 1
			else math.max(1, MIN_SEGMENTS - 2, math.ceil(totalCost) - 1)
		local totalNumSegments = innerSliceCount + 2
		local fullCost = totalCost / (innerSliceCount + 1)
		local sliceCFrames = {}
		sliceCFrames[1] = pathSliceCFrameAt(0)
		for i = 0, innerSliceCount do
			local s = if fullCost > 0
				then sForCost(fullCost * (0.5 + i))
				else (i + 0.5) / (innerSliceCount + 1) * totalLen
			sliceCFrames[i + 2] = pathSliceCFrameAt(s)
		end
		sliceCFrames[totalNumSegments + 1] = pathSliceCFrameAt(totalLen)
		-- ends need no squaring: the end slices use the exact turned end headings, and
		-- the climb profile's end pitch is exactly the configured grade (zero by default).

		-- two WedgeParts forming triangle pa-pb-pc, extruded `thickness` to the underside
		local function tri(pa, pb, pc, color, material, mVariant, thickness)
			parameters:Pause()
			local a2, b2, c2 = pa, pb, pc
			local ab, ac, bc = b2 - a2, c2 - a2, c2 - b2
			local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
			if abd > acd and abd > bcd then
				c2, a2 = a2, c2
			elseif acd > bcd and acd > abd then
				a2, b2 = b2, a2
			end
			ab, ac, bc = b2 - a2, c2 - a2, c2 - b2
			local crossV = ac:Cross(ab)
			if crossV.Magnitude < 1e-3 * ab.Magnitude * ac.Magnitude
				or crossV.Magnitude < 1e-6 then
				return
			end
			local right = crossV.Unit
			local up = bc:Cross(right).Unit
			local back = bc.Unit
			local height = math.abs(ab:Dot(up))
			local upN = if right.Y >= 0 then right else -right
			local shift = -upN * (thickness / 2)
			local function wedge(pos, rx, vz, depth)
				local w = Instance.new("WedgePart")
				w.Anchored = true
				w.TopSurface = SMOOTH
				w.BottomSurface = SMOOTH
				w.Name = "Fill"
				w.Color = color
				w.Material = material
				w.MaterialVariant = mVariant
				w.Size = Vector3.new(thickness, height, depth)
				w.CFrame = CFrame.fromMatrix(pos + shift, rx, up, vz)
				w.Parent = targetContainer
			end
			wedge((a2 + b2) / 2, right, back, math.abs(ab:Dot(back)))
			wedge((a2 + c2) / 2, -right, -back, math.abs(ac:Dot(back)))
		end
		-- Planar rectangle fast path: one box Part covers what would otherwise take
		-- four WedgeParts. Every asphalt/curb quad on a straight flat run hits this.
		local function quad(p1, p2, p3, p4, color, material, mVariant, thickness)
			local e1, e2 = p2 - p1, p3 - p2
			local e1len, e2len = e1.Magnitude, e2.Magnitude
			if e1len > 1e-4 and e2len > 1e-4
				and (e1 + (p4 - p3)).Magnitude < 1e-4
				and (e2 + (p1 - p4)).Magnitude < 1e-4
				and math.abs(e1:Dot(e2)) < 1e-4 * e1len * e2len then
				local upN = e2:Cross(e1).Unit
				if upN.Y < 0 then
					upN = -upN
				end
				local center = (p1 + p2 + p3 + p4) / 4 - upN * (thickness / 2)
				local w = createPart(
					"Fill",
					color,
					material,
					Vector3.new(e1len, thickness, e2len),
					CFrame.fromMatrix(center, e1 / e1len, upN)
				)
				w.MaterialVariant = mVariant
				w.Parent = targetContainer
				return
			end
			tri(p1, p2, p3, color, material, mVariant, thickness)
			tri(p1, p3, p4, color, material, mVariant, thickness)
		end

		--[[
			Draw the actual road
		--]]
		-- Build a sorted list of every lane marking: its lateral position and color.
		-- Edge markings are always present; the rest depend on lane count parity.
		local laneMarkings = {
			{ lat = -edgeLine, color = laneMarkingColor },
			{ lat = edgeLine, color = laneMarkingColor },
		}

		if not isCenterLaneDrawn then
			-- Even lane count: a lane boundary sits on the centreline, so opposing traffic is
			-- split by the double-yellow center lines; interior boundaries get dotted dividers.
			local half = numLanes / 2

			for i = 1, half - 1 do
				table.insert(laneMarkings, {
					lat = -i * laneWidth,
					color = laneMarkingColor,
					isDotted = true,
				})
				table.insert(laneMarkings, {
					lat = i * laneWidth,
					color = laneMarkingColor,
					isDotted = true,
				})
			end
			table.insert(laneMarkings, { lat = -CENTER_OFFSET, color = centerlineColor })
			table.insert(laneMarkings, { lat = CENTER_OFFSET, color = centerlineColor })
		else
			-- Odd lane count: a shared center lane straddles lat = 0, bounded by yellow lines
			local markingsOnEachSide = (numLanes - 1) / 2
			local halfLaneWidth = laneWidth / 2

			for _, sign in { -1, 1 } do
				for i = 1, markingsOnEachSide do
					local lat = (halfLaneWidth + (i - 1) * laneWidth) * sign
					if i == 1 then
						table.insert(laneMarkings, {
							lat = lat - (1 * sign),
							color = centerlineColor,
							isDotted = true,
							dotOffset = 4,
							skipAsphaltBoundary = true,
						})
						table.insert(laneMarkings, {
							lat = lat,
							color = centerlineColor,
						})
					else
						table.insert(laneMarkings, {
							lat = lat,
							color = laneMarkingColor,
							isDotted = true,
						})
					end
				end
			end
		end

		table.sort(laneMarkings, function(a, b)
			return a.lat < b.lat
		end)

		-- Asphalt surface: one quad-strip per lane, with boundaries at marking centers.
		-- The outer strips (-halfWidth → first marking and last marking → +halfWidth)
		-- cover the road shoulders that sit under the raised curbs.
		local asphaltBoundaries
		if hasVerticality then
			-- Road climbs: split at every marking so each quad stays close to planar
			asphaltBoundaries = {}
			table.insert(asphaltBoundaries, -halfWidth)
			for _, marking in laneMarkings do
				if not marking.skipAsphaltBoundary then
					table.insert(asphaltBoundaries, marking.lat)
				end
			end
			table.insert(asphaltBoundaries, halfWidth)
		else
			-- Flat road: a single strip across the full width is always planar
			asphaltBoundaries = { -halfWidth, halfWidth }
		end

		-- Twist makes strip quads non-planar, and their triangles crease visibly
		-- when a strip is wide (e.g. one wide lane). Twist comes from the ends
		-- having different bank, but also geometrically from changing heading
		-- while climbing (roll about the chord ~ heading change * sin(pitch)), so
		-- measure it directly from the slice frames: the angle between adjacent
		-- slices' lateral axes in the plane perpendicular to the segment chord.
		-- When the worst per-segment twist would push a strip's corners too far
		-- out of plane, fall back to subdividing the surface into multiple
		-- narrower strips, like extra lanes' worth of tessellation.
		local maxSegmentTwist = 0
		for i = 1, totalNumSegments do
			local a, b = sliceCFrames[i], sliceCFrames[i + 1]
			local chord = b.Position - a.Position
			if chord.Magnitude > 1e-4 then
				local axis = chord.Unit
				local la = a.RightVector - axis * a.RightVector:Dot(axis)
				local lb = b.RightVector - axis * b.RightVector:Dot(axis)
				if la.Magnitude > 1e-4 and lb.Magnitude > 1e-4 then
					local twist = math.acos(math.clamp(la.Unit:Dot(lb.Unit), -1, 1))
					maxSegmentTwist = math.max(maxSegmentTwist, twist)
				end
			end
		end
		if maxSegmentTwist > 0.001 then
			-- Corner deviation of a strip of width w twisted by t is ~(w/2)*sin(t/2)
			local twistDeviation = MAX_TWIST_DEVIATION * maxAngle / math.rad(10)
			local maxStripWidth = (2 * twistDeviation) / math.sin(math.min(maxSegmentTwist, math.pi) / 2)
			local subdivided = { asphaltBoundaries[1] }
			for i = 2, #asphaltBoundaries do
				local a, b = asphaltBoundaries[i - 1], asphaltBoundaries[i]
				local pieces = math.max(math.ceil((b - a) / maxStripWidth - 0.01), 1)
				for piece = 1, pieces - 1 do
					table.insert(subdivided, a + (b - a) * piece / pieces)
				end
				table.insert(subdivided, b)
			end
			asphaltBoundaries = subdivided
		end

		for segIndex = 1, totalNumSegments do
			local thisSlice = sliceCFrames[segIndex]
			local nextSlice = sliceCFrames[segIndex + 1]

			for boundIndex = 1, #asphaltBoundaries - 1 do
				local leftEdge = asphaltBoundaries[boundIndex]
				local rightEdge = asphaltBoundaries[boundIndex + 1]
				local stripWidth = rightEdge - leftEdge
				if stripWidth > 0.01 then
					quad(
						thisSlice * Vector3.new(leftEdge, hRoadTop, 0),
						thisSlice * Vector3.new(rightEdge, hRoadTop, 0),
						nextSlice * Vector3.new(rightEdge, hRoadTop, 0),
						nextSlice * Vector3.new(leftEdge, hRoadTop, 0),
						roadColor,
						ROAD_MATERIAL,
						ROAD_MATERIAL_VARIANT,
						ROAD_THICKNESS
					)
				end
			end
		end

		-- Raised curbs / sidewalks
		for _, sgn in { -1, 1 } do
			local innerLat = sgn * (halfWidth - sidewalkWidth)
			local outerLat = sgn * halfWidth
			for i = 1, totalNumSegments do
				local fa, fb = sliceCFrames[i], sliceCFrames[i + 1]
				quad(
					fa * Vector3.new(innerLat, hSideTop, 0),
					fa * Vector3.new(outerLat, hSideTop, 0),
					fb * Vector3.new(outerLat, hSideTop, 0),
					fb * Vector3.new(innerLat, hSideTop, 0),
					sidewalkColor,
					SIDEWALK_MATERIAL,
					SIDEWALK_MATERIAL_VARIANT,
					CURB_HEIGHT
				)
			end
		end

		--[[
			Markings:

			Pre-compute cumulative arc lengths along the road centreline.
			All dotted markings share this reference so their dot phases stay in sync
			around curves, where outer lanes would otherwise accumulate more length than inner ones.
		--]]
		local centerlineArcLength = { [1] = 0 }
		for i = 1, totalNumSegments do
			local centreA = sliceCFrames[i] * Vector3.new(0, hRoadTop + 0.05, 0)
			local centreB = sliceCFrames[i + 1] * Vector3.new(0, hRoadTop + 0.05, 0)
			centerlineArcLength[i + 1] = centerlineArcLength[i] + (centreB - centreA).Magnitude + 0.05
		end

		for _, marking in laneMarkings do
			local color = marking.color
			local lat = marking.lat
			local isDotted = marking.isDotted
			local dotOffset = marking.dotOffset or 0

			for i = 1, totalNumSegments do
				parameters:Pause()
				local pa = sliceCFrames[i] * Vector3.new(lat, hRoadTop + 0.05, 0)
				local pb = sliceCFrames[i + 1] * Vector3.new(lat, hRoadTop + 0.05, 0)
				if (pb - pa).Magnitude < 1e-4 then
					continue
				end

				local markingSegmentLength = (pb - pa).Magnitude + 0.05

				local part = createPart(
					"RoadMarking",
					color,
					SAND,
					Vector3.new(markingSegmentLength, MARK_THICKNESS, MARK_WIDTH),
					CFrame.lookAt((pa + pb) / 2, pb, sliceCFrames[i].UpVector) * CFrame.Angles(0, -math.pi / 2, 0)
				) :: BasePart

				-- Textured markings hide the part and paint a texture on top (dashes for
				-- dotted lines); untextured ones just show the part's color and material,
				-- rendering every marking as a solid strip.
				if textureLaneMarkings then
					local texture = Instance.new("Texture")
					texture.Face = Enum.NormalId.Top
					texture.Color3 = color

					if isDotted then
						local centrelineSegmentLength = centerlineArcLength[i + 1] - centerlineArcLength[i]

						-- Stretch or compress the tile period proportionally to how much longer/shorter
						-- this marking segment is vs the centreline segment. This guarantees the UV
						-- at the end of this part equals the UV at the start of the next one.
						local ratio = markingSegmentLength / centrelineSegmentLength
						local studsPerTileU = DOTTED_MARK_TILE_LENGTH * ratio

						-- Advance phase using centreline arc length so all lanes stay in sync.
						-- The 0.3125 shift places the road start at the midpoint of the first gap.
						local gapPhaseOffset = 0.3125 * DOTTED_MARK_TILE_LENGTH
						local offsetStudsU = ratio * (centerlineArcLength[i] + gapPhaseOffset)

						texture.ColorMap = "rbxassetid://129215561553463"
						texture.StudsPerTileU = studsPerTileU
						texture.StudsPerTileV = MARK_WIDTH
						texture.OffsetStudsU = offsetStudsU + dotOffset
					else
						texture.ColorMap = "rbxassetid://127451784449848"
						texture.StudsPerTileU = 21.4
						texture.StudsPerTileV = MARK_WIDTH
					end
					texture.Parent = part

					part.Transparency = 1
				end
				part.Parent = targetContainer
			end
		end

		--[[
			Blend skirts: sloped fill along each outer edge that ramps down into the surrounding
			terrain, hiding the hard road/terrain seam. They jut outside the model's bounding box
			and don't factor into the Width computation. One simple box part per segment per side
			keeps the part count low; on the inside of curves the boxes just overlap, which is
			fine for buried fill.
		--]]
		if attributes.Blend then
			local blendColor = attributes.BlendColor
			local blendMaterial = attributes.BlendMaterial
			local blendAngle = math.rad(attributes.BlendAngle or 30)
			local cosA, sinA = math.cos(blendAngle), math.sin(blendAngle)
			-- No sidewalk means no raised curb: the skirt attaches at road level instead
			local blendTop = if sidewalkWidth > 0 then hSideTop else hRoadTop
			for _, sgn in { -1, 1 } do
				local prevAlongU, prevDownU
				for i = 1, totalNumSegments do
					parameters:Pause()
					local fa, fb = sliceCFrames[i], sliceCFrames[i + 1]
					local topA = fa * Vector3.new(sgn * halfWidth, blendTop, 0)
					local topB = fb * Vector3.new(sgn * halfWidth, blendTop, 0)
					local slopeA = fa:VectorToWorldSpace(Vector3.new(sgn * cosA, -sinA, 0)) * BLEND_LENGTH
					local slopeB = fb:VectorToWorldSpace(Vector3.new(sgn * cosA, -sinA, 0)) * BLEND_LENGTH

					if hasVerticality then
						-- Climbing road: the skirt surface twists along the climb, so draw it as
						-- quads that follow the slice frames, like the road surface does. Adjacent
						-- quads share their slice edges exactly, so no gaps open at the joints.
						quad(topA, topB, topB + slopeB, topA + slopeA, blendColor, blendMaterial, "", BLEND_THICKNESS)
						continue
					end

					local along = topB - topA
					local alongLen = along.Magnitude
					if alongLen < 1e-4 then
						prevAlongU, prevDownU = nil, nil
						continue
					end
					local alongU = along.Unit
					-- Mean slope, projected perpendicular to the chord. Where curvature changes
					-- across a segment (e.g. the S inflection) the two slice slopes don't tilt
					-- symmetrically fore/aft, so the raw average has an along-track component
					-- that would drift the box off its joints; anchoring to the top edge and
					-- removing that component keeps the boxes registered exactly.
					local meanSlope = (slopeA + slopeB) / 2
					local downSlope = meanSlope - alongU * meanSlope:Dot(alongU)
					if downSlope.Magnitude < 1e-4 then
						prevAlongU, prevDownU = nil, nil
						continue
					end
					local downU = downSlope.Unit
					local normal = alongU:Cross(downU)
					if normal.Y < 0 then
						normal = -normal
					end
					local center = (topA + topB) / 2 + downU * (BLEND_LENGTH / 2) - normal * (BLEND_THICKNESS / 2)
					local part = createPart(
						"BlendFill",
						blendColor,
						blendMaterial,
						Vector3.new(alongLen, BLEND_THICKNESS, BLEND_LENGTH),
						CFrame.fromMatrix(center, alongU, normal)
					)
					part.Parent = targetContainer

					-- On the outward side of a bend the boxes fan apart, leaving a triangular
					-- gap at the joint (flat road => a plain isoceles triangle), which tri()
					-- fills with just two back-to-back wedges. On the inward side the boxes
					-- overlap instead, which the signed test skips.
					if prevDownU then
						local gapA = topA + prevDownU * BLEND_LENGTH
						local gapB = topA + downU * BLEND_LENGTH
						if (gapB - gapA):Dot(prevAlongU + alongU) > 1e-4 then
							tri(topA, gapA, gapB, blendColor, blendMaterial, "", BLEND_THICKNESS)
						end
					end
					prevAlongU, prevDownU = alongU, downU
				end
			end
		end

		-- Snapping helpers: cubes marking the nominal box-aligned corners of each end
		-- face (where the edge corners sit at zero turn) — blue at the start end, red
		-- at the end end, matching the AdjustBlue*/AdjustRed* parameters. The cubes
		-- stay box aligned (unrotated) regardless of turn, since ends pivot about
		-- their centre.
		if attributes.AdjustShowSnappingHelper then
			-- Each cube is pushed 2 studs into the bounds along the road's nominal
			-- (un-turned) end direction only — never laterally, so an end's two cubes
			-- stay exactly a road width apart — and rests atop the snap level.
			local function helperCube(color, x, y, z)
				local cube = createPart(
					"SnappingHelper",
					color,
					Enum.Material.SmoothPlastic,
					Vector3.new(4, 4, 4),
					CFrame.new(flipSign * x, y + 2, z)
				)
				cube.CanCollide = false
				cube.Parent = targetContainer
			end
			local blue = Color3.fromRGB(0, 100, 255)
			local red = Color3.fromRGB(255, 40, 40)
			helperCube(blue, p0x - halfWidth, climbY(0), -halfZ + 2)
			helperCube(blue, p0x + halfWidth, climbY(0), -halfZ + 2)
			helperCube(red, p1x - halfWidth, climbY(1), halfZ - 2)
			helperCube(red, p1x + halfWidth, climbY(1), halfZ - 2)
		end
	end,
}

return Generator
