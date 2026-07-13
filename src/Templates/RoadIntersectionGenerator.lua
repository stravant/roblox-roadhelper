--!optimize 2
--!native
-- Packaged copy of the ProceduralCarts RoadIntersection generator, used by
-- RoadHelper as a fallback template when a place has no intersections yet.

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
	LaneWidthX = 24,
	LaneCountX = 2,
	LaneWidthZ = 24,
	LaneCountZ = 2,
	SidewalkWidth = 8,
	IntersectionAngle = 90,
	MaxAngle = 10,
	ThroughRoad = true,
	CrossingWidth = 0,
	Blend = false,
	BlendColor = Color3.fromRGB(66, 102, 12),
	BlendMaterial = Enum.Material.Grass,
	BlendAngle = 30,
	HaveLaneMarkings = true,
	TextureLaneMarkings = false,
	AdjustShowSnappingHelper = false,
	RoadMaterial = Enum.Material.Concrete,
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

local ROAD_THICKNESS = 0.2
local CURB_HEIGHT = 1
local MARK_WIDTH = 0.8
local MARK_THICKNESS = 0.04
local CENTER_OFFSET = 1
local EDGE_INSET = 2.6
local BLEND_LENGTH = 12
local BLEND_THICKNESS = 1

local MARK_SETBACK = 2
local STOP_LINE_WIDTH = 2
-- The stop bar sits this far in from each open end, so the bounding box
-- controls how much open turning space the middle of the intersection has
local STOP_LINE_END_DISTANCE = 12
-- Crosswalk stripe width/spacing, and its gap to the stop bar
local CROSSWALK_STRIPE = 2
local CROSSWALK_GAP = 2

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

--[[
	RoadCrossIntersection: a four-way crossing of two StraightRoad-compatible
	roads. Road Z runs along +Z through the box centre; road X crosses it at
	IntersectionAngle (90 = perpendicular). Each road has its own lane count
	and lane width. A non-90 angle skews the crossing, which shifts where
	road X meets the ±X box faces (off centre along the face).

	The pavement decomposes into non-overlapping flat regions:
	- the central parallelogram where the two roads overlap,
	- four road stubs from the box faces to the parallelogram,
	- four corner fans bounded by a circular fillet of the two adjacent
	  pavement edges. The fillet's tangent length is maximised to the space
	  available in the box, so a bigger box gives smoother corner curves.
	Sidewalk (curb height) strips run along the stub edges and around the
	corner arcs. Markings continue along the stubs and end staggered along
	the crossing road's edge, with stop bars across the approach lanes.
]]

local Generator: GeneratorModuleDefinition<typeof(defaultAttributes)> = {
	Attributes = defaultAttributes,
	OnGenerate = function(parameters, targetContainer)
		local attributes = parameters.Attributes
		local size = parameters.Size
		local bottom = -size.Y / 2

		local sw = attributes.SidewalkWidth or 8
		local wX = attributes.LaneCountX * attributes.LaneWidthX + 2 * sw
		local wZ = attributes.LaneCountZ * attributes.LaneWidthZ + 2 * sw
		local halfX = size.X / 2
		local halfZ = size.Z / 2

		local angle = math.rad(math.clamp(attributes.IntersectionAngle or 90, 25, 155))
		local sinA, cosA = math.sin(angle), math.cos(angle)

		-- Plan-view unit vectors (y = 0): road Z runs along uZ, road X along uX
		local uZ = Vector3.zAxis
		local uX = Vector3.new(sinA, 0, cosA)
		local nZ = Vector3.xAxis
		local nX = Vector3.new(cosA, 0, -sinA)

		local hRoadTop = ROAD_THICKNESS
		local hSideTop = ROAD_THICKNESS + CURB_HEIGHT

		local roadColor = attributes.RoadColor
		local sidewalkColor = attributes.SidewalkColor
		local centerlineColor = attributes.CenterlineColor
		local laneMarkingColor = attributes.LaneMarkingColor
		local haveLaneMarkings = if attributes.HaveLaneMarkings ~= nil then attributes.HaveLaneMarkings else true
		local textureLaneMarkings = attributes.TextureLaneMarkings
		-- ThroughRoad = false drops the -X stub, turning the crossing into a T
		-- junction: the straight Z road becomes the continuous crossbar, and
		-- the ANGLED X road is the side road approaching from the +X side only
		local throughRoad = if attributes.ThroughRoad ~= nil then attributes.ThroughRoad else true
		local roadMaterial = attributes.RoadMaterial or ROAD_MATERIAL
		local roadMaterialVariant = if roadMaterial == ROAD_MATERIAL then ROAD_MATERIAL_VARIANT else ""

		local maxAngle = math.rad(attributes.MaxAngle or 10)
		local crossingWidth = math.max(attributes.CrossingWidth or 0, 0)

		local function at(p: Vector3, h: number): Vector3
			return Vector3.new(p.X, bottom + h, p.Z)
		end

		-- two WedgeParts forming triangle pa-pb-pc, extruded to the underside
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

		local function roadQuad(p1, p2, p3, p4)
			quad(at(p1, hRoadTop), at(p2, hRoadTop), at(p3, hRoadTop), at(p4, hRoadTop),
				roadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS)
		end
		local function walkQuad(p1, p2, p3, p4)
			quad(at(p1, hSideTop), at(p2, hSideTop), at(p3, hSideTop), at(p4, hSideTop),
				sidewalkColor, SIDEWALK_MATERIAL, SIDEWALK_MATERIAL_VARIANT, CURB_HEIGHT)
		end

		-- Blend skirt: one sloped box hanging off an outer boundary edge,
		-- ramping down into the surrounding terrain. The intersection is flat
		-- and its boundary is concave everywhere, so plain (overlapping) boxes
		-- cover it fully with no gap wedges needed.
		local blendColor = attributes.BlendColor
		local blendMaterial = attributes.BlendMaterial
		local blendAngle = math.rad(attributes.BlendAngle or 30)
		local cosB, sinB = math.cos(blendAngle), math.sin(blendAngle)
		local blendTop = if sw > 0 then hSideTop else hRoadTop
		local function blendBox(a: Vector3, b: Vector3, outward: Vector3)
			local topA = at(a, blendTop)
			local topB = at(b, blendTop)
			local along = topB - topA
			local alongLen = along.Magnitude
			if alongLen < 0.05 then
				return
			end
			local alongU = along.Unit
			local downU = outward * cosB - Vector3.yAxis * sinB
			local normal = alongU:Cross(downU)
			if normal.Y < 0 then
				normal = -normal
			end
			local boxCenter = (topA + topB) / 2 + downU * (BLEND_LENGTH / 2) - normal * (BLEND_THICKNESS / 2)
			local part = createPart(
				"BlendFill",
				blendColor,
				blendMaterial,
				Vector3.new(alongLen, BLEND_THICKNESS, BLEND_LENGTH),
				CFrame.fromMatrix(boxCenter, alongU, normal)
			)
			part.Parent = targetContainer
		end

		-- Corner of the central parallelogram on side sZ of road Z (its edge
		-- x = sZ*wZ/2) and side sX of road X (its edge p.nX = sX*wX/2)
		local function cornerPoint(sZ, sX): Vector3
			local x = sZ * wZ / 2
			local z = (sX * wX / 2 - x * cosA) / -sinA
			return Vector3.new(x, 0, z)
		end

		-- Central overlap parallelogram
		roadQuad(cornerPoint(1, 1), cornerPoint(1, -1), cornerPoint(-1, -1), cornerPoint(-1, 1))

		-- Road Z stubs: from the z = s*halfZ face to road X's near edge
		for _, s in { -1, 1 } do
			roadQuad(
				Vector3.new(-wZ / 2, 0, s * halfZ),
				Vector3.new(wZ / 2, 0, s * halfZ),
				cornerPoint(1, -s),
				cornerPoint(-1, -s)
			)
		end
		-- Road X stubs: from the x = t*halfX face to road Z's near edge
		-- (Squared ends: perpendicular to the road at halfX along it, the
		-- length it would have at 90 degrees, so straight segments join flush)
		for _, t in { -1, 1 } do
			if not throughRoad and t == -1 then
				continue
			end
			local endCentre = uX * (t * halfX)
			roadQuad(
				endCentre + nX * (wX / 2),
				endCentre - nX * (wX / 2),
				cornerPoint(t, -1),
				cornerPoint(t, 1)
			)
		end

		-- Corner fillets: at each corner the two roads' pavement edge lines
		-- meet; join them with an arc tangent to both, sized to the space
		-- available in the box (bigger box = smoother corner). The fillet
		-- centre sits on the OUTSIDE of the corner, so going inward from the
		-- arc means increasing radius: the raised sidewalk band spans
		-- [r, r + sw], i.e. from the pavement edge inward to the curb face,
		-- matching the road cross-section. Per corner data is kept for the
		-- markings pass below.
		local function rotY(v: Vector3, a: number): Vector3
			local c, s = math.cos(a), math.sin(a)
			return Vector3.new(v.X * c + v.Z * s, 0, -v.X * s + v.Z * c)
		end
		local cornerData = {}
		for _, sZ in { -1, 1 } do
			for _, sX in { -1, 1 } do
				if not throughRoad and sZ == -1 then
					-- T junction: no corners on the far side of the crossbar
					continue
				end
				local Pin = cornerPoint(sZ, sX)
				local eZdir = Vector3.new(0, 0, -sX)
				local eXdir = uX * sZ
				-- Distances along the pavement edges to the open end planes
				local dzAvail = (-sX * halfZ - Pin.Z) / -sX
				local dxAvail = halfX - sZ * Pin:Dot(uX)
				local d = math.min(dzAvail, dxAvail)
				if d > 0.5 then
					local theta = math.acos(math.clamp(eZdir:Dot(eXdir), -1, 1))
					local r = d * math.tan(theta / 2)
					local bis = (eZdir + eXdir).Unit
					local center = Pin + bis * (d / math.cos(theta / 2))
					local T1 = Pin + eZdir * d
					local T2 = Pin + eXdir * d
					local v1 = T1 - center
					local v2 = T2 - center
					local sweep = math.atan2(v2.X, v2.Z) - math.atan2(v1.X, v1.Z)
					if sweep > math.pi then
						sweep -= 2 * math.pi
					elseif sweep < -math.pi then
						sweep += 2 * math.pi
					end
					local steps = math.max(2, math.ceil(math.abs(sweep) / maxAngle))
					local dirs = {}
					for i = 0, steps do
						dirs[i + 1] = rotY(v1, sweep * i / steps) / r
					end
					-- Drivable flare out to the curb arc
					for i = 1, steps do
						tri(at(Pin, hRoadTop), at(center + dirs[i] * r, hRoadTop), at(center + dirs[i + 1] * r, hRoadTop),
							roadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS)
					end
					-- Sidewalk band: from the pavement-edge arc inward to the
					-- curb face (the flare fan provides its asphalt shoulder)
					for i = 1, steps do
						local inA = center + dirs[i] * r
						local inB = center + dirs[i + 1] * r
						local outA = center + dirs[i] * (r + sw)
						local outB = center + dirs[i + 1] * (r + sw)
						walkQuad(inA, outA, outB, inB)
					end
					-- Straight sidewalk strips from the arc ends to the open
					-- ends, INSIDE the pavement edge like the road profile
					if dzAvail - d > 1e-3 then
						local inward = nZ * (-sZ * sw)
						local endEdge = Pin + eZdir * dzAvail
						walkQuad(T1, T1 + inward, endEdge + inward, endEdge)
					end
					if dxAvail - d > 1e-3 then
						local inward = nX * (-sX * sw)
						local endEdge = Pin + eXdir * dxAvail
						walkQuad(T2, T2 + inward, endEdge + inward, endEdge)
					end
					if attributes.Blend then
						-- Skirt along this corner's stretch of the boundary: the
						-- arc (outward = radially toward the fillet centre, which
						-- sits outside the pavement) plus the straight runs out
						-- to the open ends
						for i = 1, steps do
							local aPt = center + dirs[i] * r
							local bPt = center + dirs[i + 1] * r
							blendBox(aPt, bPt, -(dirs[i] + dirs[i + 1]).Unit)
						end
						if dzAvail - d > 1e-3 then
							blendBox(T1, Pin + eZdir * dzAvail, nZ * sZ)
						end
						if dxAvail - d > 1e-3 then
							blendBox(T2, Pin + eXdir * dxAvail, nX * sX)
						end
					end
					-- Edge-line arc (concentric, EDGE_INSET inside the curb
					-- face, i.e. sw + EDGE_INSET inward of the pavement edge) and
					-- the handover points for the stubs' straight edge lines
					local edgeArc = {}
					for i = 1, steps + 1 do
						edgeArc[i] = center + dirs[i] * (r + sw + EDGE_INSET)
					end
					cornerData[sZ .. "," .. sX] = {
						edgeArc = edgeArc,
						-- Miter extension so consecutive chord strips meet at
						-- their outer corners instead of leaving a wedge gap
						edgeExtend = (MARK_WIDTH / 2) * math.tan(math.abs(sweep) / (2 * steps)),
						tZ = -sX * Pin.Z + d,
						tX = sZ * Pin:Dot(uX) + d,
					}
				end
			end
		end

		-- T junction: the far side of the crossbar has no corners; its
		-- sidewalk runs straight through from end to end instead
		if not throughRoad then
			local a = Vector3.new(-wZ / 2, 0, -halfZ)
			local b = Vector3.new(-wZ / 2, 0, halfZ)
			local inward = Vector3.new(sw, 0, 0)
			walkQuad(a, a + inward, b + inward, b)
			if attributes.Blend then
				blendBox(a, b, -Vector3.xAxis)
			end
		end

		--[[
			Markings: each road's lane markings continue along its stubs and
			end staggered along the crossing road's near pavement edge, plus a
			stop bar across the approach lanes of each stub.
		]]
		if haveLaneMarkings then
			local markingCount = 0
			local function markingStrip(a: Vector3, b: Vector3, color, width)
				local pa, pb = at(a, hRoadTop + 0.05), at(b, hRoadTop + 0.05)
				local len = (pb - pa).Magnitude
				if len < 0.5 then
					return
				end
				local part = createPart(
					"RoadMarking",
					color,
					SAND,
					Vector3.new(len, MARK_THICKNESS, width),
					CFrame.lookAt((pa + pb) / 2, pb) * CFrame.Angles(0, -math.pi / 2, 0)
				)
				if textureLaneMarkings then
					local texture = Instance.new("Texture")
					texture.Face = Enum.NormalId.Top
					texture.Color3 = color
					texture.ColorMap = "rbxassetid://127451784449848"
					texture.StudsPerTileU = 21.4
					texture.StudsPerTileV = width
					-- Sequence-seeded offset so consecutive strips (corner
					-- arc chords, crosswalk stripes) don't visibly repeat the
					-- same slice of the texture
					markingCount += 1
					texture.OffsetStudsU = (markingCount * 7.31) % 21.4
					texture.Parent = part
					part.Transparency = 1
				end
				part.Parent = targetContainer
			end

			-- The lane marking lats/colors for one road (drawn solid; lane
			-- lines are conventionally solid approaching an intersection)
			local function buildMarkings(laneWidth, numLanes, w)
				local edgeLine = w / 2 - sw - EDGE_INSET
				local markings = {
					{ lat = -edgeLine, color = laneMarkingColor, isEdge = true },
					{ lat = edgeLine, color = laneMarkingColor, isEdge = true },
				}
				if numLanes % 2 == 0 then
					for i = 1, numLanes / 2 - 1 do
						table.insert(markings, { lat = -i * laneWidth, color = laneMarkingColor })
						table.insert(markings, { lat = i * laneWidth, color = laneMarkingColor })
					end
					table.insert(markings, { lat = -CENTER_OFFSET, color = centerlineColor })
					table.insert(markings, { lat = CENTER_OFFSET, color = centerlineColor })
				else
					local halfLaneWidth = laneWidth / 2
					for _, sign in { -1, 1 } do
						for i = 1, (numLanes - 1) / 2 do
							local lat = (halfLaneWidth + (i - 1) * laneWidth) * sign
							if i == 1 then
								table.insert(markings, { lat = lat - sign, color = centerlineColor })
								table.insert(markings, { lat = lat, color = centerlineColor })
							else
								table.insert(markings, { lat = lat, color = laneMarkingColor })
							end
						end
					end
				end
				return markings
			end

			-- The outermost lane markings follow the corner curves. Each
			-- chord strip is miter-extended so the OUTER corners of
			-- consecutive strips join, rather than their centrelines.
			for _, data in cornerData do
				local pts = data.edgeArc
				for i = 1, #pts - 1 do
					local dir = (pts[i + 1] - pts[i]).Unit
					markingStrip(
						pts[i] - dir * data.edgeExtend,
						pts[i + 1] + dir * data.edgeExtend,
						laneMarkingColor,
						MARK_WIDTH
					)
				end
			end

			-- One road's stub markings. All lane lines of a stub end on a
			-- SQUARE cut (perpendicular to the road) placed just clear of the
			-- crossing road, with a perpendicular stop bar across the approach
			-- lanes. Edge lines instead run to the corner arc tangency and
			-- continue around the corner (drawn above).
			local function drawStubMarkings(u, n, w, laneWidth, numLanes, othN, othW, faceDistFn, edgeCutFn, stubs, skipEdgeLatSide)
				local markings = buildMarkings(laneWidth, numLanes, w)
				local edgeLine = w / 2 - sw - EDGE_INSET
				for _, s in stubs do
					local dir = u * s
					local dDotOth = dir:Dot(othN)
					local othSide = math.sign(dDotOth)
					local function tInnerAt(lat)
						return (othSide * othW / 2 - (n * lat):Dot(othN)) / dDotOth
					end
					-- The stop bar sits a fixed distance in from the open end
					-- (clamped clear of the crossing road when the box is small),
					-- so a bigger box leaves more open pavement in the middle
					local tCutMin = math.max(tInnerAt(-edgeLine), tInnerAt(edgeLine)) + MARK_SETBACK
					local tEnd = faceDistFn(0, s)
					-- A crosswalk claims its space in front of the stop line
					local crossingSpace = if crossingWidth > 0 then crossingWidth + CROSSWALK_GAP else 0
					local tBar = math.max(tEnd - STOP_LINE_END_DISTANCE, tCutMin + STOP_LINE_WIDTH / 2 + crossingSpace)
					local tMarks = tBar + STOP_LINE_WIDTH / 2 + 1
					for _, marking in markings do
						if skipEdgeLatSide and marking.isEdge and math.sign(marking.lat) == skipEdgeLatSide then
							-- Drawn continuously by the caller instead
							continue
						end
						local base = n * marking.lat
						local tFace = faceDistFn(marking.lat, s)
						if marking.isEdge then
							local tEdge = edgeCutFn(s, math.sign(marking.lat)) or tMarks
							if tFace > tEdge then
								markingStrip(base + dir * tEdge, base + dir * tFace, marking.color, MARK_WIDTH)
							end
						elseif tFace > tMarks then
							markingStrip(base + dir * tMarks, base + dir * tFace, marking.color, MARK_WIDTH)
						end
					end
					-- Stop bar square across the approach (right-hand) lanes
					local inbound = -dir
					local rightDir = Vector3.new(-inbound.Z, 0, inbound.X)
					local latSign = math.sign(rightDir:Dot(n))
					local latA = latSign * (CENTER_OFFSET + 1)
					local latB = latSign * (edgeLine - 1.5)
					markingStrip(n * latA + dir * tBar, n * latB + dir * tBar, laneMarkingColor, STOP_LINE_WIDTH)
					if crossingWidth > 0 then
						-- Zebra crosswalk between the stop bar and the
						-- junction, spanning the full drivable width
						local walkFar = tBar - STOP_LINE_WIDTH / 2 - CROSSWALK_GAP
						local walkNear = walkFar - crossingWidth
						local span = edgeLine - 1.5
						local lat = -span + CROSSWALK_STRIPE / 2
						while lat <= span - CROSSWALK_STRIPE / 2 do
							markingStrip(n * lat + dir * walkNear, n * lat + dir * walkFar, laneMarkingColor, CROSSWALK_STRIPE)
							lat += CROSSWALK_STRIPE * 2
						end
					end
				end
			end

			drawStubMarkings(uZ, nZ, wZ, attributes.LaneWidthZ, attributes.LaneCountZ, nX, wX, function(lat, s)
				return halfZ
			end, function(s, latSide)
				local data = cornerData[latSide .. "," .. -s]
				return if data then data.tZ else nil
			end, { -1, 1 }, if throughRoad then nil else -1)
			if not throughRoad then
				-- The crossbar's far-side (sidewalk side) edge line runs
				-- continuously from end to end
				local farEdge = nZ * -(wZ / 2 - sw - EDGE_INSET)
				markingStrip(farEdge + uZ * -halfZ, farEdge + uZ * halfZ, laneMarkingColor, MARK_WIDTH)
			end
			-- Squared ends: every road X marking runs to the same end plane
			drawStubMarkings(uX, nX, wX, attributes.LaneWidthX, attributes.LaneCountX, nZ, wZ, function(lat, s)
				return halfX
			end, function(s, latSide)
				local data = cornerData[s .. "," .. latSide]
				return if data then data.tX else nil
			end, if throughRoad then { -1, 1 } else { 1 })
		end

		-- Snapping helpers: box-aligned cubes marking the corners of each open
		-- end — blue for the Z road's ends, red for the X road's ends
		if attributes.AdjustShowSnappingHelper then
			-- Cubes stay box aligned like every generator's snapping helpers.
			-- The angled X ends position theirs about the slanted end's centre
			-- with world-aligned offsets, so they meet the markers of a world
			-- aligned road segment (angled via its end Dir adjust) exactly like
			-- a straight-to-straight joint.
			local function helperCube(color, p)
				local cube = createPart(
					"SnappingHelper",
					color,
					Enum.Material.SmoothPlastic,
					Vector3.new(4, 4, 4),
					CFrame.new(p.X, bottom + 2, p.Z)
				)
				cube.CanCollide = false
				cube.Parent = targetContainer
			end
			local blue = Color3.fromRGB(0, 100, 255)
			local red = Color3.fromRGB(255, 40, 40)
			for _, s in { -1, 1 } do
				helperCube(blue, Vector3.new(-wZ / 2, 0, s * (halfZ - 2)))
				helperCube(blue, Vector3.new(wZ / 2, 0, s * (halfZ - 2)))
				if throughRoad or s == 1 then
					local endCentre = uX * (s * halfX)
					helperCube(red, Vector3.new(endCentre.X - s * 2, 0, endCentre.Z - wX / 2))
					helperCube(red, Vector3.new(endCentre.X - s * 2, 0, endCentre.Z + wX / 2))
				end
			end
		end
	end,
}

return Generator
