local TestTypes = require("./TestTypes")

local RoadMath = require("./RoadMath")

local WIDTH = 64

local function makeSegment(kind: RoadMath.SegmentKind, size: Vector3, pivot: CFrame, flip: boolean?): RoadMath.SegmentInfo
	-- Stand-in for a ProceduralModel: only GetAttribute is needed by RoadMath
	local fakeModel: any = {
		attrs = {} :: { [string]: any },
	}
	fakeModel.GetAttribute = function(self, name: string)
		return self.attrs[name]
	end
	return {
		Model = fakeModel :: any,
		Kind = kind,
		Width = WIDTH,
		Size = size,
		Pivot = pivot,
		Flip = flip or false,
	}
end

local function expectFuzzy(t: TestTypes.TestContext, actual: Vector3, expected: Vector3, epsilon: number?)
	if not actual:FuzzyEq(expected, epsilon or 0.01) then
		t.fail(`Expected {expected}, got {actual}`)
	end
end

return function(t: TestTypes.TestContext)
	--
	-- Endpoint frames
	--

	t.test("straight endpoints: flat straight road", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, blue.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, red.WorldCFrame.LookVector, Vector3.new(0, 0, 1))
	end)

	t.test("straight endpoints: swayed climbing road with flip", function()
		-- sway = (200 - 64)/2 = 68; flip mirrors X so blue is at +68
		local seg = makeSegment("Straight", Vector3.new(200, 30, 300), CFrame.identity, true)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(68, -15, -150))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(-68, 15, 150))
	end)

	t.test("straight endpoints: respect the model pivot", function()
		local pivot = CFrame.new(100, 5, 20) * CFrame.Angles(0, math.rad(90), 0)
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), pivot)
		local blue = RoadMath.getEndpoint(seg, "Blue")
		expectFuzzy(t, blue.WorldCFrame.Position, (pivot * CFrame.new(0, 0, -100)).Position)
		expectFuzzy(t, blue.WorldCFrame.LookVector, pivot:VectorToWorldSpace(Vector3.new(0, 0, -1)))
	end)

	t.test("curve endpoints: flat square curve", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(-60 + 32, 0, -60))
		expectFuzzy(t, blue.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(60, 0, 60 - 32))
		expectFuzzy(t, red.WorldCFrame.LookVector, Vector3.new(1, 0, 0))
	end)

	t.test("curve endpoints: flip swaps climb ends", function()
		local seg = makeSegment("Curve", Vector3.new(120, 20, 120), CFrame.identity, true)
		local blue, red = RoadMath.getEndpoints(seg)
		t.expect(blue.WorldCFrame.Position.Y).toBe(10)
		t.expect(red.WorldCFrame.Position.Y).toBe(-10)
	end)

	--
	-- Moving endpoints
	--

	t.test("solveMove straight: extend red end forward", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(0, 0, 150))
		expectFuzzy(t, solution.Size, Vector3.new(WIDTH, 0, 250))
		t.expect(solution.Flip).toBe(false)
		-- Blue endpoint must stay at (0, 0, -100)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(0, 0, 150))
	end)

	t.test("solveMove straight: lateral move creates sway and sets Flip by side", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)

		-- Move red +X: red ends up on the +X side, no flip
		local plus = RoadMath.solveMove(seg, "Red", Vector3.new(40, 0, 100))
		expectFuzzy(t, plus.Size, Vector3.new(WIDTH + 40, 0, 200))
		t.expect(plus.Flip).toBe(false)
		local plusSeg = makeSegment("Straight", plus.Size, plus.Pivot, plus.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(plusSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(plusSeg, "Red").WorldCFrame.Position, Vector3.new(40, 0, 100))

		-- Move red -X: crosses to the other side, Flip
		local minus = RoadMath.solveMove(seg, "Red", Vector3.new(-40, 0, 100))
		t.expect(minus.Flip).toBe(true)
		local minusSeg = makeSegment("Straight", minus.Size, minus.Pivot, minus.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(minusSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(minusSeg, "Red").WorldCFrame.Position, Vector3.new(-40, 0, 100))
	end)

	t.test("solveMove straight: moving the blue end keeps red fixed", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local solution = RoadMath.solveMove(seg, "Blue", Vector3.new(-30, 0, -160))
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, Vector3.new(-30, 0, -160))
		-- Blue moved -X means red is on the +X side relative to blue: no flip
		t.expect(solution.Flip).toBe(false)
	end)

	t.test("solveMove straight: vertical move sets height, clamps below", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local up = RoadMath.solveMove(seg, "Red", Vector3.new(0, 25, 100))
		t.expect(up.Size.Y).toBe(25)
		local newSeg = makeSegment("Straight", up.Size, up.Pivot, up.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(0, 25, 100))

		-- Red below blue clamps to flat
		local down = RoadMath.solveMove(seg, "Red", Vector3.new(0, -25, 100))
		t.expect(down.Size.Y).toBe(0)
	end)

	t.test("solveMove straight: respects rotated pivots", function()
		local pivot = CFrame.new(50, 0, 50) * CFrame.Angles(0, math.rad(90), 0)
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), pivot)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local oldRed = RoadMath.getEndpoint(seg, "Red").WorldCFrame.Position
		-- Extend along the world direction the road actually runs
		local newRed = oldRed + (oldRed - oldBlue).Unit * 50
		local solution = RoadMath.solveMove(seg, "Red", newRed)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldBlue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, newRed)
	end)

	t.test("solveMove curve: endpoints track moved corners", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(100, 10, 28))
		local newSeg = makeSegment("Curve", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldBlue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(100, 10, 28))
		t.expect(solution.Flip).toBe(false)
	end)

	t.test("solveMove curve: moving red below blue flips", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(60, -18, 28))
		t.expect(solution.Flip).toBe(true)
		t.expect(solution.Size.Y).toBe(18)
		local newSeg = makeSegment("Curve", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldBlue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(60, -18, 28))
	end)

	t.test("solveMove curve: clamps to minimum footprint", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		-- Try to collapse the curve entirely
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(-60, 0, -60))
		t.expect(solution.Size.X >= WIDTH).toBe(true)
		t.expect(solution.Size.Z >= WIDTH).toBe(true)
	end)

	--
	-- Joints
	--

	t.test("findJoint: mated red->blue endpoints are closed", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		-- B continues from A's red end at (0, 0, 100), heading +Z
		local segB = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 150))
		local segments = { segA, segB }
		local joint = RoadMath.findJoint(RoadMath.getEndpoint(segA, "Red"), segments)
		t.expect(joint ~= nil).toBe(true)
		assert(joint)
		t.expect(joint.Id).toBe("Blue")
		t.expect(joint.Segment).toBe(segB)
	end)

	t.test("findJoint: far endpoints and same-facing endpoints are open", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local segFar = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 500))
		-- Same position as A's red end but facing the same way (overlapping, not mated)
		local segSame = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 50))
		local segments = { segA, segFar, segSame }
		local joint = RoadMath.findJoint(RoadMath.getEndpoint(segA, "Red"), segments)
		t.expect(joint == nil).toBe(true)
	end)

	--
	-- Adjust mapping
	--

	t.test("adjustDeltaSign: dir is +1 for both sides of a joint", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local segB = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 150))
		local selected = RoadMath.getEndpoint(segA, "Red")
		local partner = RoadMath.getEndpoint(segB, "Blue")
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Dir")).toBe(1)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Dir")).toBe(1)
	end)

	t.test("adjustDeltaSign: grade/bank match for red->blue joints", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local segB = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 150))
		local selected = RoadMath.getEndpoint(segA, "Red")
		local partner = RoadMath.getEndpoint(segB, "Blue")
		-- selected red: colorSign +1, facing itself +1 => +1
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Grade")).toBe(1)
		-- partner blue: colorSign -1, facing opposite -1 => +1 (grades stay equal)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Grade")).toBe(1)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Bank")).toBe(1)
	end)

	t.test("adjustDeltaSign: grade/bank negate for blue-blue joints", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		-- B's blue end mates with A's blue end (B runs the other way)
		local segB = makeSegment(
			"Straight",
			Vector3.new(WIDTH, 0, 100),
			CFrame.new(0, 0, -150) * CFrame.Angles(0, math.rad(180), 0)
		)
		local selected = RoadMath.getEndpoint(segA, "Blue")
		local partner = RoadMath.getEndpoint(segB, "Blue")
		-- Sanity: they are mated
		t.expect((selected.WorldCFrame.Position - partner.WorldCFrame.Position).Magnitude < 0.1).toBe(true)
		-- selected blue: colorSign -1, facing itself +1 => -1
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Grade")).toBe(-1)
		-- partner blue: colorSign -1, facing opposite -1 => +1
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Grade")).toBe(1)
	end)

	--
	-- New segment placement
	--

	t.test("placeNewSegment: straight extension joins blue to the open red end", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local openEnd = RoadMath.getEndpoint(segA, "Red") -- at (0, 0, 100) facing +Z
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Straight", WIDTH)
		t.expect(kind).toBe("Straight")
		t.expect(joinId).toBe("Blue")
		local newSeg = makeSegment("Straight", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		expectFuzzy(t, joined.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, joined.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
	end)

	t.test("placeNewSegment: right turn joins a curve's blue end", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Right", WIDTH)
		t.expect(kind).toBe("Curve")
		t.expect(joinId).toBe("Blue")
		local newSeg = makeSegment("Curve", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		expectFuzzy(t, joined.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, joined.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		-- Right turn: the curve's far (red) endpoint should be on the +X side
		local far = RoadMath.getEndpoint(newSeg, "Red")
		t.expect(far.WorldCFrame.Position.X > 10).toBe(true)
	end)

	t.test("placeNewSegment: left turn joins a curve's red end, exits -X side", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Left", WIDTH)
		t.expect(kind).toBe("Curve")
		t.expect(joinId).toBe("Red")
		local newSeg = makeSegment("Curve", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		expectFuzzy(t, joined.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, joined.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		-- Left turn: the curve's far (blue) endpoint should be on the -X side
		local far = RoadMath.getEndpoint(newSeg, "Blue")
		t.expect(far.WorldCFrame.Position.X < -10).toBe(true)
	end)

	t.test("placeNewSegment: follows the open end's actual (adjusted) direction", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local mockModel = {
			attrs = { AdjustRedDir = 30 },
		}
		(mockModel :: any).GetAttribute = function(self, name)
			return self.attrs[name]
		end
		segA.Model = mockModel :: any
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local _, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Straight", WIDTH)
		local newSeg = makeSegment("Straight", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		-- The joining face must oppose the actual outward = +Z yawed 30deg clockwise
		local expectedOutward = CFrame.Angles(0, math.rad(30), 0):VectorToWorldSpace(Vector3.new(0, 0, 1))
		expectFuzzy(t, joined.WorldCFrame.LookVector, -expectedOutward)
	end)

	t.test("matchingAdjust: negates for same-color joins, copies for opposite", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local mockModel = {
			attrs = { AdjustRedGrade = 10, AdjustRedBank = 5 },
		}
		(mockModel :: any).GetAttribute = function(self, name)
			return self.attrs[name]
		end
		segA.Model = mockModel :: any
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		-- Red joined to Blue: k = -(+1)(-1) = +1 (copy)
		local blueJoin = RoadMath.matchingAdjust(openEnd, "Blue")
		t.expect(blueJoin.Grade).toBe(10)
		t.expect(blueJoin.Bank).toBe(5)
		-- Red joined to Red: k = -(+1)(+1) = -1 (negate)
		local redJoin = RoadMath.matchingAdjust(openEnd, "Red")
		t.expect(redJoin.Grade).toBe(-10)
		t.expect(redJoin.Bank).toBe(-5)
	end)
end
