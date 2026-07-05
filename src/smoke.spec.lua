local TestTypes = require("./TestTypes")

--[[
	Smoke test: just require every module to catch syntax errors, bad requires,
	and top-level mistakes. The interactive behavior needs a live plugin
	context, so it is exercised manually in Studio.
]]

return function(t: TestTypes.TestContext)
	t.test("all modules load", function()
		require("./RoadMath")
		require("./Settings")
		require("./createRoadSession")
		require("./RoadHelperGui")
		require("./main")
		require("./Handles/EndpointPickHandles")
		require("./Handles/EndpointMoveHandles")
		require("./Handles/EndpointRotateHandles")
		require("./Handles/AddHandles")
	end)
end
